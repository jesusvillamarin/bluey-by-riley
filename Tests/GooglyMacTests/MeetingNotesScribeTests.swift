import XCTest
@testable import GooglyMac

final class MeetingNotesScribeTests: XCTestCase {
    private func word(_ text: String, _ start: Double, _ end: Double, _ speaker: String? = "speaker_0") -> [String: Any] {
        var w: [String: Any] = ["text": text, "type": "word", "start": start, "end": end]
        if let speaker { w["speaker_id"] = speaker }
        return w
    }

    private func space(_ start: Double, _ end: Double, _ speaker: String? = "speaker_0") -> [String: Any] {
        var w: [String: Any] = ["text": " ", "type": "spacing", "start": start, "end": end]
        if let speaker { w["speaker_id"] = speaker }
        return w
    }

    func testTwoSpeakersAlternating() {
        let words = [
            word("Hello", 0, 0.4), space(0.4, 0.5), word("there.", 0.5, 1.0),
            space(1.0, 1.2, "speaker_1"), word("Hi!", 1.2, 1.6, "speaker_1"),
            space(1.6, 1.8, "speaker_0"), word("Ready?", 1.8, 2.4),
        ]
        let segments = MeetingNotes.segments(fromScribeWords: words)
        XCTAssertEqual(segments.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 1"])
        XCTAssertEqual(segments.map(\.text), ["Hello there.", "Hi!", "Ready?"])
        XCTAssertEqual(segments.map(\.start), [0, 1.2, 1.8])
        XCTAssertEqual(segments.map(\.end), [1.0, 1.6, 2.4])
    }

    func testSpeakersNumberedByFirstAppearance() {
        let words = [word("a", 0, 1, "speaker_3"), word("b", 1, 2, "speaker_0")]
        XCTAssertEqual(MeetingNotes.segments(fromScribeWords: words).map(\.speaker), ["Speaker 1", "Speaker 2"])
    }

    func testShortGapSameSpeakerMerges() {
        let words = [word("First", 0, 1), space(1, 2), word("second", 2, 3)]
        let segments = MeetingNotes.segments(fromScribeWords: words)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "First second")
        XCTAssertEqual(segments[0].end, 3)
    }

    func testLongGapSameSpeakerStaysSeparate() {
        let words = [word("First", 0, 1), word("second", 4, 5)]
        let segments = MeetingNotes.segments(fromScribeWords: words)
        XCTAssertEqual(segments.map(\.text), ["First", "second"])
        XCTAssertEqual(segments.map(\.speaker), ["Speaker 1", "Speaker 1"])
    }

    func testAudioEventsAndSpacingNeverAppearInText() {
        let words: [[String: Any]] = [
            word("Well", 0, 0.5),
            ["text": "(laughter)", "type": "audio_event", "start": 0.5, "end": 1.0, "speaker_id": "speaker_0"],
            space(1.0, 1.1), word("okay.", 1.1, 1.6),
        ]
        let segments = MeetingNotes.segments(fromScribeWords: words)
        XCTAssertEqual(segments.map(\.text), ["Well okay."])
    }

    func testMissingSpeakerIsOneSpeaker() {
        let words = [word("No", 0, 0.5, nil), word("labels", 0.6, 1.0, nil)]
        let segments = MeetingNotes.segments(fromScribeWords: words)
        XCTAssertEqual(segments.map(\.speaker), ["Speaker 1"])
        XCTAssertEqual(segments.map(\.text), ["No labels"])
    }

    func testPunctuationStaysAttachedWithoutSpacingEntries() {
        let words = [word("Hello,", 0, 0.5), word("world.", 0.6, 1.0)]
        XCTAssertEqual(MeetingNotes.segments(fromScribeWords: words).map(\.text), ["Hello, world."])
    }

    func testNoWordsNoSegments() {
        XCTAssertTrue(MeetingNotes.segments(fromScribeWords: []).isEmpty)
        XCTAssertTrue(MeetingNotes.segments(fromScribeWords: [space(0, 1)]).isEmpty)
    }

    func testScribeRequestFields() throws {
        let request = MeetingNotes.scribeRequest(audio: Data("abc".utf8), key: "k", boundary: "B")
        XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/speech-to-text")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "k")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=B")
        XCTAssertEqual(request.timeoutInterval, 300)
        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        for (name, value) in ["model_id": "scribe_v2", "diarize": "true", "timestamps_granularity": "word", "tag_audio_events": "false"] {
            XCTAssertTrue(body.contains("name=\"\(name)\"\r\n\r\n\(value)\r\n"), name)
        }
        XCTAssertFalse(body.contains("language_code"))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"chunk.m4a\""))
    }
}
