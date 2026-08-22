import Foundation
import Testing
@testable import SmartTubeIOSCore

// MARK: - FEShortsClientRegressionTests
//
// Regression coverage for the current Shorts transport. YouTube retired the
// FEshorts browse endpoint, so the first page and tagged continuations now use
// WEB search for `#shorts`. Untagged continuations from older app versions keep
// the legacy TVHTML5-first fallback.

// MARK: - URLProtocol helper

/// Intercepts the first outgoing POST request and captures its JSON body.
/// Returns HTTP 400 so the caller's network path fails fast.
private final class BodyCapturingURLProtocol: URLProtocol, @unchecked Sendable {

    nonisolated(unsafe) static var capturedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool {
        request.httpMethod == "POST"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession converts httpBody to httpBodyStream before handing the request
        // to URLProtocol; httpBody is always nil here.
        // Only capture the FIRST request — fetchShorts falls back to a second search
        // request when the primary browse fails, and we must not let it overwrite
        // the FEshorts browse body we already captured.
        if BodyCapturingURLProtocol.capturedBody == nil {
            if let stream = request.httpBodyStream {
                stream.open()
                var body = Data()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer {
                    buffer.deallocate()
                    stream.close()
                }
                // Use read-until-zero rather than hasBytesAvailable; the latter
                // can return false prematurely for in-memory streams.
                while true {
                    let count = stream.read(buffer, maxLength: bufferSize)
                    if count <= 0 { break }
                    body.append(buffer, count: count)
                }
                BodyCapturingURLProtocol.capturedBody = body
            } else if let bodyData = request.httpBody {
                // Fallback: some configurations pass the body directly in httpBody.
                BodyCapturingURLProtocol.capturedBody = bodyData
            }
        }

        // Reply with a minimal HTTP 400 response so the API call fails fast.
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 400,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Tests

@Suite("Shorts client routing", .serialized)
struct FEShortsClientRegressionTests {

    // MARK: - Helpers

    /// Returns an `InnerTubeAPI` wired to `BodyCapturingURLProtocol` via an ephemeral
    /// `URLSession`. This avoids polluting the global URLProtocol registry.
    private func makeTestAPI(authToken: String) -> InnerTubeAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BodyCapturingURLProtocol.self]
        let session = URLSession(configuration: config)
        return InnerTubeAPI(authToken: authToken, session: session)
    }

    // MARK: - fetchShorts

    /// FEshorts is no longer accepted by YouTube; the current first-page path is
    /// a WEB search and must not regress to the retired TV browse endpoint.
    @Test("fetchShorts sends WEB clientName")
    func fetchShortsSendsWebClient() async throws {
        BodyCapturingURLProtocol.capturedBody = nil
        let api = makeTestAPI(authToken: "fake-tv-oauth-token")

        // The call will throw (HTTP 400 from BodyCapturingURLProtocol), which is expected.
        _ = try? await api.fetchShorts()

        let bodyData = try #require(
            BodyCapturingURLProtocol.capturedBody,
            "URLProtocol should have captured the POST body"
        )
        let json = try #require(
            try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
            "Request body must be valid JSON"
        )

        let context = json["context"] as? [String: Any]
        let clientDict = context?["client"] as? [String: Any]

        #expect(
            clientDict?["clientName"] as? String == "WEB",
            """
            fetchShorts must use the WEB search path because FEshorts is retired.
            Found clientName=\(String(describing: clientDict?["clientName"]))
            """
        )
    }

    // MARK: - fetchShortsMore

    /// Search continuations are tagged `srch:` and must stay on the WEB search
    /// client while forwarding the raw token unchanged.
    @Test("fetchShortsMore routes srch token through WEB")
    func fetchShortsMoreSendsWebSearchClient() async throws {
        BodyCapturingURLProtocol.capturedBody = nil
        let api = makeTestAPI(authToken: "fake-tv-oauth-token")

        _ = try? await api.fetchShortsMore(continuationToken: "srch:test-continuation-token-12345")

        let bodyData = try #require(
            BodyCapturingURLProtocol.capturedBody,
            "URLProtocol should have captured the POST body"
        )
        let json = try #require(
            try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
            "Request body must be valid JSON"
        )

        let context = json["context"] as? [String: Any]
        let clientDict = context?["client"] as? [String: Any]

        #expect(
            clientDict?["clientName"] as? String == "WEB",
            """
            A search continuation must use the WEB search client.
            Found clientName=\(String(describing: clientDict?["clientName"]))
            """
        )
        #expect(
            json["continuation"] as? String == "test-continuation-token-12345",
            "fetchShortsMore must forward the continuation token in the body"
        )
    }

    @Test("legacy untagged continuation starts with TVHTML5 when authenticated")
    func legacyContinuationStartsWithTVClient() async throws {
        BodyCapturingURLProtocol.capturedBody = nil
        let api = makeTestAPI(authToken: "fake-tv-oauth-token")

        _ = try? await api.fetchShortsMore(continuationToken: "legacy-token")

        let bodyData = try #require(BodyCapturingURLProtocol.capturedBody)
        let json = try #require(try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let context = json["context"] as? [String: Any]
        let client = context?["client"] as? [String: Any]
        #expect(client?["clientName"] as? String == "TVHTML5")
        #expect(json["continuation"] as? String == "legacy-token")
    }
}
