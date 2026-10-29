import Foundation

enum ElevenLabs {
    enum Failure: LocalizedError {
        case noKey, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .noKey: return "I need an ElevenLabs API key. Add one under ElevenLabs Key in the menu bar."
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
