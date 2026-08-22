import Foundation
import Darwin
import NIOCore
import NIOPosix
import NIOSSL

/// HTTPS transport used by the tvOS playback path when the system TLS stack is
/// rejected by the media CDN. It runs entirely inside the app, validates the
/// server certificate and hostname, and never depends on a companion device.
///
/// `MultiThreadedEventLoopGroup` is intentional: SwiftNIO's default event loop
/// on Apple platforms uses Network.framework, which would put playback back on
/// the same TLS implementation that the fallback exists to avoid. NIOPosix plus
/// NIOSSL performs the TLS handshake with the package's vendored BoringSSL.
public enum StandaloneHTTPClient {
    private static let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private static let resolverQueue = DispatchQueue(
        label: "com.void.smarttube.standalone-http-resolver",
        qos: .userInitiated
    )
    private static let maximumResponseBytes = 24 * 1024 * 1024

    private static let tlsContextResult: Result<NIOSSLContext, any Error> = Result {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = .fullVerification
        // Node's fetch transport (the known-good GVS profile) does not advertise
        // HTTP/2 ALPN for these HTTP/1.1 requests. An empty list lets the server
        // select HTTP/1.1 without adding an otherwise different TLS extension.
        configuration.applicationProtocols = []
        return try NIOSSLContext(configuration: configuration)
    }

    public static func data(
        for request: URLRequest,
        timeout: TimeInterval = 30,
        redirectLimit: Int = 5
    ) async throws -> IPv4HTTPResponse {
        guard redirectLimit >= 0 else { throw StandaloneHTTPClientError.tooManyRedirects }
        let response = try await perform(request, timeout: timeout)

        guard [301, 302, 303, 307, 308].contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"),
              let redirectURL = URL(string: location, relativeTo: response.url)?.absoluteURL else {
            return response
        }
        guard redirectLimit > 0 else { throw StandaloneHTTPClientError.tooManyRedirects }

        var redirected = request
        redirected.url = redirectURL
        let originalMethod = request.httpMethod?.uppercased() ?? "GET"
        if response.statusCode == 303
            || ((response.statusCode == 301 || response.statusCode == 302) && originalMethod == "POST") {
            redirected.httpMethod = "GET"
            redirected.httpBody = nil
            redirected.setValue(nil, forHTTPHeaderField: "Content-Length")
            redirected.setValue(nil, forHTTPHeaderField: "Content-Type")
        }
        if request.url?.host?.caseInsensitiveCompare(redirectURL.host ?? "") != .orderedSame {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
            redirected.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        return try await data(
            for: redirected,
            timeout: timeout,
            redirectLimit: redirectLimit - 1
        )
    }

    private static func perform(
        _ request: URLRequest,
        timeout: TimeInterval
    ) async throws -> IPv4HTTPResponse {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty else {
            throw StandaloneHTTPClientError.invalidURL
        }
        let port = url.port ?? 443
        let address = try await preferredAddress(host: host, port: port)
        let tlsContext = try tlsContextResult.get()
        let payload = IPv4HTTPClient.makeRequestBytes(
            request,
            url: url,
            host: host,
            port: port,
            keepAlive: true
        )

        let responsePromise = eventLoopGroup.next().makePromise(of: ByteBuffer.self)
        let exchange = StandaloneHTTPExchangeHandler(
            request: ByteBuffer(bytes: payload),
            responsePromise: responsePromise,
            maximumResponseBytes: maximumResponseBytes,
            requestMethod: request.httpMethod?.uppercased() ?? "GET"
        )
        let timeoutMilliseconds = Int64(max(1, (timeout * 1_000).rounded(.up)))
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(.milliseconds(timeoutMilliseconds))
            .channelInitializer { channel in
                do {
                    let tlsHandler = try NIOSSLClientHandler(
                        context: tlsContext,
                        serverHostname: host
                    )
                    try channel.pipeline.syncOperations.addHandler(tlsHandler)
                    try channel.pipeline.syncOperations.addHandler(exchange)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let channel: any NIOCore.Channel
        do {
            channel = try await bootstrap.connect(to: address).get()
        } catch {
            throw StandaloneHTTPClientError.connection(error.localizedDescription)
        }

        let timeoutTask = channel.eventLoop.scheduleTask(
            in: .milliseconds(timeoutMilliseconds)
        ) {
            exchange.failForTimeout()
        }
        defer {
            timeoutTask.cancel()
            channel.close(promise: nil)
        }

        do {
            let buffer = try await responsePromise.futureResult.get()
            return try IPv4HTTPClient.parseResponse(
                Data(buffer.readableBytesView),
                url: url
            )
        } catch let error as StandaloneHTTPClientError {
            throw error
        } catch {
            throw StandaloneHTTPClientError.connection(error.localizedDescription)
        }
    }

    /// Prefer IPv4 so the player request and its signed media URLs use the same
    /// household route. IPv6 remains a fallback for IPv6-only/NAT64 networks.
    private static func preferredAddress(host: String, port: Int) async throws -> SocketAddress {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<SocketAddress, any Error>) in
            resolverQueue.async {
                continuation.resume(with: Result {
                    try preferredAddressBlocking(host: host, port: port)
                })
            }
        }
    }

    private static func preferredAddressBlocking(host: String, port: Int) throws -> SocketAddress {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var results: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &results)
        guard status == 0, let first = results else {
            let message = status == 0 ? "no addresses" : String(cString: gai_strerror(status))
            throw StandaloneHTTPClientError.dns(host: host, message: message)
        }
        defer { freeaddrinfo(first) }

        var firstIPv4: String?
        var firstIPv6: String?
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            let family = current.pointee.ai_family
            if family == AF_INET || family == AF_INET6 {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let nameStatus = getnameinfo(
                    current.pointee.ai_addr,
                    current.pointee.ai_addrlen,
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if nameStatus == 0 {
                    let addressBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    let numericAddress = String(decoding: addressBytes, as: UTF8.self)
                    if family == AF_INET, firstIPv4 == nil {
                        firstIPv4 = numericAddress
                    } else if family == AF_INET6, firstIPv6 == nil {
                        firstIPv6 = numericAddress
                    }
                }
            }
            cursor = current.pointee.ai_next
        }

        guard let selected = firstIPv4 ?? firstIPv6 else {
            throw StandaloneHTTPClientError.dns(host: host, message: "no usable IP address")
        }
        return try SocketAddress(ipAddress: selected, port: port)
    }
}

public enum StandaloneHTTPClientError: LocalizedError, Sendable {
    case invalidURL
    case dns(host: String, message: String)
    case connection(String)
    case timedOut
    case responseTooLarge
    case tooManyRedirects

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The standalone HTTP request URL is invalid"
        case .dns(let host, let message):
            return "Unable to resolve \(host): \(message)"
        case .connection(let message):
            return "Standalone HTTPS connection failed: \(message)"
        case .timedOut:
            return "Standalone HTTPS request timed out"
        case .responseTooLarge:
            return "Standalone HTTPS response exceeded its size limit"
        case .tooManyRedirects:
            return "Standalone HTTPS request exceeded its redirect limit"
        }
    }
}

private final class StandaloneHTTPExchangeHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let request: ByteBuffer
    private let responsePromise: EventLoopPromise<ByteBuffer>
    private let maximumResponseBytes: Int
    private let requestMethod: String
    private var response = ByteBuffer()
    private var isFinished = false
    private weak var context: ChannelHandlerContext?

    init(
        request: ByteBuffer,
        responsePromise: EventLoopPromise<ByteBuffer>,
        maximumResponseBytes: Int,
        requestMethod: String
    ) {
        self.request = request
        self.responsePromise = responsePromise
        self.maximumResponseBytes = maximumResponseBytes
        self.requestMethod = requestMethod
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func channelActive(context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(request), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        guard response.readableBytes + incoming.readableBytes <= maximumResponseBytes else {
            finish(.failure(StandaloneHTTPClientError.responseTooLarge))
            context.close(promise: nil)
            return
        }
        response.writeBuffer(&incoming)
        if responseIsComplete() {
            finish(.success(response))
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(.success(response))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        // A number of Google video endpoints close HTTP/1.1 connections without
        // sending TLS close_notify after the complete response body. Browsers and
        // URLSession accept that behaviour. NIOSSL reports it as uncleanShutdown,
        // so preserve the received response and let the HTTP parser validate that
        // headers/chunks/content-length are complete.
        if let sslError = error as? NIOSSLError,
           sslError == .uncleanShutdown,
           response.readableBytes > 0 {
            finish(.success(response))
        } else {
            finish(.failure(error))
        }
        context.close(promise: nil)
    }

    func failForTimeout() {
        finish(.failure(StandaloneHTTPClientError.timedOut))
        context?.close(promise: nil)
    }

    private func finish(_ result: Result<ByteBuffer, any Error>) {
        guard !isFinished else { return }
        isFinished = true
        responsePromise.completeWith(result)
    }

    /// HTTP/1.1 keep-alive responses must complete as soon as the declared body
    /// arrives; waiting for EOF would turn every successful request into a timeout.
    /// The final parser still validates and decodes the response after this check.
    private func responseIsComplete() -> Bool {
        let raw = Data(response.readableBytesView)
        let headerTerminator = Data([13, 10, 13, 10])
        guard let headerRange = raw.range(of: headerTerminator) else { return false }

        let headerData = raw[..<headerRange.lowerBound]
        let lines = String(decoding: headerData, as: UTF8.self)
            .components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return false }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            return false
        }
        if requestMethod == "HEAD" || statusCode == 204 || statusCode == 304 {
            return true
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = headerRange.upperBound
        if let value = headers["content-length"], let length = Int(value), length >= 0 {
            return raw.count - bodyStart >= length
        }
        if headers["transfer-encoding"]?.localizedCaseInsensitiveContains("chunked") == true {
            return chunkedBodyIsComplete(raw, bodyStart: bodyStart)
        }
        return false
    }

    private func chunkedBodyIsComplete(_ raw: Data, bodyStart: Int) -> Bool {
        let lineTerminator = Data([13, 10])
        let headerTerminator = Data([13, 10, 13, 10])
        var cursor = bodyStart

        while cursor < raw.count {
            guard let lineRange = raw.range(
                of: lineTerminator,
                options: [],
                in: cursor..<raw.count
            ) else { return false }
            let rawSize = String(decoding: raw[cursor..<lineRange.lowerBound], as: UTF8.self)
            let sizeText = rawSize.split(separator: ";", maxSplits: 1).first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16),
                  size >= 0 else { return false }
            cursor = lineRange.upperBound

            if size == 0 {
                if cursor + 2 <= raw.count,
                   raw[cursor] == 13,
                   raw[cursor + 1] == 10 {
                    return true
                }
                return raw.range(
                    of: headerTerminator,
                    options: [],
                    in: cursor..<raw.count
                ) != nil
            }

            guard cursor + size + 2 <= raw.count,
                  raw[cursor + size] == 13,
                  raw[cursor + size + 1] == 10 else { return false }
            cursor += size + 2
        }
        return false
    }
}
