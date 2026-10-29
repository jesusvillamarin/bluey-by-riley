import Foundation

/// A decoded ElevenLabs Scribe Realtime server message.
public enum ScribeServerMessage: Equatable {
    case sessionStarted
    case partial(String)
    case committed(String)
    case failed(type: String)
}

/// Wire format of the Scribe Realtime websocket (24 kHz PCM16 mono, manual commit).
public enum ScribeRealtime {
    public static let sampleRate = 24000
    private static let errorTypes: Set<String> = [
        "error", "auth_error", "quota_exceeded", "rate_limited", "commit_throttled", "queue_overflow",
        "resource_exhausted", "input_error", "invalid_request", "chunk_size_exceeded",
        "insufficient_audio_activity", "transcriber_error", "session_time_limit_exceeded", "unaccepted_terms"
    ]

    public static func socketURL(token: String, keyterms: [String], languageCode: String?) -> URL {
        var items = [
            ("token", token), ("model_id", "scribe_v2_realtime"),
            ("audio_format", "pcm_\(sampleRate)"), ("commit_strategy", "manual")
        ]
        if let languageCode { items.append(("language_code", languageCode)) }
        items += keyterms.filter { !$0.isEmpty && $0.count <= 20 }.prefix(50).map { ("keyterms", $0) }
        let query = items.map { "\($0.0)=\(percentEncode($0.1))" }.joined(separator: "&")
        return URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime?\(query)")!
    }

    /// One websocket text frame; an empty `pcm` with `commit: true` ends the turn.
    public static func audioFrame(_ pcm: Data, commit: Bool) -> String {
        let object: [String: Any] = [
            "message_type": "input_audio_chunk", "audio_base_64": pcm.base64EncodedString(),
            "commit": commit, "sample_rate": sampleRate
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Returns nil for malformed or unknown message types.
    public static func parse(_ text: String) -> ScribeServerMessage? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = json["message_type"] as? String else { return nil }
        switch type {
        case "session_started": return .sessionStarted
        case "partial_transcript": return (json["text"] as? String).map { .partial($0) }
        case "committed_transcript", "committed_transcript_with_timestamps": return (json["text"] as? String).map { .committed($0) }
        case let type where errorTypes.contains(type): return .failed(type: type)
        default: return nil
        }
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? value
    }
}

/// One held push-to-talk utterance: buffers audio until the socket is ready, commits on release.
public struct ScribeTurn {
    public enum Release: Equatable { case send([String]), wait, tooShort, overflowed }
    public enum Event: Equatable { case partial(String), final(String), failed(String) }
    private var buffer = VoiceTurnBuffer()
    private var isStarted = false
    private var isReleased = false
    private var commitSent = false
    private var finished = false
    private var segments: [String] = []
    public init() {}

    /// Frames to send now for newly captured audio (none while Scribe is still starting).
    public mutating func audio(_ pcm: Data) -> [String] {
        guard !isReleased else { return [] }
        return buffer.append(pcm, ready: isStarted).map { [ScribeRealtime.audioFrame($0, commit: false)] } ?? []
    }

    /// `session_started` arrived: flush buffered audio, then the commit if the key was already released.
    public mutating func started() -> [String] {
        isStarted = true
        var frames = buffer.connected().map { ScribeRealtime.audioFrame($0, commit: false) }
        if isReleased, buffer.canCommit { frames.append(commitFrame()) }
        return frames
    }

    public mutating func release() -> Release {
        guard !isReleased else { return .wait }
        if buffer.overflowed { return .overflowed }
        guard buffer.canCommit else { return .tooShort }
        isReleased = true
        return isStarted ? .send([commitFrame()]) : .wait
    }

    public mutating func receive(_ message: ScribeServerMessage) -> Event? {
        guard !finished else { return nil }
        switch message {
        case .sessionStarted: return nil
        case .partial(let text): return .partial(text)
        case .committed(let text):
            segments.append(text)
            guard commitSent else { return nil }
            finished = true
            return .final(segments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines))
        case .failed(let type):
            finished = true
            return .failed(type)
        }
    }

    private mutating func commitFrame() -> String {
        commitSent = true
        return ScribeRealtime.audioFrame(Data(), commit: true)
    }
}
