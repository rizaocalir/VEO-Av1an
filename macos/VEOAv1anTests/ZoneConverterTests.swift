//
//  ZoneConverterTests.swift — unit tests for the Swift converter port
//  Mirrors tests/test_veo_to_av1an.py
//

import XCTest
@testable import VEOAv1an

final class ZoneConverterTests: XCTestCase {

    let perSegmentStdout = """
      Segments (3):
        #   Time        Complexity   CRF   Bitrate      VMAF   Iter
        -   ----        ----------   ---   -------      ----   ----
        1   0.0-2.0s    30           38    850 kbps     93.4   2
        2   2.0-4.0s    62           24    2100 kbps    92.8   3
        3   4.0-6.0s    47           30    1400 kbps    93.1   3
    """

    let perShotStdout = """
      Shot 1 (0.0s - 4.2s, 4.2s):
        Hull: 5 points, 900 - 3200 kbps, VMAF 90.1 - 97.4
      Shot 2 (4.2s - 9.8s, 5.6s):
        Hull: 5 points, 1500 - 6000 kbps, VMAF 88.3 - 96.9
        Shot   Res     Codec      CRF   Bitrate     VMAF
        ----   ---     -----      ---   -------     ----
        1      1080p   libsvtav1  30    1800 kbps   94.2
        2      1080p   libsvtav1  24    3100 kbps   94.8
    """

    // MARK: stdout parsing

    func testPerSegmentTable() {
        let segs = parseVeoStdout(perSegmentStdout)
        XCTAssertEqual(segs.count, 3)
        XCTAssertEqual(segs[0], Segment(start: 0, end: 2, crf: 38))
        XCTAssertEqual(segs[2], Segment(start: 4, end: 6, crf: 30))
    }

    func testPerShotWithTrellis() {
        let segs = parseVeoStdout(perShotStdout)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].crf, 30)
        XCTAssertEqual(segs[1].crf, 24)
        XCTAssertEqual(segs[1].end, 9.8, accuracy: 0.01)
    }

    func testDetectTable() {
        let text = """
          #   Start    End      Duration
          1   0.00s    4.17s    4.17s
          2   4.17s    9.83s    5.67s
        """
        let segs = parseVeoStdout(text)
        XCTAssertEqual(segs.count, 2)
        XCTAssertNil(segs[0].crf)
    }

    func testGarbage() {
        XCTAssertTrue(parseVeoStdout("nothing useful\nfoo bar").isEmpty)
    }

    // MARK: JSON parsing

    func testJSONNanoseconds() throws {
        let json = """
        {"segments": [
          {"start": 0, "end": 2000000000, "crf": 38},
          {"start": 2000000000, "end": 4000000000, "crf": 24}
        ]}
        """.data(using: .utf8)!
        let segs = try parseVeoJSON(data: json)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[1], Segment(start: 2, end: 4, crf: 24))
    }

    func testJSONPerShotAssignments() throws {
        let json = """
        {"shots": [
          {"shot": {"index": 0, "start": 0, "end": 4200000000}},
          {"shot": {"index": 1, "start": 4200000000, "end": 9800000000}}
        ],
        "assignments": [
          {"shot_index": 0, "crf": 30},
          {"shot_index": 1, "crf": 24}
        ]}
        """.data(using: .utf8)!
        let segs = try parseVeoJSON(data: json)
        XCTAssertEqual(segs.map(\.crf), [30, 24])
    }

    // MARK: zones

    private func zones(_ segs: [Segment],
                       fps: Double = 24, frames: Int = 240,
                       encoder: String = "svt-av1",
                       minLen: Int = 24,
                       defaultCRF: Double? = nil,
                       extra: String = "",
                       report: inout ConvertReport) throws -> [Zone] {
        try toZones(segments: segs, fps: fps, totalFrames: frames,
                    encoder: encoder, defaultCRF: defaultCRF,
                    minSceneFrames: minLen, extraZoneParams: extra,
                    report: &report)
    }

    func testBasicRender() throws {
        var r = ConvertReport()
        let z = try zones([Segment(start: 0, end: 2, crf: 38),
                           Segment(start: 2, end: 10, crf: 24)],
                          report: &r)
        XCTAssertEqual(renderZones(z),
                       "0 48 svt-av1 --crf 38\n48 -1 svt-av1 --crf 24\n")
    }

    func testOverlapClipped() throws {
        var r = ConvertReport()
        let z = try zones([Segment(start: 0, end: 3, crf: 30),
                           Segment(start: 2, end: 6, crf: 25)],
                          report: &r)
        XCTAssertEqual(r.clippedOverlaps, 1)
        XCTAssertEqual(z[0].endFrame, 48)
        XCTAssertEqual(z[1].startFrame, 48)
    }

    func testAdjacentMerged() throws {
        var r = ConvertReport()
        let z = try zones([Segment(start: 0, end: 1, crf: 30),
                           Segment(start: 1, end: 5, crf: 30),
                           Segment(start: 5, end: 10, crf: 22)],
                          report: &r)
        XCTAssertEqual(z.count, 2)
        XCTAssertEqual(r.mergedAdjacent, 1)
    }

    func testShortZoneMerged() throws {
        var r = ConvertReport()
        let z = try zones([Segment(start: 0, end: 4, crf: 30),
                           Segment(start: 4, end: 4.25, crf: 50),
                           Segment(start: 4.25, end: 10, crf: 32)],
                          report: &r)
        XCTAssertEqual(z.count, 2)
        XCTAssertEqual(r.droppedShort, 1)
        XCTAssertEqual(z[1].startFrame, 96)
    }

    func testCRFClamped() throws {
        var r = ConvertReport()
        let z = try zones([Segment(start: 0, end: 5, crf: 80)], report: &r)
        XCTAssertTrue(z[0].videoParams.contains("--crf 63"))
        XCTAssertEqual(r.clampedCRF, 1)
    }

    func testEncoderFlag() throws {
        var r = ConvertReport()
        let z = try zones([Segment(start: 0, end: 5, crf: 28)],
                          encoder: "aom", report: &r)
        XCTAssertTrue(z[0].videoParams.contains("--cq-level=28"))
    }

    func testEOFMarker() throws {
        var r = ConvertReport()
        let z = try zones([Segment(start: 0, end: 3, crf: 30),
                           Segment(start: 3, end: 10, crf: 25)],
                          report: &r)
        XCTAssertEqual(z.last?.endFrame, -1)
    }

    func testUncoveredReported() throws {
        var r = ConvertReport()
        let z = try zones([Segment(start: 2, end: 8, crf: 30)], report: &r)
        XCTAssertEqual(r.uncoveredLead, 2, accuracy: 0.001)
        XCTAssertEqual(r.uncoveredTail, 2, accuracy: 0.001)
        XCTAssertEqual(z[0].endFrame, 192)
    }

    func testDefaultCRF() throws {
        var r = ConvertReport()
        let z = try zones([Segment(start: 0, end: 5, crf: nil)],
                          defaultCRF: 31, report: &r)
        XCTAssertTrue(z[0].videoParams.contains("--crf 31"))
    }

    func testUnsupportedEncoder() {
        var r = ConvertReport()
        XCTAssertThrowsError(try zones([Segment(start: 0, end: 5, crf: 30)],
                                       encoder: "rav1e", report: &r))
    }
}
