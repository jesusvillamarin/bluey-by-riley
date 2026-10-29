import Foundation

/// Turns recorded audio into a proper transcript and keeps each session's
/// meeting notes as plain files any agent can read: ~/Documents/Bluey Notes/<date> <id>/.
enum MeetingNotes {
    static let model = "gpt-transcribe"

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bluey Notes", isDirectory: true)
    }

    struct Segment {
        var speaker: String
        var start: Double
        var end: Double
        var text: String
    }

    // MARK: Folders

    /// The session's folder, made the first time it's needed.
    static func folder(session: String, started: Date) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        writeReadmeIfNeeded()
        let tag = String(session.prefix(8)).lowercased()
        if let existing = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .first(where: { $0.lastPathComponent.hasSuffix(tag) }) {
            return existing
        }
        let name = DateFormatter.folderName.string(from: started) + " " + tag
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: url.appendingPathComponent("audio"), withIntermediateDirectories: true)
        return url
    }

    private static func writeReadmeIfNeeded() {
        let url = root.appendingPathComponent("README.md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let text = """
        # Bluey Notes

        Meeting notes recorded by Riley's Bluey app (the blueberry on the iPhone). One folder per listening \
        session, named by start time.

        In each session folder:
        - `notes.md`: the full transcript with timestamps, plus Riley's questions to Bluey, \
        Bluey's replies and any research reports, in time order. Start here.
        - `session.json`: the same data, structured.
        - `audio/`: the raw recording, as five-minute AAC chunks.

        Speakers are told apart only when an ElevenLabs key is set (numbered per five-minute chunk, so the same number can mean different people in different chunks); otherwise each chunk is one block of text. Lines marked "(live)" are a rough live transcript for audio that hasn't been fully \
        transcribed yet.
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Transcription

    /// Saves the chunk's audio into the session folder and transcribes it.
    static func transcribe(audio: Data, session: String, index: Int, sessionStarted: Date) async throws -> (segments: [Segment], folder: URL) {
        let folder = folder(session: session, started: sessionStarted)
        let audioURL = folder.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioURL, withIntermediateDirectories: true)
        try audio.write(to: audioURL.appendingPathComponent(String(format: "chunk-%03d.m4a", index)))
        if Keychain.get(.elevenlabs) != nil {
            // No fallback to OpenAI if Scribe fails: the phone's retry handles it, and nothing else gets billed.
            return (try await scribeBatch(audio: audio), folder)
        }
        let json = try await post(audio, fields: ["model": model, "response_format": "json"])
        let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (text.isEmpty ? [] : [Segment(speaker: "?", start: 0, end: 0, text: text)], folder)
    }

    private static func post(_ audio: Data, fields: [String: String]) async throws -> [String: Any] {
        guard let key = Keychain.get(.openai) else { throw RealtimeHost.TokenError.noKey }
        let request = multipartRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
                                       headers: ["Authorization": "Bearer \(key)"], fields: fields, audio: audio)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RealtimeHost.TokenError.failed("transcription \(code) " + (String(data: data, encoding: .utf8) ?? ""))
        }
        return json
    }

    /// A POST with the form fields and the audio as `file`.
    private static func multipartRequest(url: URL, headers: [String: String], fields: [String: String], audio: Data,
                                         boundary: String = "googly-\(UUID().uuidString)") -> URLRequest {
        var body = Data()
        for (name, value) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"chunk.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    // MARK: Scribe v2 batch

    /// Transcribes with ElevenLabs Scribe v2, speakers told apart. Language is left to auto-detect.
    static func scribeBatch(audio: Data) async throws -> [Segment] {
        guard let key = Keychain.get(.elevenlabs) else { throw ElevenLabs.Failure.noKey }
        let (data, response) = try await URLSession.shared.data(for: scribeRequest(audio: audio, key: key))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RealtimeHost.TokenError.failed("scribe transcription \(code) " + (String(data: data, encoding: .utf8) ?? ""))
        }
        return segments(fromScribeWords: json["words"] as? [[String: Any]] ?? [])
    }

    static func scribeRequest(audio: Data, key: String, boundary: String = "googly-\(UUID().uuidString)") -> URLRequest {
        multipartRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!, headers: ["xi-api-key": key],
                         fields: ["model_id": "scribe_v2", "diarize": "true", "timestamps_granularity": "word", "tag_audio_events": "false"],
                         audio: audio, boundary: boundary)
    }

    /// One line per speaker turn, from Scribe's word list. Speakers are "Speaker 1", "Speaker 2"… in order of first appearance;
    /// a turn ends when the speaker changes or after a pause of 2.5 s or more.
    static func segments(fromScribeWords words: [[String: Any]]) -> [Segment] {
        var turns: [Segment] = []
        var order: [String] = []
        var spaced = true
        for word in words {
            let text = word["text"] as? String ?? ""
            switch word["type"] as? String {
            case "audio_event":
                continue
            case "spacing":
                if var last = turns.last { last.text += text; turns[turns.count - 1] = last }
                spaced = true
                continue
            default:
                break
            }
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let id = word["speaker_id"] as? String ?? ""
            if !order.contains(id) { order.append(id) }
            let speaker = "Speaker \(order.firstIndex(of: id)! + 1)"
            let start = (word["start"] as? Double) ?? 0
            let end = (word["end"] as? Double) ?? start
            if var last = turns.last, last.speaker == speaker, start - last.end < 2.5 {
                last.text += (spaced ? "" : " ") + text
                last.end = end
                turns[turns.count - 1] = last
            } else {
                turns.append(Segment(speaker: speaker, start: start, end: end, text: text))
            }
            spaced = false
        }
        return turns.map { Segment(speaker: $0.speaker, start: $0.start, end: $0.end,
                                   text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    // MARK: Notes files

    /// Writes session.json and notes.md from the phone's copy of the session. Returns the folder.
    @discardableResult
    static func write(session json: [String: Any]) -> URL? {
        guard let id = json["id"] as? String, let startedAt = json["started"] as? Double else { return nil }
        let started = Date(timeIntervalSince1970: startedAt)
        let folder = folder(session: id, started: started)
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("session.json"), options: .atomic)
        }
        try? markdown(json, started: started).write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        return folder
    }

    private static func markdown(_ json: [String: Any], started: Date) -> String {
        let ended = (json["ended"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let entries = json["entries"] as? [[String: Any]] ?? []
        let pending = json["transcribing"] as? Int ?? 0
        let day = DateFormatter()
        day.dateStyle = .full
        day.timeStyle = .short
        let clock = DateFormatter()
        clock.dateFormat = "h:mm:ss a"

        var out = ["# Bluey session: \(day.string(from: started))", ""]
        if let ended {
            let minutes = Int(ended.timeIntervalSince(started) / 60)
            out.append("Ended \(clock.string(from: ended)) (\(minutes / 60)h \(minutes % 60)m).")
        } else {
            out.append("Still recording.")
        }
        if pending > 0 { out.append("\(pending) recording chunk(s) still being transcribed; this file updates when they're done.") }
        let asked = entries.filter { $0["kind"] as? String == "asked" }.count
        if asked > 0 { out.append("Riley asked Bluey \(asked) question(s); they're marked inline below.") }
        out += ["", "## Transcript", ""]

        for entry in entries {
            let text = (entry["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let time = (entry["time"] as? Double).map { clock.string(from: Date(timeIntervalSince1970: $0)) } ?? ""
            switch entry["kind"] as? String {
            case "transcript":
                out.append("**[\(time)] Speaker \(entry["speaker"] as? String ?? "?"):** \(text)")
            case "heard":
                out.append("[\(time)] (live) \(text)")
            case "asked":
                out.append("> **[\(time)] Riley asked Bluey:** \(text)")
            case "reply":
                out.append("> **Bluey:** \(text)")
            case "codex":
                out.append("> **[\(time)] Codex:** \(text)")
            case "report":
                let quoted = text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
                out.append("> **Research report:**\n" + quoted)
            default:
                out.append("[\(time)] \(text)")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}

private extension DateFormatter {
    static let folderName: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()
}
