import XCTest
@testable import GooglyShared

final class VoicePlaybackTests: XCTestCase {
    /// `count` samples of silence as the base64 the Mac would send.
    private func pcm(_ count: Int = 100) -> String { Data(count: count * 2).base64EncodedString() }

    func testPCM16ConvertsToFloat() {
        // 0, 16384 (0.5), -16384 (-0.5), -32768 (-1), little-endian.
        let data = Data([0x00, 0x00, 0x00, 0x40, 0x00, 0xC0, 0x00, 0x80])
        XCTAssertEqual(VoicePlayback.samples(fromPCM16: data), [0, 0.5, -0.5, -1])
    }

    func testOddTrailingByteIsDropped() {
        XCTAssertEqual(VoicePlayback.samples(fromPCM16: Data([0x00, 0x40, 0x7F])), [0.5])
        XCTAssertEqual(VoicePlayback.samples(fromPCM16: Data([0x7F])), [])
        XCTAssertEqual(VoicePlayback.samples(fromPCM16: Data()), [])
    }

    func testConversionIgnoresTheDataSliceOffset() {
        let whole = Data([0xFF, 0xFF, 0x00, 0x40, 0x00, 0x40])
        XCTAssertEqual(VoicePlayback.samples(fromPCM16: whole.dropFirst(2)), [0.5, 0.5])
    }

    func testBadOrEmptyChunksAreNotScheduled() {
        var playback = VoicePlayback()
        XCTAssertNil(playback.chunk(base64: nil, speech: 1))
        XCTAssertNil(playback.chunk(base64: "not base64!!", speech: 1))
        XCTAssertNil(playback.chunk(base64: Data([0x01]).base64EncodedString(), speech: 1), "half a sample")
        XCTAssertFalse(playback.isActive, "nothing scheduled, so nothing to wait for")
    }

    func testSpeechFinishesAfterTheEndAndTheLastBufferPlays() {
        var playback = VoicePlayback()
        let first = playback.chunk(base64: pcm(), speech: 1)!
        let second = playback.chunk(base64: pcm(), speech: 1)!
        XCTAssertTrue(playback.isActive)
        XCTAssertTrue(playback.macMaySend)
        XCTAssertFalse(playback.played(generation: first.generation), "more is still queued")
        XCTAssertFalse(playback.end(), "a buffer is still playing")
        XCTAssertTrue(playback.isDraining)
        XCTAssertFalse(playback.macMaySend)
        XCTAssertTrue(playback.played(generation: second.generation), "the last buffer after the end")
        XCTAssertFalse(playback.isActive)
    }

    func testBuffersFinishingBeforeTheEndDoNotEndTheSpeech() {
        var playback = VoicePlayback()
        let chunk = playback.chunk(base64: pcm(), speech: 1)!
        XCTAssertFalse(playback.played(generation: chunk.generation), "the Mac may still send more (a tool call between lines)")
        XCTAssertTrue(playback.isActive)
        XCTAssertTrue(playback.end(), "everything had already played")
    }

    func testResetIgnoresBuffersFromBefore() {
        var playback = VoicePlayback()
        let old = playback.chunk(base64: pcm(), speech: 1)!
        playback.reset()
        XCTAssertFalse(playback.isActive)
        XCTAssertFalse(playback.played(generation: old.generation), "the stopped player reports its buffers as done")
        let fresh = playback.chunk(base64: pcm(), speech: 2)!
        XCTAssertNotEqual(fresh.generation, old.generation)
        XCTAssertFalse(playback.played(generation: old.generation))
        XCTAssertTrue(playback.isActive, "the stale callback didn't touch the new speech")
    }

    func testEndWithoutChunksDoesNothing() {
        var playback = VoicePlayback()
        XCTAssertFalse(playback.end())
        XCTAssertFalse(playback.isActive)
    }

    func testReplyWhileAudioIsPlayingLeavesItToTheAudio() {
        var playback = VoicePlayback()
        _ = playback.chunk(base64: pcm(), speech: 1)
        XCTAssertEqual(playback.replyEnded(speech: 1, mayHaveAudio: true), .playing)
    }

    func testReplyAfterTheSpeechAlreadyEndedButStillPlaying() {
        var playback = VoicePlayback()
        _ = playback.chunk(base64: pcm(), speech: 1)
        _ = playback.end()
        XCTAssertEqual(playback.replyEnded(speech: 1, mayHaveAudio: true), .playing)
    }

    func testReplyWithNoAudioYetWaitsOneGraceThenIsTextOnly() {
        var playback = VoicePlayback()
        XCTAssertEqual(playback.replyEnded(speech: 3, mayHaveAudio: true), .waitForAudio)
        XCTAssertTrue(playback.isActive)
        XCTAssertTrue(playback.macMaySend, "a hold now must cancel it, the Mac may be about to speak")
        XCTAssertEqual(playback.speech, 3)
        XCTAssertTrue(playback.graceElapsed(), "no sound ever came")
        XCTAssertFalse(playback.isActive)
        XCTAssertFalse(playback.graceElapsed(), "only once")
    }

    func testAudioDuringTheGraceMeansItIsNotTextOnly() {
        var playback = VoicePlayback()
        XCTAssertEqual(playback.replyEnded(speech: 3, mayHaveAudio: true), .waitForAudio)
        _ = playback.chunk(base64: pcm(), speech: 3)
        XCTAssertFalse(playback.graceElapsed(), "the sound took over")
        XCTAssertTrue(playback.isActive)
    }

    func testEmptyReplyOrErrorWithoutAudioFinishesAtOnce() {
        var playback = VoicePlayback()
        XCTAssertEqual(playback.replyEnded(speech: 1, mayHaveAudio: false), .finished)
        XCTAssertFalse(playback.isActive)
    }

    func testResetDuringTheGraceEndsIt() {
        var playback = VoicePlayback()
        _ = playback.replyEnded(speech: 1, mayHaveAudio: true)
        playback.reset()
        XCTAssertFalse(playback.graceElapsed())
        XCTAssertFalse(playback.isActive)
    }

    func testASecondSpeechAfterTheFirstEnded() {
        var playback = VoicePlayback()
        let first = playback.chunk(base64: pcm(), speech: 0)!
        _ = playback.end()
        XCTAssertTrue(playback.played(generation: first.generation))
        let second = playback.chunk(base64: pcm(), speech: 0)!
        XCTAssertTrue(playback.isActive)
        XCTAssertFalse(playback.end(), "the second buffer is still playing")
        XCTAssertTrue(playback.played(generation: second.generation))
    }

    // MARK: The ledger's part

    func testHoldCancelsTheUnansweredTurn() {
        var ledger = VoiceTurnLedger()
        _ = ledger.beginHold()
        ledger.asked()
        XCTAssertEqual(ledger.beginHold(), [1])
    }

    func testHoldCancelsAFinishedTurnWhoseSpeechIsStillComing() {
        var ledger = VoiceTurnLedger()
        _ = ledger.beginHold()
        ledger.asked()
        ledger.finished(1)
        XCTAssertEqual(ledger.beginHold(audioFrom: 1), [1], "voiceDone is out but the Mac is still speaking")
    }

    func testHoldDoesNotCancelAFinishedAndEndedTurn() {
        var ledger = VoiceTurnLedger()
        _ = ledger.beginHold()
        ledger.asked()
        ledger.finished(1)
        XCTAssertEqual(ledger.beginHold(), [])
    }

    func testHoldCancelsAMacTurnThatIsSpeaking() {
        var ledger = VoiceTurnLedger()
        XCTAssertEqual(ledger.beginHold(audioFrom: 0), [0])
        XCTAssertEqual(ledger.beginHold(macBusy: true), [0], "mid-reply, no audio yet")
    }

    func testHoldCancelsOnlyTheLiveSpeechNotAnOlderTurnNumber() {
        var ledger = VoiceTurnLedger()
        _ = ledger.beginHold()
        ledger.asked()
        ledger.finished(1)
        _ = ledger.beginHold()
        XCTAssertEqual(ledger.beginHold(audioFrom: 1), [], "turn 1's audio belongs to an older hold; the Mac was told then")
    }

    func testAudioPlaysForTheUsersTurnEvenAfterItsTextIsDone() {
        var ledger = VoiceTurnLedger()
        _ = ledger.beginHold()
        ledger.asked()
        ledger.finished(1)
        XCTAssertTrue(ledger.mayPlay(1, holding: false))
        XCTAssertFalse(ledger.mayPlay(2, holding: false))
    }

    func testOldTurnsAudioIsRefusedAfterAHoldBegins() {
        var ledger = VoiceTurnLedger()
        _ = ledger.beginHold()
        ledger.asked()
        _ = ledger.beginHold()
        XCTAssertFalse(ledger.mayPlay(1, holding: true))
        XCTAssertFalse(ledger.mayPlay(1, holding: false))
    }

    func testMacTurnsPlayOnlyWhenNoHoldAndNoAnswerAwaited() {
        var ledger = VoiceTurnLedger()
        XCTAssertTrue(ledger.mayPlay(0, holding: false))
        XCTAssertTrue(ledger.mayPlay(nil, holding: false))
        XCTAssertFalse(ledger.mayPlay(0, holding: true))
        _ = ledger.beginHold()
        ledger.asked()
        XCTAssertFalse(ledger.mayPlay(0, holding: false), "he is waiting for the user's answer")
        ledger.finished(1)
        XCTAssertTrue(ledger.mayPlay(0, holding: false))
    }
}
