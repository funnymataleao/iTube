import Foundation
import XCTest
@testable import SmartTubeIOS

final class OnDevicePlaybackRelayTests: XCTestCase {
    func testOpenAndOversizedByteRangesAreCapped() {
        XCTAssertEqual(
            OnDevicePlaybackRelay.boundedRange("bytes=10-", maximumBytes: 100),
            "bytes=10-109"
        )
        XCTAssertEqual(
            OnDevicePlaybackRelay.boundedRange("bytes=10-1000", maximumBytes: 100),
            "bytes=10-109"
        )
        XCTAssertEqual(
            OnDevicePlaybackRelay.boundedRange("bytes=10-20", maximumBytes: 100),
            "bytes=10-20"
        )
        XCTAssertNil(OnDevicePlaybackRelay.boundedRange("bytes=-20", maximumBytes: 100))
        XCTAssertNil(OnDevicePlaybackRelay.boundedRange("bytes=0-10,20-30", maximumBytes: 100))
    }

    func testHLSPlaylistsRewriteLineAndURIAttributeReferences() {
        let manifest = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="keys/key.bin"
        #EXTINF:5,
        segments/one.m4s
        """
        let base = URL(string: "https://manifest.googlevideo.com/path/master.m3u8")!

        let rewritten = OnDevicePlaybackRelay.rewritePlaylist(
            manifest,
            baseURL: base
        ) { upstream in
            URL(string: "http://127.0.0.1:9000/resource/\(upstream.lastPathComponent)")!
        }

        XCTAssertTrue(rewritten.contains(#"URI="http://127.0.0.1:9000/resource/key.bin""#))
        XCTAssertTrue(rewritten.contains("http://127.0.0.1:9000/resource/one.m4s"))
        XCTAssertFalse(rewritten.contains("segments/one.m4s"))
    }

    func testSIDXIsConvertedIntoFMP4HLSByteRanges() throws {
        var data = Data()
        appendUInt32(16, to: &data)
        data.append(contentsOf: Data("ftyp".utf8))
        data.append(contentsOf: repeatElement(UInt8(0), count: 8))

        appendUInt32(44, to: &data)
        data.append(contentsOf: Data("sidx".utf8))
        appendUInt32(0, to: &data)       // version + flags
        appendUInt32(1, to: &data)       // reference ID
        appendUInt32(1_000, to: &data)   // timescale
        appendUInt32(0, to: &data)       // earliest presentation time
        appendUInt32(0, to: &data)       // first offset
        appendUInt16(0, to: &data)       // reserved
        appendUInt16(1, to: &data)       // reference count
        appendUInt32(1_000, to: &data)   // reference type 0 + byte size
        appendUInt32(5_000, to: &data)   // duration = 5 seconds
        appendUInt32(0, to: &data)       // SAP flags

        let index = try OnDevicePlaybackRelay.parseMP4Index(data)
        XCTAssertEqual(index.initializationLength, 16)
        XCTAssertEqual(index.references, [
            .init(offset: 60, size: 1_000, duration: 5),
        ])

        let playlist = OnDevicePlaybackRelay.mediaPlaylist(
            mediaURL: URL(string: "http://127.0.0.1:9000/resource/video.mp4")!,
            index: index
        )
        XCTAssertTrue(playlist.contains(#"#EXT-X-MAP:URI="http://127.0.0.1:9000/resource/video.mp4",BYTERANGE="16@0""#))
        XCTAssertTrue(playlist.contains("#EXT-X-BYTERANGE:1000@60"))
        XCTAssertTrue(playlist.contains("#EXTINF:5.000000,"))
        XCTAssertTrue(playlist.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }
}
