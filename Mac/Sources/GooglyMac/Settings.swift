import Foundation
import GooglyShared

/// User choices from the menu bar, kept between launches.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    var onChange: (() -> Void)?

    /// Cursor size in points (the design's default is 72).
    var cursorSize: Double {
        get { defaults.object(forKey: "cursorSize") as? Double ?? 72 }
        set { defaults.set(newValue, forKey: "cursorSize"); onChange?() }
    }

    var showCursor: Bool {
        get { defaults.object(forKey: "showCursor") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showCursor"); onChange?() }
    }

    /// Where the phone sits under the screen, 0 = left edge, 1 = right edge.
    var phonePosition: Double {
        get { defaults.object(forKey: "phonePosition") as? Double ?? 0.5 }
        set { defaults.set(newValue, forKey: "phonePosition"); onChange?() }
    }

    /// When idle, hide the big cursor and let the phone's eyes follow your own mouse.
    var followMouse: Bool {
        get { defaults.object(forKey: "followMouse") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "followMouse"); onChange?() }
    }

    var captions: Bool {
        get { defaults.object(forKey: "captions") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "captions"); onChange?() }
    }

    /// Lets him click, type, press keys and open things when you ask.
    var computerControl: Bool {
        get { defaults.object(forKey: "computerControl") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "computerControl"); onChange?() }
    }

    /// How the cursor's path shows while it flies.
    var trail: PointerTrail {
        get { PointerTrail(rawValue: defaults.string(forKey: "trail") ?? "") ?? .comet }
        set { defaults.set(newValue.rawValue, forKey: "trail"); onChange?() }
    }

    /// Fast talks through OpenAI Realtime; Subscription uses Claude and ElevenLabs.
    var voiceMode: VoiceMode {
        get { VoiceMode(rawValue: defaults.string(forKey: "voiceMode") ?? "") ?? .fast }
        set { defaults.set(newValue.rawValue, forKey: "voiceMode"); onChange?() }
    }

    /// Subscription mode reads his replies aloud (ElevenLabs) as well as showing them.
    var speakAloud: Bool {
        get { defaults.object(forKey: "speakAloud") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "speakAloud"); onChange?() }
    }

    /// His ElevenLabs voice in English. Empty until the first reply is spoken, when the default is picked and saved
    /// here (from a background thread, so this doesn't call `onChange`).
    var voiceID: String {
        get { defaults.string(forKey: "voiceID") ?? "" }
        set { defaults.set(newValue, forKey: "voiceID") }
    }

    /// His ElevenLabs voice in Spanish, saved the same way.
    var spanishVoiceID: String {
        get { defaults.string(forKey: "spanishVoiceID") ?? "" }
        set { defaults.set(newValue, forKey: "spanishVoiceID") }
    }

    /// The mood picked by hand in the menu.
    var mood: Mood {
        get { Mood(rawValue: defaults.string(forKey: "mood") ?? "") ?? .listening }
        set { defaults.set(newValue.rawValue, forKey: "mood"); onChange?() }
    }
}
