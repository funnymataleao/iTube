import Foundation
import Testing
@testable import SmartTubeIOSCore

private final class VideoTopicsURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capturedURL: URL?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/youtube/v3/videos"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedURL = request.url
        let body = Data(
            """
            {
              "items": [
                {"id":"whole","snippet":{"categoryId":"28","tags":["swift"],"publishedAt":"1970-01-01T00:00:01Z"}},
                {"id":"fractional","snippet":{"categoryId":"20","publishedAt":"1970-01-01T00:00:01.250Z"}},
                {"id":"invalid","snippet":{"publishedAt":"not-a-date"}},
                {"id":"missing","snippet":{"categoryId":"24"}}
              ]
            }
            """.utf8
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("YouTube video topic metadata", .serialized)
struct InnerTubeAPIVideoTopicsTests {
    @Test("Parses exact publishedAt and requests it in the fields projection")
    func parsesPublishedAt() async throws {
        VideoTopicsURLProtocol.capturedURL = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VideoTopicsURLProtocol.self]
        let api = InnerTubeAPI(
            authToken: "test-token",
            session: URLSession(configuration: configuration)
        )

        let result = try await api.fetchVideoTopicMetadata(
            videoIDs: ["whole", "fractional", "invalid", "missing"]
        )

        #expect(result["whole"]?.publishedAt == Date(timeIntervalSince1970: 1))
        let fractional = try #require(result["fractional"]?.publishedAt)
        #expect(abs(fractional.timeIntervalSince1970 - 1.25) < 0.000_001)
        #expect(result["invalid"]?.publishedAt == nil)
        #expect(result["missing"]?.publishedAt == nil)
        #expect(result["whole"]?.categoryID == "28")
        #expect(result["whole"]?.tags == ["swift"])

        let capturedURL = try #require(VideoTopicsURLProtocol.capturedURL)
        let fields = URLComponents(url: capturedURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "fields" })?
            .value
        #expect(fields == "items(id,snippet(categoryId,tags,publishedAt))")
    }
}
