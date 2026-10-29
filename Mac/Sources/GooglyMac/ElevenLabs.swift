import Foundation

enum ElevenLabs {
    enum Failure: LocalizedError {
        case noKey, noVoice, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .noKey: return "I need an ElevenLabs API key. Add one under ElevenLabs Key in the menu bar."
            case .noVoice: return "ElevenLabs has no voice for me to use. Pick one under Voice in the menu bar."
            case .http(let status, let body): return "ElevenLabs said \(status): \(body.prefix(160))"
            }
        }
    }

    /// A single-use token (15 minutes to start a session), so the real key never leaves the Mac.
    static func mintToken(_ type: String) async throws -> String {
        guard let key = Keychain.get(.elevenlabs) else { throw Failure.noKey }
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/single-use-token/\(type)")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Failure.http(code, String(data: data, encoding: .utf8) ?? "") }
        struct Minted: Decodable { let token: String }
        return try JSONDecoder().decode(Minted.self, from: data).token
    }

    // MARK: Speech

    static let speechModel = "eleven_flash_v2_5"
    /// 0.25 s of PCM16 at 24 kHz mono, an even number of bytes so every chunk holds whole samples.
    static let chunkBytes = 12_000

    /// The text-to-speech request: raw PCM16 24 kHz mono in the response body. No `language_code`: Flash v2.5 follows the text.
    static func speechRequest(_ text: String, voiceID: String, apiKey: String) -> URLRequest {
        let voice = voiceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? voiceID
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice)/stream?output_format=pcm_24000")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "model_id": speechModel], options: [.sortedKeys])
        return request
    }

    /// The spoken text as PCM16 chunks of about 0.25 s, the last one shorter. Ending the stream early (the caller
    /// stops iterating or its task is cancelled) cancels the HTTP request.
    static func speech(_ text: String, voiceID: String, session: URLSession = .shared,
                       apiKey: String? = Keychain.get(.elevenlabs)) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    guard let apiKey else { throw Failure.noKey }
                    guard !voiceID.isEmpty else { throw Failure.noVoice }
                    let (bytes, response) = try await session.bytes(for: speechRequest(text, voiceID: voiceID, apiKey: apiKey))
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(code) else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte); if body.count >= 400 { break } }
                        throw Failure.http(code, String(decoding: body, as: UTF8.self))
                    }
                    var chunk = Data()
                    chunk.reserveCapacity(chunkBytes)
                    for try await byte in bytes {
                        chunk.append(byte)
                        if chunk.count == chunkBytes { continuation.yield(chunk); chunk.removeAll(keepingCapacity: true) }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    // MARK: Voices

    /// A premade voice and the languages ElevenLabs has verified it for with `speechModel`.
    struct Voice: Equatable {
        let id: String
        let name: String
        let languages: Set<String>
    }

    /// One page of `GET /v2/voices`. Tolerant: entries without an id are skipped; a verified language counts for
    /// Flash v2.5 when its `model_id` says so or is missing.
    static func parseVoices(_ data: Data) throws -> (voices: [Voice], next: String?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.http(200, "Unexpected voices reply") }
        let voices = (root["voices"] as? [[String: Any]] ?? []).compactMap { entry -> Voice? in
            guard let id = entry["voice_id"] as? String, !id.isEmpty else { return nil }
            let languages = (entry["verified_languages"] as? [[String: Any]] ?? []).compactMap { verified -> String? in
                guard verified["model_id"] as? String ?? speechModel == speechModel,
                      let language = (verified["language"] as? String)?.lowercased(), !language.isEmpty else { return nil }
                return language
            }
            return Voice(id: id, name: entry["name"] as? String ?? id, languages: Set(languages))
        }
        let hasMore = root["has_more"] as? Bool ?? false
        return (voices, hasMore ? root["next_page_token"] as? String : nil)
    }

    /// Every premade voice, in the order ElevenLabs lists them. The `language` filter of the API matches a voice's
    /// label rather than its verified languages, so filtering is done here.
    static func listVoices(session: URLSession = .shared, apiKey: String? = Keychain.get(.elevenlabs)) async throws -> [Voice] {
        guard let apiKey else { throw Failure.noKey }
        var voices: [Voice] = []
        var token: String?
        for _ in 0..<5 {
            var components = URLComponents(string: "https://api.elevenlabs.io/v2/voices")!
            components.queryItems = [URLQueryItem(name: "category", value: "premade"), URLQueryItem(name: "page_size", value: "100")]
                + (token.map { [URLQueryItem(name: "next_page_token", value: $0)] } ?? [])
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 20
            request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw Failure.http(code, String(decoding: data, as: UTF8.self)) }
            let page = try parseVoices(data)
            voices += page.voices
            guard let next = page.next else { break }
            token = next
        }
        return voices
    }

    /// Voices that speak both English and Spanish, for the picker.
    static func bilingual(_ voices: [Voice]) -> [Voice] {
        voices.filter { $0.languages.isSuperset(of: ["en", "es"]) }
    }

    /// His default voice: the first speaking English and Spanish, else the first speaking Spanish, else the first.
    static func defaultVoice(from voices: [Voice]) -> Voice? {
        bilingual(voices).first ?? voices.first { $0.languages.contains("es") } ?? voices.first
    }
}

/// The voice he speaks with: the saved one, or on first use the default among ElevenLabs' premade voices, saved.
/// Ids are never hardcoded; ElevenLabs retires premade voices.
actor VoiceChoice {
    private let saved: @Sendable () -> String
    private let save: @Sendable (String) -> Void
    private let list: @Sendable () async throws -> [ElevenLabs.Voice]
    private let speech: @Sendable (_ text: String, _ voiceID: String) -> AsyncThrowingStream<Data, Error>

    init(saved: @escaping @Sendable () -> String, save: @escaping @Sendable (String) -> Void,
         list: @escaping @Sendable () async throws -> [ElevenLabs.Voice] = { try await ElevenLabs.listVoices() },
         speech: @escaping @Sendable (String, String) -> AsyncThrowingStream<Data, Error> = { ElevenLabs.speech($0, voiceID: $1) }) {
        self.saved = saved
        self.save = save
        self.list = list
        self.speech = speech
    }

    /// `text` in his voice. Picking the voice happens inside the stream, so a first-use lookup failure is an ordinary
    /// speech failure; ending the stream early cancels the lookup or the request, whichever is under way.
    nonisolated func speak(_ text: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let id = try await self.voiceID()
                    for try await chunk in self.speech(text, id) { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    func voiceID() async throws -> String {
        let current = saved()
        if !current.isEmpty { return current }
        guard let voice = ElevenLabs.defaultVoice(from: try await list()) else { throw ElevenLabs.Failure.noVoice }
        // A concurrent caller may have saved one while this one was listing; the first choice stands.
        let winner = saved()
        if !winner.isEmpty { return winner }
        save(voice.id)
        return voice.id
    }
}

/// Keeps one fresh Scribe token ready so a press-to-talk doesn't wait on the mint. Each token is handed out once.
actor ElevenLabsTokens {
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date
    private let mint: @Sendable () async throws -> String
    private var ready: (token: String, minted: Date)?
    private var prefetching = false

    init(maxAge: TimeInterval = 13 * 60,
         now: @escaping @Sendable () -> Date = { Date() },
         mint: @escaping @Sendable () async throws -> String = { try await ElevenLabs.mintToken("realtime_scribe") }) {
        self.maxAge = maxAge
        self.now = now
        self.mint = mint
    }

    func token() async throws -> String {
        // Taking the ready token and clearing it happen with no await between, so no one else can see it.
        let held = ready
        ready = nil
        let token: String
        if let held, now().timeIntervalSince(held.minted) < maxAge { token = held.token } else { token = try await mint() }
        Task { await self.prefetch() }
        return token
    }

    /// Mints a token for the next call unless one is already ready or on its way. Failures are ignored; `token()` will surface them.
    func prefetch() async {
        if let ready, now().timeIntervalSince(ready.minted) < maxAge { return }
        guard !prefetching else { return }
        prefetching = true
        defer { prefetching = false }
        guard let token = try? await mint() else { return }
        ready = (token, now())
    }
}
