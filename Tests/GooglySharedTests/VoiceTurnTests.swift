import XCTest
@testable import GooglyShared

final class VoiceTurnTests: XCTestCase {
    func testStartReply() {
        let reply = VoiceStartReply(text: #"{"mode":"subscription","keyterms":["Bluey","Codex"]}"#)
        XCTAssertEqual(reply.mode, .subscription)
        XCTAssertEqual(reply.keyterms, ["Bluey", "Codex"])
        XCTAssertFalse(reply.speaks, "no flag means text only")
        XCTAssertTrue(VoiceStartReply(text: #"{"mode":"subscription","speak":true}"#).speaks)
        XCTAssertFalse(VoiceStartReply(text: #"{"mode":"subscription","speak":false}"#).speaks)
        XCTAssertFalse(VoiceStartReply(text: #"{"mode":"fast","speak":true}"#).speaks, "Fast never plays the Mac's voice")
        XCTAssertEqual(VoiceStartReply(text: #"{"mode":"fast"}"#).mode, .fast)
        XCTAssertEqual(VoiceStartReply(text: nil).mode, .fast)
        XCTAssertEqual(VoiceStartReply(text: "nope").mode, .fast)
        XCTAssertEqual(VoiceStartReply(text: #"{"mode":"other"}"#).mode, .fast)
    }

    func testAcceptsCurrentTurnAndMacTurnsOnly() {
        var ledger = VoiceTurnLedger()
        XCTAssertNil(ledger.begin())
        XCTAssertEqual(ledger.turn, 1)
        XCTAssertTrue(ledger.accepts(1))
        XCTAssertTrue(ledger.accepts(0))
        XCTAssertTrue(ledger.accepts(nil))
        XCTAssertFalse(ledger.accepts(2))
        XCTAssertNil(ledger.begin())
        XCTAssertFalse(ledger.accepts(1), "a packet from the old turn is dropped")
        XCTAssertTrue(ledger.accepts(2))
    }

    func testHoldingAgainCancelsOnlyAnUnansweredTurn() {
        var ledger = VoiceTurnLedger()
        _ = ledger.begin()
        XCTAssertNil(ledger.begin(), "turn 1 was never asked: nothing to cancel on the Mac")
        ledger.asked()
        XCTAssertEqual(ledger.begin(), 2)
        ledger.asked()
        ledger.finished(3)
        XCTAssertNil(ledger.begin(), "turn 3 was answered")
    }

    func testMacTurnsDoNotCloseTheUsersTurn() {
        var ledger = VoiceTurnLedger()
        _ = ledger.begin()
        ledger.asked()
        ledger.finished(0)
        XCTAssertTrue(ledger.awaitingReply)
        XCTAssertFalse(ledger.isUserTurn(0))
        ledger.finished(1)
        XCTAssertFalse(ledger.awaitingReply)
    }

    func testOnlyTheUsersTurnTouchesTheWatchdog() {
        var ledger = VoiceTurnLedger()
        _ = ledger.begin()
        ledger.asked()
        XCTAssertEqual(ledger.watchdog(after: 1), .rearm)
        XCTAssertEqual(ledger.watchdog(after: 0), .leave, "a Codex turn's packets don't count as the answer making progress")
        XCTAssertEqual(ledger.watchdog(after: nil), .leave)
        ledger.finished(0)
        XCTAssertEqual(ledger.watchdog(after: 0), .leave)
        ledger.finished(1)
        XCTAssertEqual(ledger.watchdog(after: 1), .stop)
        XCTAssertEqual(ledger.watchdog(after: 0), .leave, "and they don't cancel it either")
    }

    func testAToolStartBuysTheWholeToolCapBeforeTheWatchdogFires() {
        // The Mac caps a tool at 180 s of silence from claude; the phone must wait longer than that after voiceTool.
        XCTAssertGreaterThan(VoiceTurnLedger.watchdogSeconds(after: "voiceTool"), 180)
        XCTAssertEqual(VoiceTurnLedger.watchdogSeconds(after: "voiceDelta"), 120)
        XCTAssertEqual(VoiceTurnLedger.watchdogSeconds(after: nil), 120)
    }

    func testAbandonDropsLatePackets() {
        var ledger = VoiceTurnLedger()
        _ = ledger.begin()
        ledger.asked()
        ledger.abandon()
        XCTAssertFalse(ledger.accepts(1))
        XCTAssertFalse(ledger.awaitingReply)
        XCTAssertNil(ledger.begin())
    }

    func testTimingsCountFromTheHoldAndKeepTheFirstMark() {
        var clock = Date(timeIntervalSince1970: 100)
        var timings = VoiceTurnTimings(now: { clock })
        timings.mark(.released)
        XCTAssertEqual(timings.seconds, [:], "nothing before a hold")
        timings.begin()
        clock += 1.25
        timings.mark(.released)
        clock += 0.5
        timings.mark(.firstDelta)
        clock += 9
        timings.mark(.firstDelta)
        XCTAssertEqual(timings.seconds, ["holdStarted": 0, "released": 1.25, "firstDelta": 1.75], "later repeats are ignored")
        timings.begin()
        XCTAssertEqual(timings.seconds, ["holdStarted": 0])
    }
}
