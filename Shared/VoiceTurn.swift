import Foundation

/// What the Mac answered to `voiceStart`: which voice mode to use and the words Scribe should expect.
public struct VoiceStartReply: Equatable {
    public var mode: VoiceMode
    public var keyterms: [String]

    /// Anything that isn't a clear Subscription answer (no reply, an older Mac, bad JSON) means Fast.
    public init(text: String?) {
        guard let text, let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              json["mode"] as? String == VoiceMode.subscription.rawValue else {
            mode = .fast; keyterms = []; return
        }
        mode = .subscription
        keyterms = (json["keyterms"] as? [String]) ?? []
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

    /// The transcript went to the Mac.
    public mutating func asked() { awaitingReply = true }

    /// Whether a packet's `speech` belongs here: this turn, or one the Mac started.
    public func accepts(_ speech: Int?) -> Bool {
        let speech = speech ?? 0
        return speech == 0 || speech == turn
    }

    /// Whether `speech` is the user's own turn rather than one the Mac started.
    public func isUserTurn(_ speech: Int?) -> Bool { (speech ?? 0) != 0 }

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
