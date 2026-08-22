import Foundation
import Network
import Security

/// Buffered HTTP response returned by ``IPv4HTTPClient``.
///
/// Header values are retained as arrays because YouTube watch pages send several
/// independent `Set-Cookie` fields which must not be folded on commas.
public struct IPv4HTTPResponse: Sendable {
    public let url: URL
    public let statusCode: Int
    public let headers: [String: [String]]
    public let body: Data

    public init(
        url: URL,
        statusCode: Int,
        headers: [String: [String]],
        body: Data
    ) {
        self.url = url
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func value(forHTTPHeaderField name: String) -> String? {
        headers[name.lowercased()]?.last
    }

    public func values(forHTTPHeaderField name: String) -> [String] {
        headers[name.lowercased()] ?? []
    }
}

public enum IPv4HTTPClientError: LocalizedError, Sendable {
    case invalidURL
    case unsupportedScheme(String)
    case connection(String)
    case timedOut
    case malformedResponse
    case tooManyRedirects

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The IPv4 HTTP request URL is invalid"
        case .unsupportedScheme(let scheme):
            return "Unsupported IPv4 HTTP scheme: \(scheme)"
        case .connection(let message):
            return "IPv4 HTTP connection failed: \(message)"
        case .timedOut:
            return "IPv4 HTTP request timed out"
        case .malformedResponse:
            return "The IPv4 HTTP response was malformed"
        case .tooManyRedirects:
            return "The IPv4 HTTP request exceeded its redirect limit"
        }
    }
}

/// Small HTTPS/1.1 client whose Network.framework stack is explicitly restricted
/// to IPv4. tvOS otherwise prefers the Apple TV's native IPv6 route; YouTube can
/// independently challenge that address even while the household IPv4 session is
/// trusted. The client keeps normal TLS hostname validation and SNI intact.
public enum IPv4HTTPClient {
    public static func data(
        for request: URLRequest,
        timeout: TimeInterval = 30,
        redirectLimit: Int = 5
    ) async throws -> IPv4HTTPResponse {
        guard redirectLimit >= 0 else { throw IPv4HTTPClientError.tooManyRedirects }
        let response = try await perform(request, timeout: timeout)

        guard [301, 302, 303, 307, 308].contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"),
              let redirectURL = URL(string: location, relativeTo: response.url)?.absoluteURL else {
            return response
        }
        guard redirectLimit > 0 else { throw IPv4HTTPClientError.tooManyRedirects }

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
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty else {
            throw IPv4HTTPClientError.invalidURL
        }
        guard scheme == "https" else {
            throw IPv4HTTPClientError.unsupportedScheme(scheme)
        }

        let portValue = url.port ?? 443
        guard let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
            throw IPv4HTTPClientError.invalidURL
        }

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(
            tlsOptions.securityProtocolOptions,
            host
        )
        // We emit HTTP/1.1 bytes directly, so prevent ALPN from selecting HTTP/2.
        sec_protocol_options_add_tls_application_protocol(
            tlsOptions.securityProtocolOptions,
            "http/1.1"
        )
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: parameters
        )
        let payload = makeRequestBytes(request, url: url, host: host, port: portValue)
        let raw = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, any Error>) in
            let operation = IPv4HTTPRequestOperation(
                connection: connection,
                payload: payload,
                timeout: timeout,
                continuation: continuation
            )
            operation.start()
        }
        return try parseResponse(raw, url: url)
    }

    static func makeRequestBytes(
        _ request: URLRequest,
        url: URL,
        host: String,
        port: Int,
        keepAlive: Bool = false
    ) -> Data {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var target = components?.percentEncodedPath ?? url.path
        if target.isEmpty { target = "/" }
        if let query = components?.percentEncodedQuery, !query.isEmpty {
            target += "?\(query)"
        }

        var headers = request.allHTTPHeaderFields ?? [:]
        for key in Array(headers.keys) where [
            "host", "connection", "content-length", "accept-encoding",
        ].contains(key.lowercased()) {
            headers.removeValue(forKey: key)
        }
        headers["Host"] = port == 443 ? host : "\(host):\(port)"
        headers["Connection"] = keepAlive ? "keep-alive" : "close"
        headers["Accept-Encoding"] = "identity"
        if headers.keys.allSatisfy({ $0.caseInsensitiveCompare("User-Agent") != .orderedSame }) {
            headers["User-Agent"] = "iTube/tvOS"
        }

        let body = request.httpBody ?? Data()
        if !body.isEmpty {
            headers["Content-Length"] = String(body.count)
        }
        let method = request.httpMethod?.uppercased() ?? "GET"
        var head = "\(method) \(target) HTTP/1.1\r\n"
        for (name, value) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var result = Data(head.utf8)
        result.append(body)
        return result
    }

    static func parseResponse(_ raw: Data, url: URL) throws -> IPv4HTTPResponse {
        let separator = Data([13, 10, 13, 10])
        guard let headerRange = raw.range(of: separator) else {
            throw IPv4HTTPClientError.malformedResponse
        }
        let headerData = raw[..<headerRange.lowerBound]
        let lines = String(decoding: headerData, as: UTF8.self)
            .components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw IPv4HTTPClientError.malformedResponse
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw IPv4HTTPClientError.malformedResponse
        }

        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name, default: []].append(value)
        }

        let bodyStart = headerRange.upperBound
        let encodedBody = Data(raw[bodyStart...])
        let body: Data
        if headers["transfer-encoding"]?.contains(where: {
            $0.localizedCaseInsensitiveContains("chunked")
        }) == true {
            body = try decodeChunkedBody(encodedBody)
        } else if let lengthValue = headers["content-length"]?.last,
                  let length = Int(lengthValue),
                  encodedBody.count >= length {
            body = Data(encodedBody.prefix(length))
        } else {
            body = encodedBody
        }
        return IPv4HTTPResponse(
            url: url,
            statusCode: statusCode,
            headers: headers,
            body: body
        )
    }

    private static func decodeChunkedBody(_ data: Data) throws -> Data {
        let crlf = Data([13, 10])
        var cursor = data.startIndex
        var decoded = Data()
        while cursor < data.endIndex {
            guard let lineRange = data[cursor...].range(of: crlf) else {
                throw IPv4HTTPClientError.malformedResponse
            }
            let sizeLine = String(decoding: data[cursor..<lineRange.lowerBound], as: UTF8.self)
            let sizeToken = sizeLine.split(separator: ";", maxSplits: 1).first ?? ""
            guard let size = Int(sizeToken.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw IPv4HTTPClientError.malformedResponse
            }
            cursor = lineRange.upperBound
            if size == 0 { return decoded }
            guard size >= 0,
                  let chunkEnd = data.index(cursor, offsetBy: size, limitedBy: data.endIndex),
                  chunkEnd <= data.endIndex else {
                throw IPv4HTTPClientError.malformedResponse
            }
            decoded.append(data[cursor..<chunkEnd])
            cursor = chunkEnd
            guard cursor + 2 <= data.endIndex,
                  data[cursor] == 13,
                  data[cursor + 1] == 10 else {
                throw IPv4HTTPClientError.malformedResponse
            }
            cursor += 2
        }
        throw IPv4HTTPClientError.malformedResponse
    }
}

private final class IPv4HTTPRequestOperation: @unchecked Sendable {
    private let connection: NWConnection
    private let payload: Data
    private let timeout: TimeInterval
    private let continuation: CheckedContinuation<Data, any Error>
    private let queue = DispatchQueue(
        label: "com.void.smarttube.ipv4-http",
        qos: .userInitiated
    )
    private var buffer = Data()
    private var completed = false
    private var didSend = false

    init(
        connection: NWConnection,
        payload: Data,
        timeout: TimeInterval,
        continuation: CheckedContinuation<Data, any Error>
    ) {
        self.connection = connection
        self.payload = payload
        self.timeout = timeout
        self.continuation = continuation
    }

    func start() {
        // Keep the operation alive through the connection's state handler. `finish`
        // clears this handler, breaking the temporary retention cycle deterministically.
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.sendIfNeeded()
            case .failed(let error):
                self.finish(.failure(IPv4HTTPClientError.connection(String(describing: error))))
            case .cancelled:
                if !self.completed {
                    self.finish(.failure(IPv4HTTPClientError.connection("cancelled")))
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(IPv4HTTPClientError.timedOut))
        }
    }

    private func sendIfNeeded() {
        guard !didSend, !completed else { return }
        didSend = true
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(.failure(IPv4HTTPClientError.connection(String(describing: error))))
            } else {
                self.receiveNext()
            }
        })
    }

    private func receiveNext() {
        guard !completed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let error {
                self.finish(.failure(IPv4HTTPClientError.connection(String(describing: error))))
            } else if isComplete {
                self.finish(.success(self.buffer))
            } else {
                self.receiveNext()
            }
        }
    }

    private func finish(_ result: Result<Data, any Error>) {
        guard !completed else { return }
        completed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}
