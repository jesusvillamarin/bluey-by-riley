import Foundation

/// How Bluey hears and thinks: OpenAI Realtime, or Claude CLI with ElevenLabs Scribe.
public enum VoiceMode: String, Codable, Sendable {
    case fast, subscription
}
