import Foundation

/// What the Mac answered to `voiceStart`: which voice mode to use and the words Scribe should expect.
public struct VoiceStartReply: Equatable {
    public var mode: VoiceMode
    public var keyterms: [String]
    /// The Mac will speak his replies (Speak Aloud is on). Fixed for the session: changing it restarts the session.
    public var speaks: Bool

    /// Anything that isn't a clear Subscription answer (no reply, an older Mac, bad JSON) means Fast.
    public init(text: String?) {
        guard let text, let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              json["mode"] as? String == VoiceMode.subscription.rawValue else {
            mode = .fast; keyterms = []; speaks = false; return
        }
        mode = .subscription
        keyterms = (json["keyterms"] as? [String]) ?? []
        speaks = json["speak"] as? Bool ?? false
    }
}

/// The phone's turn numbering for Subscription mode. The Mac tags every `voice*` packet with the number of the
/// turn it belongs to; 0 means a turn the Mac started itself (a Codex update).
public struct VoiceTurnLedger {
    public private(set) var turn = 0
    /// `voiceAsk` was sent for `turn` and the Mac hasn't finished it.
    public private(set) var awaitingReply = false
    public init() {}

    /// A new hold. Returns the turn the Mac should be told to cancel, if one is still unanswered.
    public mutating func begin() -> Int? {
        let cancel = awaitingReply ? turn : nil
        turn += 1
        awaitingReply = false
        return cancel
    }

    /// A new hold, with `audioFrom` the turn whose speech the Mac may still be sending (nil if none) and `macBusy` set
    /// when a turn the Mac started is mid-reply. Returns the turns the Mac should be told to cancel: the user's last
    /// turn if it is unanswered or still speaking, and speech 0 if a Mac turn is running.
    public mutating func beginHold(audioFrom: Int? = nil, macBusy: Bool = false) -> [Int] {
        let previous = turn
        var cancels: [Int] = []
        if let unanswered = begin() {
            cancels.append(unanswered)
        } else if let audioFrom, audioFrom == previous, audioFrom != 0 {
            cancels.append(audioFrom)
        }
        if audioFrom == 0 || (macBusy && cancels.isEmpty) { cancels.append(0) }
        return cancels
    }

    /// Whether audio for `speech` may play now. The user's own accepted turn always may, even after its text is done;
    /// a turn the Mac started plays only when no hold is in progress and no answer is awaited.
    public func mayPlay(_ speech: Int?, holding: Bool) -> Bool {
        guard accepts(speech) else { return false }
        return isUserTurn(speech) || (!holding && !awaitingReply)
    }

    /// The transcript went to the Mac.
    public mutating func asked() { awaitingReply = true }

    /// Whether a packet's `speech` belongs here: this turn, or one the Mac started.
    public func accepts(_ speech: Int?) -> Bool {
        let speech = speech ?? 0
        return speech == 0 || speech == turn
    }

    /// Whether `speech` is the user's own turn rather than one the Mac started.
    public func isUserTurn(_ speech: Int?) -> Bool { (speech ?? 0) != 0 }

    public enum Watchdog: Equatable { case rearm, stop, leave }

    /// What an accepted packet for `speech` does to the wait-for-an-answer timer. Only the user's own turn drives it:
    /// a turn the Mac started (speech 0) neither restarts it nor stops it.
    public func watchdog(after speech: Int?) -> Watchdog {
        guard isUserTurn(speech) else { return .leave }
        return awaitingReply ? .rearm : .stop
    }

    /// How long to wait for the Mac's next packet after one with this `command`. Claude is silent while a tool runs
    /// (the Mac caps that at 180 s), so a `voiceTool` buys the tool's whole cap plus a margin.
    public static func watchdogSeconds(after command: String?) -> TimeInterval {
        command == "voiceTool" ? 200 : 120
    }

    /// The Mac finished (or failed) the turn `speech`.
    public mutating func finished(_ speech: Int?) {
        if isUserTurn(speech), speech == turn { awaitingReply = false }
    }

    /// Gives up on the current turn (sleep, watchdog): anything still in flight for it is ignored from now on.
    public mutating func abandon() {
        turn += 1
        awaitingReply = false
    }
}

/// Seconds since the hold began for each step of a Subscription turn, for `bluey-voice-status.json`.
public struct VoiceTurnTimings {
    public enum Mark: String, CaseIterable {
        case scribeStarted, released, finalTranscript, firstDelta, done
    }
    private let now: () -> Date
    private var started: Date?
    private var marks: [Mark: TimeInterval] = [:]
    public init(now: @escaping () -> Date = Date.init) { self.now = now }

    /// The hold started: forget the last turn's timings.
    public mutating func begin() {
        started = now()
        marks = [:]
    }

    /// Records a step the first time it happens in a turn.
    public mutating func mark(_ mark: Mark) {
        guard let started, marks[mark] == nil else { return }
        marks[mark] = now().timeIntervalSince(started)
    }

    public var seconds: [String: Double] {
        guard started != nil else { return [:] }
        var out: [String: Double] = ["holdStarted": 0]
        for (mark, value) in marks { out[mark.rawValue] = (value * 1000).rounded() / 1000 }
        return out
    }
}
