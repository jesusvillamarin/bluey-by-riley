import XCTest
@testable import GooglyShared

final class ScribeTurnTests: XCTestCase {
    func testSocketURL() {
        let url = ScribeRealtime.socketURL(token: "t k", keyterms: ["Bluey", "Codex", String(repeating: "x", count: 21)], languageCode: nil)
        XCTAssertEqual(url.absoluteString, "wss://api.elevenlabs.io/v1/speech-to-text/realtime?token=t%20k&model_id=scribe_v2_realtime&audio_format=pcm_24000&commit_strategy=manual&keyterms=Bluey&keyterms=Codex")
    }
    func testSocketURLPutsLanguageBeforeKeyterms() {
        let url = ScribeRealtime.socketURL(token: "t", keyterms: ["Bluey"], languageCode: "es")
        XCTAssertEqual(url.absoluteString, "wss://api.elevenlabs.io/v1/speech-to-text/realtime?token=t&model_id=scribe_v2_realtime&audio_format=pcm_24000&commit_strategy=manual&language_code=es&keyterms=Bluey")
    }
    func testSocketURLCapsKeytermsAtFifty() {
        let url = ScribeRealtime.socketURL(token: "t", keyterms: (0..<60).map { "k\($0)" }, languageCode: nil)
        XCTAssertEqual(url.absoluteString.components(separatedBy: "keyterms=").count - 1, 50)
    }
    func testAudioFrameIsTextJSON() throws {
        let frame = ScribeRealtime.audioFrame(Data([1, 2]), commit: true)
        let json = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as! [String: Any]
        XCTAssertEqual(json["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(json["audio_base_64"] as? String, "AQI=")
        XCTAssertEqual(json["commit"] as? Bool, true)
        XCTAssertEqual(json["sample_rate"] as? Int, 24000)
    }
    func testParse() {
        XCTAssertEqual(ScribeRealtime.parse(#"{"message_type":"committed_transcript_with_timestamps","text":"hola","words":[]}"#), .committed("hola"))
        XCTAssertEqual(ScribeRealtime.parse(#"{"message_type":"auth_error","error":"bad"}"#), .failed(type: "auth_error"))
        XCTAssertNil(ScribeRealtime.parse(#"{"message_type":"something_new"}"#))
    }
    func testParseSessionStartedPartialAndGarbage() {
        XCTAssertEqual(ScribeRealtime.parse(#"{"message_type":"session_started","session_id":"x"}"#), .sessionStarted)
        XCTAssertEqual(ScribeRealtime.parse(#"{"message_type":"partial_transcript","text":"ho"}"#), .partial("ho"))
        XCTAssertEqual(ScribeRealtime.parse(#"{"message_type":"committed_transcript","text":"hola"}"#), .committed("hola"))
        XCTAssertNil(ScribeRealtime.parse("not json"))
        XCTAssertNil(ScribeRealtime.parse(#"{"message_type":"partial_transcript"}"#))
    }
    func testBuffersUntilStartedThenCommitsAfterAudio() {
        var turn = ScribeTurn()
        XCTAssertEqual(turn.audio(Data(count: 4800)), [])
        XCTAssertEqual(turn.release(), .wait)
        let frames = turn.started()
        XCTAssertEqual(frames.count, 2)            // buffered audio, then the commit
        XCTAssertTrue(frames.last!.contains("\"commit\":true"))
    }
    func testStreamsOnceStarted() { var t = ScribeTurn(); _ = t.started(); XCTAssertEqual(t.audio(Data(count: 10)).count, 1) }
    func testReleaseTooShort() { var t = ScribeTurn(); _ = t.started(); _ = t.audio(Data(count: 100)); XCTAssertEqual(t.release(), .tooShort) }
    func testReleaseOverflowed() {
        var t = ScribeTurn()
        _ = t.audio(Data(count: 960_001))
        XCTAssertEqual(t.release(), .overflowed)
    }
    func testFinalJoinsSegmentsAfterCommit() {
        var t = ScribeTurn(); _ = t.started(); _ = t.audio(Data(count: 4800))
        XCTAssertEqual(t.receive(.committed("primera parte")), nil)   // Scribe's own mid-utterance commit
        guard case .send = t.release() else { return XCTFail() }
        XCTAssertEqual(t.receive(.committed("y segunda")), .final("primera parte y segunda"))
    }
    func testEmptyFinalTranscript() {
        var t = ScribeTurn(); _ = t.started(); _ = t.audio(Data(count: 4800)); _ = t.release()
        XCTAssertEqual(t.receive(.committed("  ")), .final(""))
    }
    func testServerErrorFails() { var t = ScribeTurn(); XCTAssertEqual(t.receive(.failed(type: "quota_exceeded")), .failed("quota_exceeded")) }
    func testReleaseSendsOneCommitFrame() {
        var t = ScribeTurn(); _ = t.started(); _ = t.audio(Data(count: 4800))
        guard case .send(let frames) = t.release() else { return XCTFail() }
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames[0].contains("\"commit\":true"))
    }
    func testPartialsPassThroughUntilFinal() {
        var t = ScribeTurn(); _ = t.started(); _ = t.audio(Data(count: 4800))
        XCTAssertEqual(t.receive(.partial("ho")), .partial("ho"))
        _ = t.release()
        XCTAssertEqual(t.receive(.committed("hola")), .final("hola"))
        XCTAssertNil(t.receive(.partial("late")))
        XCTAssertNil(t.receive(.committed("again")))
        XCTAssertNil(t.receive(.failed(type: "error")))
    }
    func testAudioAfterReleaseIsDropped() {
        var t = ScribeTurn(); _ = t.started(); _ = t.audio(Data(count: 4800)); _ = t.release()
        XCTAssertEqual(t.audio(Data(count: 10)), [])
    }
}
