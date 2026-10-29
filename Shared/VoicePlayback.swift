import Foundation

/// Bookkeeping for the audio the Mac sends in Subscription mode (`voiceAudio` chunks, then `voiceAudioEnd`): which
/// chunks to schedule, when the speech has finished playing, and what a new hold throws away. `LiveVoice` does the
/// scheduling; this decides.
///
/// Audio can start before `voiceDone` and keep coming after it, and a turn that was cut off never gets an end, so a
/// hold always calls `reset()` instead of waiting for one.
public struct VoicePlayback {
    /// With Speak Aloud on, a reply that ends with no audio yet gets this long (seconds) to start speaking before it
    /// counts as text only (speech failed). Generous: a cold connection can make the first sound slow.
    public static let audioGrace: TimeInterval = 4
    /// The longest `sleep` waits for a goodbye that is still playing.
    public static let sleepCap: TimeInterval = 8

    /// One chunk ready to schedule. Pass `generation` back to `played` so a chunk from before a `reset()` is ignored.
    public struct Chunk {
        public let samples: [Float]
        public let generation: Int
    }

    /// What a reply that just ended means for the sound.
    public enum Reply: Equatable {
        /// Nothing is playing and nothing more is coming.
        case finished
        /// Sound is playing or coming: its end, not the reply, brings him back to listening.
        case playing
        /// No sound yet, but some may start: call `graceElapsed()` after `audioGrace`.
        case waitForAudio
    }

    public private(set) var generation = 0
    /// The turn the sound belongs to (0 for one the Mac started).
    public private(set) var speech: Int?
    /// Scheduled chunks that haven't finished playing.
    private var pending = 0
    /// Chunks have arrived for a turn whose `voiceAudioEnd` hasn't.
    private var open = false
    /// A reply ended without sound and the grace period isn't over.
    private var waiting = false

    public init() {}

    /// Sound is playing, or may still start.
    public var isActive: Bool { pending > 0 || open || waiting }
    /// The Mac may still send audio for `speech`, so a new hold should tell it to stop.
    public var macMaySend: Bool { open || waiting }
    /// Everything has arrived and is only playing out.
    public var isDraining: Bool { pending > 0 && !open }

    /// PCM16 little-endian mono to Float32 samples. A trailing odd byte is half a sample: dropped.
    public static func samples(fromPCM16 data: Data) -> [Float] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        let base = data.startIndex
        return (0..<count).map { i in
            let value = UInt16(data[base + 2 * i]) | UInt16(data[base + 2 * i + 1]) << 8
            return Float(Int16(bitPattern: value)) / 32768
        }
    }

    /// A `voiceAudio` packet's payload. Nil when there is nothing to play (bad base64, or less than one sample).
    public mutating func chunk(base64: String?, speech: Int?) -> Chunk? {
        guard let base64, let data = Data(base64Encoded: base64) else { return nil }
        let samples = Self.samples(fromPCM16: data)
        guard !samples.isEmpty else { return nil }
        self.speech = speech
        open = true
        waiting = false
        pending += 1
        return Chunk(samples: samples, generation: generation)
    }

    /// A scheduled chunk finished playing. True when that was the last of the speech.
    public mutating func played(generation: Int) -> Bool {
        guard generation == self.generation, pending > 0 else { return false }
        pending -= 1
        return !isActive
    }

    /// `voiceAudioEnd`: no more chunks for the turn. True when it has all been played already.
    public mutating func end() -> Bool {
        guard open else { return false }
        open = false
        return !isActive
    }

    /// `voiceDone` or `voiceError` for a turn. Text to say may be followed by audio the Mac is still making; an error
    /// is not, and neither is a reply with nothing to say.
    public mutating func replyEnded(speech: Int?, mayHaveAudio: Bool) -> Reply {
        if open || pending > 0 { return .playing }
        guard mayHaveAudio else { return .finished }
        self.speech = speech
        waiting = true
        return .waitForAudio
    }

    /// The grace period passed. True when no sound ever came, so the reply stays text only.
    public mutating func graceElapsed() -> Bool {
        guard waiting else { return false }
        waiting = false
        return true
    }

    /// A new hold or sleep: drops everything queued and ignores whatever is still in flight.
    public mutating func reset() {
        generation += 1
        pending = 0
        open = false
        waiting = false
        speech = nil
    }
}
