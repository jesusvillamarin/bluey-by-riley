import XCTest
@testable import GooglyMac

/// Answers every request from a closure, so nothing touches the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: ((URLRequest) -> (status: Int, body: Data))?
    nonisolated(unsafe) static var seen: [URLRequest] = []

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
            request.httpBody = body
        }
        Self.seen.append(request)
        let (status, body) = Self.respond?(request) ?? (500, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ElevenLabsSpeechTests: XCTestCase {
    override func setUp() { StubProtocol.respond = nil; StubProtocol.seen = [] }

    private func collect(_ stream: AsyncThrowingStream<Data, Error>) async throws -> [Data] {
        var chunks: [Data] = []
        for try await chunk in stream { chunks.append(chunk) }
        return chunks
    }

    func testSpeechRequest() throws {
        let request = ElevenLabs.speechRequest("Hola, qué tal.", voiceID: "abc123", apiKey: "sk_test")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/text-to-speech/abc123/stream?output_format=pcm_24000")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "sk_test")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["text": "Hola, qué tal.", "model_id": "eleven_v4_turbo"], "no language_code: the model follows the text")
        let spanish = ElevenLabs.speechRequest("Vale.", voiceID: "abc123", apiKey: "sk_test", language: "es")
        let pinned = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(spanish.httpBody)) as? [String: String])
        XCTAssertEqual(pinned["language_code"], "es")
    }

    func testChunksAreAQuarterSecondAndTheLastIsShorter() async throws {
        let audio = Data((0..<30_001).map { UInt8($0 % 251) })
        StubProtocol.respond = { _ in (200, audio) }
        let chunks = try await collect(ElevenLabs.speech("Hi.", voiceID: "v1", session: StubProtocol.session(), apiKey: "k"))
        XCTAssertEqual(chunks.map(\.count), [12_000, 12_000, 6_001])
        XCTAssertEqual(chunks.reduce(Data(), +), audio)
        XCTAssertEqual(StubProtocol.seen.first?.value(forHTTPHeaderField: "xi-api-key"), "k")
    }

    func testShortAudioIsOneChunk() async throws {
        StubProtocol.respond = { _ in (200, Data(repeating: 1, count: 500)) }
        let chunks = try await collect(ElevenLabs.speech("Hi.", voiceID: "v1", session: StubProtocol.session(), apiKey: "k"))
        XCTAssertEqual(chunks.map(\.count), [500])
    }

    func testHTTPErrorCarriesStatusAndBody() async throws {
        StubProtocol.respond = { _ in (401, Data(#"{"detail":"invalid key"}"#.utf8)) }
        do {
            _ = try await collect(ElevenLabs.speech("Hi.", voiceID: "v1", session: StubProtocol.session(), apiKey: "k"))
            XCTFail("expected a failure")
        } catch let ElevenLabs.Failure.http(status, body) {
            XCTAssertEqual(status, 401)
            XCTAssertTrue(body.contains("invalid key"))
        }
    }

    func testNoKeyAndNoVoiceFailBeforeAnyRequest() async throws {
        do { _ = try await collect(ElevenLabs.speech("Hi.", voiceID: "v1", session: StubProtocol.session(), apiKey: nil)); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, ElevenLabs.Failure.noKey.errorDescription) }
        do { _ = try await collect(ElevenLabs.speech("Hi.", voiceID: "", session: StubProtocol.session(), apiKey: "k")); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, ElevenLabs.Failure.noVoice.errorDescription) }
        XCTAssertTrue(StubProtocol.seen.isEmpty)
    }

    // MARK: Voices

    private static let page = #"""
    {"voices":[
      {"voice_id":"a1","name":"Alpha","category":"premade","verified_languages":[
        {"language":"en","model_id":"eleven_v4_turbo","accent":"american"},
        {"language":"es","model_id":"eleven_multilingual_v2"}]},
      {"voice_id":"b2","name":"Bravo","verified_languages":[
        {"language":"en","model_id":"eleven_v4_turbo"},{"language":"es","model_id":"eleven_v4_turbo"}]},
      {"voice_id":"c3","name":"Charlie","verified_languages":[{"language":"es","model_id":"eleven_v4_turbo"}]},
      {"voice_id":"d4","name":"Delta"},
      {"name":"No id"}
    ],"has_more":true,"next_page_token":"tok2"}
    """#

    func testParseVoicesReadsVerifiedLanguagesForFlash() throws {
        let page = try ElevenLabs.parseVoices(Data(Self.page.utf8))
        XCTAssertEqual(page.next, "tok2")
        XCTAssertEqual(page.voices.map(\.id), ["a1", "b2", "c3", "d4"])
        XCTAssertEqual(page.voices.map(\.languages), [["en"], ["en", "es"], ["es"], []], "a language verified for another model doesn't count")
        XCTAssertEqual(page.voices[1].name, "Bravo")
    }

    func testDefaultVoicePrefersBothThenSpanishThenAny() throws {
        let voices = try ElevenLabs.parseVoices(Data(Self.page.utf8)).voices
        XCTAssertEqual(ElevenLabs.defaultVoice(from: voices)?.id, "b2")
        XCTAssertEqual(ElevenLabs.bilingual(voices).map(\.id), ["b2"])
        XCTAssertEqual(ElevenLabs.defaultVoice(from: [voices[0], voices[2], voices[3]])?.id, "c3")
        XCTAssertEqual(ElevenLabs.defaultVoice(from: [voices[3], voices[0]])?.id, "d4")
        XCTAssertNil(ElevenLabs.defaultVoice(from: []))
    }

    private static let spanishPage = #"""
    {"voices":[
      {"voice_id":"gb","name":"George","labels":{"language":"en","accent":"british"},"verified_languages":[
        {"language":"en","locale":"en-GB","model_id":"eleven_v4_turbo"},{"language":"es","locale":"es-ES","model_id":"eleven_v4_turbo"}]},
      {"voice_id":"mx","name":"Michael","labels":{"language":"en","accent":"american"},"verified_languages":[
        {"language":"es","locale":"es-MX","accent":"mexican","model_id":"eleven_v4_turbo"}]},
      {"voice_id":"la","name":"Jaime","labels":{"language":"es","accent":"latin american"},"verified_languages":[
        {"language":"es","locale":"es-AR","accent":"latin american","model_id":"eleven_turbo_v2_5"},
        {"language":"es","locale":"es-AR","accent":"latin american","model_id":"eleven_v4_turbo"}]},
      {"voice_id":"en","name":"Bella","labels":{"language":"en","accent":"american"},"verified_languages":[
        {"language":"en","locale":"en-US","model_id":"eleven_v4_turbo"}]}
    ]}
    """#

    func testSpanishDefaultPrefersANativeLatinAmericanVoice() throws {
        let voices = try ElevenLabs.parseVoices(Data(Self.spanishPage.utf8)).voices
        XCTAssertEqual(voices[2].native, "es")
        XCTAssertEqual(voices[2].accent, "latin american")
        XCTAssertEqual(voices[1].spanishLocales, ["es-mx"])
        XCTAssertEqual(ElevenLabs.spanishVoices(voices).map(\.id), ["la", "mx", "gb"], "native Latin American, then a Latin locale, then Spain")
        XCTAssertEqual(ElevenLabs.defaultSpanishVoice(from: voices)?.id, "la")
        XCTAssertEqual(ElevenLabs.defaultSpanishVoice(from: [voices[0], voices[3]])?.id, "gb")
        XCTAssertNil(ElevenLabs.defaultSpanishVoice(from: [voices[3]]))
    }

    func testListVoicesFollowsPagesAndAsksForAllOfTheAccountsVoices() async throws {
        StubProtocol.respond = { request in
            if request.url?.query?.contains("next_page_token=tok2") == true {
                return (200, Data(#"{"voices":[{"voice_id":"e5","name":"Echo"}],"has_more":false}"#.utf8))
            }
            return (200, Data(Self.page.utf8))
        }
        let voices = try await ElevenLabs.listVoices(session: StubProtocol.session(), apiKey: "k")
        XCTAssertEqual(voices.map(\.id), ["a1", "b2", "c3", "d4", "e5"])
        let first = try XCTUnwrap(StubProtocol.seen.first?.url?.absoluteString)
        XCTAssertTrue(first.hasPrefix("https://api.elevenlabs.io/v2/voices?"), first)
        XCTAssertTrue(!first.contains("category=") && first.contains("page_size=100"), "voices added from the library count too: \(first)")
        XCTAssertEqual(StubProtocol.seen.first?.value(forHTTPHeaderField: "xi-api-key"), "k")
    }

    // MARK: VoiceChoice

    final class Saved: @unchecked Sendable {
        private let lock = NSLock()
        private var id = ""
        private var lists = 0
        var value: String { get { lock.lock(); defer { lock.unlock() }; return id } set { lock.lock(); id = newValue; lock.unlock() } }
        var listCalls: Int { lock.lock(); defer { lock.unlock() }; return lists }
        func listed() { lock.lock(); lists += 1; lock.unlock() }
    }

    func testFirstUsePicksTheDefaultAndSavesIt() async throws {
        let saved = Saved()
        let voices = try ElevenLabs.parseVoices(Data(Self.page.utf8)).voices
        let choice = VoiceChoice(saved: { saved.value }, save: { saved.value = $0 }, list: { saved.listed(); return voices })
        let first = try await choice.voiceID()
        let second = try await choice.voiceID()
        XCTAssertEqual(first, "b2")
        XCTAssertEqual(second, "b2")
        XCTAssertEqual(saved.value, "b2")
        XCTAssertEqual(saved.listCalls, 1, "listed once, then the saved one is used")
    }

    func testASavedVoiceIsNeverReplaced() async throws {
        let saved = Saved()
        saved.value = "mine"
        let choice = VoiceChoice(saved: { saved.value }, save: { saved.value = $0 }, list: { saved.listed(); return [] })
        let id = try await choice.voiceID()
        XCTAssertEqual(id, "mine")
        XCTAssertEqual(saved.listCalls, 0)
    }

    func testListFailureIsASpeechFailure() async throws {
        struct Down: LocalizedError { var errorDescription: String? { "offline" } }
        let choice = VoiceChoice(saved: { "" }, save: { _ in }, list: { throw Down() })
        do { _ = try await collect(choice.speak("Hi.")); XCTFail("expected a failure") }
        catch { XCTAssertEqual(error.localizedDescription, "offline") }
        let none = VoiceChoice(saved: { "" }, save: { _ in }, list: { [] })
        do { _ = try await none.voiceID(); XCTFail("expected a failure") }
        catch { XCTAssertEqual(error.localizedDescription, ElevenLabs.Failure.noVoice.errorDescription) }
    }

    func testSpeakUsesTheChosenVoiceAndEndingItEndsTheRequest() async throws {
        final class Ended: @unchecked Sendable { var value = false }
        let ended = Ended()
        let choice = VoiceChoice(saved: { "v9" }, save: { _ in }, list: { [] }, speech: { text, voice in
            AsyncThrowingStream { continuation in
                continuation.yield(Data("\(voice):\(text)".utf8))
                continuation.onTermination = { _ in ended.value = true }
            }
        })
        let task = Task { () -> String? in
            for try await chunk in choice.speak("Hi.") { return String(decoding: chunk, as: UTF8.self) }
            return nil
        }
        let first = try await task.value
        XCTAssertEqual(first, "v9:Hi.")
        let deadline = Date().addingTimeInterval(2)
        while !ended.value && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(ended.value, "leaving the stream cancels the request underneath")
    }

    // MARK: Bilingual

    func testDetectsTheLanguageOfASentence() {
        XCTAssertEqual(SpeechLanguage.detect("Hola, ¿cómo estás? Todo bien por aquí, parce."), .es)
        XCTAssertEqual(SpeechLanguage.detect("Right then, what are we working on today?"), .en)
        XCTAssertNil(SpeechLanguage.detect("OK."), "too short to tell")
    }

    func testEachLanguageSpeaksWithItsOwnVoiceAndShortLinesKeepTheLastOne() async throws {
        let echo: @Sendable (String) -> @Sendable (String, String) -> AsyncThrowingStream<Data, Error> = { tag in
            { text, voice in AsyncThrowingStream { $0.yield(Data("\(tag)/\(voice):\(text)".utf8)); $0.finish() } }
        }
        let voice = BilingualVoice(
            english: VoiceChoice(saved: { "gb" }, save: { _ in }, list: { [] }, speech: echo("en")),
            spanish: VoiceChoice(saved: { "la" }, save: { _ in }, list: { [] }, speech: echo("es")))
        let lines = ["Hola, ¿cómo estás? Todo bien por aquí.", "OK.", "Right then, what are we working on today?", "Vale."]
        var spoken: [String] = []
        for line in lines { spoken += try await collect(voice.speak(line)).map { String(decoding: $0, as: UTF8.self) } }
        XCTAssertEqual(spoken, ["es/la:\(lines[0])", "es/la:OK.", "en/gb:\(lines[2])", "en/gb:Vale."])
    }
}
