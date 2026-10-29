# Subscription Voice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Subscription" voice mode: hold the phone to talk (ElevenLabs Scribe v2 Realtime), a warm `claude -p` (Haiku, the user's subscription) answers on the Mac using Bluey's tools, the reply shows as a bubble and (milestone 2) is spoken with ElevenLabs TTS. Meeting notes move to Scribe v2 batch (milestone 3). OpenAI Realtime remains as "Fast" mode, unchanged.

**Architecture:** The phone streams held audio straight to Scribe with a single-use token minted by the Mac, then sends the final transcript over GooglyLink. The Mac keeps one `claude` process per awake session (stream-json in/out) and serves `RealtimeHost`'s existing tools to it through a local, token-protected HTTP MCP server. Reply text streams back as unsolicited `voice*` packets; TTS runs on the Mac and audio is relayed to the phone.

**Tech Stack:** Swift 5.9, AppKit/SwiftUI, URLSession websockets, Network.framework (`NWListener`), XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-29-subscription-voice-design.md`

## Global Constraints

- macOS 14+ (Mac app, `Package.swift`), iOS 17+ (phone, `project.yml`). No third-party packages, no ElevenLabs/Anthropic SDKs.
- The ElevenLabs key lives only in `Keychain` (`keys.json`) on the Mac. The phone only ever receives single-use `realtime_scribe` tokens.
- Scribe Realtime socket: `wss://api.elevenlabs.io/v1/speech-to-text/realtime?token=…&model_id=scribe_v2_realtime&audio_format=pcm_24000&commit_strategy=manual` plus optional repeated `keyterms` (max 50, each ≤ 20 chars), RFC 3986 percent-encoding (space → `%20`). Audio frames are websocket **text** frames: `{"message_type":"input_audio_chunk","audio_base_64":…,"commit":false,"sample_rate":24000}`. Commit = same frame with empty audio and `"commit":true` (what Panita ships).
- Token mint: `POST https://api.elevenlabs.io/v1/single-use-token/realtime_scribe`, header `xi-api-key`, response `{"token":…}`. Tokens are single use, 15 min life: never hand one out twice, discard prefetched ones older than 13 min.
- `claude` arguments, exactly: `-p --model haiku --tools "" --no-session-persistence --setting-sources "" --strict-mcp-config --mcp-config <json> --allowedTools mcp__bluey --disable-slash-commands --input-format stream-json --output-format stream-json --verbose --include-partial-messages --system-prompt <prompt>`. Child runs in an empty working directory, without the `CLAUDECODE` env var, stderr discarded.
- MCP server: binds `127.0.0.1` only, random port, requires `Authorization: Bearer <random 32-byte hex>` generated per app launch; server name `bluey`.
- TTS (milestone 2): `POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}/stream?output_format=pcm_24000`, body `{"text":…,"model_id":"eleven_flash_v2_5"}`.
- Scribe batch (milestone 3): `POST https://api.elevenlabs.io/v1/speech-to-text`, multipart `model_id=scribe_v2`, `file`, `diarize=true`.
- Fast mode (OpenAI Realtime) behaviour must not change. The OpenAI key remains required for focus checks and `web_research`.
- Never fall back silently from Subscription to Fast mode; show the fix instead.
- Tests: `swift test --scratch-path /tmp/bluey-voice-swift`. No real network or real `claude` in unit tests. There is no iOS test target: testable logic goes in `Shared/` or the Mac target with injected closures (the `FocusCompanion` style).
- Code style: match the surrounding files (sparse doc comments, one-line `///` on types and non-obvious members).

## Review Focus

1. **Release after < 100 ms, or silence.** Expect "I didn't catch that", no `voiceAsk` sent, no Claude turn. Tests: `ScribeTurnTests.testReleaseTooShort`, `testEmptyFinalTranscript` (Task 1).
2. **Holding again while he is thinking or speaking.** Expect the old turn interrupted, no reply/audio from it ever shown or played, the new turn answered. Tests: `SubscriptionVoiceTests.testCancelInterruptsAndSuppressesOldTurn` (Task 6), `SubscriptionVoiceTests.testCancelStopsSpeech` (Task 8).
3. **`claude` not installed, or signed out (process exits at once).** Expect a bubble with the fix ("Install Claude Code" / "open Terminal, run `claude` and sign in"), mode unchanged. Tests: `ClaudeVoiceSessionTests.testMissingBinary`, `testProcessExitsImmediately` (Task 4).
4. **Stale or reused Scribe token** (e.g. Bluey awake and idle for 20 minutes). Expect a fresh token every hold: the phone asks the Mac at each hold and keeps none. Tests: `ElevenLabsTokensTests` (Task 2); device check in Task 7.
5. **A long tool turn (`web_research`, several screen tools) must not time out** while events keep arriving; a silent hang must. Test: `ClaudeVoiceSessionTests.testActivityResetsTimeout` (Task 4).

---

## Milestone 1 — hold to talk, Claude answers, bubbles

### Task 1: Scribe protocol and the held-turn state machine (Shared)

**Files:**
- Create: `Shared/ScribeRealtime.swift`
- Test: `Tests/GooglySharedTests/ScribeTurnTests.swift`

Port from Panita's `panita-ecosystem/panita/Sources/Panita/Transcription/Realtime/ScribeRealtimeMessages.swift` (parser, error type list) and add `sample_rate`. Reuse `VoiceTurnBuffer` for audio captured before `session_started` (its 4800-byte `canCommit` and 960 KB cap already match 24 kHz PCM16).

**Interfaces:**
- Produces:
  - `public enum ScribeServerMessage: Equatable { case sessionStarted, partial(String), committed(String), failed(type: String) }`
  - `public enum ScribeRealtime { static let sampleRate = 24000; static func socketURL(token: String, keyterms: [String], languageCode: String?) -> URL; static func audioFrame(_ pcm: Data, commit: Bool) -> String; static func parse(_ text: String) -> ScribeServerMessage? }` (`parse` returns nil for unknown types; error types: `error, auth_error, quota_exceeded, rate_limited, commit_throttled, queue_overflow, resource_exhausted, input_error, invalid_request, chunk_size_exceeded, insufficient_audio_activity, transcriber_error, session_time_limit_exceeded, unaccepted_terms`)
  - `public struct ScribeTurn` with `public enum Release: Equatable { case send([String]), wait, tooShort, overflowed }`, `public enum Event: Equatable { case partial(String), final(String), failed(String) }`, `init()`, `mutating func audio(_ pcm: Data) -> [String]`, `mutating func started() -> [String]`, `mutating func release() -> Release`, `mutating func receive(_ message: ScribeServerMessage) -> Event?`.
  - Final text = all committed segments joined by a space, trimmed; emitted on the first `committed` after the commit was sent.

- [ ] **Step 1: Write the failing tests**

```swift
func testSocketURL() {
    let url = ScribeRealtime.socketURL(token: "t k", keyterms: ["Bluey", "Codex", String(repeating: "x", count: 21)], languageCode: nil)
    XCTAssertEqual(url.absoluteString, "wss://api.elevenlabs.io/v1/speech-to-text/realtime?token=t%20k&model_id=scribe_v2_realtime&audio_format=pcm_24000&commit_strategy=manual&keyterms=Bluey&keyterms=Codex")
}
func testAudioFrameIsTextJSON() throws {
    let frame = ScribeRealtime.audioFrame(Data([1, 2]), commit: true)
    let json = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as! [String: Any]
    XCTAssertEqual(json["message_type"] as? String, "input_audio_chunk")
    XCTAssertEqual(json["audio_base_64"] as? String, "AQI=")
    XCTAssertEqual(json["commit"] as? Bool, true)
    XCTAssertEqual(json["sample_rate"] as? Int, 24000)
}
func testParse() {
    XCTAssertEqual(ScribeRealtime.parse(#"{"message_type":"committed_transcript_with_timestamps","text":"hola","words":[]}"#), .committed("hola"))
    XCTAssertEqual(ScribeRealtime.parse(#"{"message_type":"auth_error","error":"bad"}"#), .failed(type: "auth_error"))
    XCTAssertNil(ScribeRealtime.parse(#"{"message_type":"something_new"}"#))
}
func testBuffersUntilStartedThenCommitsAfterAudio() {
    var turn = ScribeTurn()
    XCTAssertEqual(turn.audio(Data(count: 4800)), [])
    XCTAssertEqual(turn.release(), .wait)
    let frames = turn.started()
    XCTAssertEqual(frames.count, 2)            // buffered audio, then the commit
    XCTAssertTrue(frames.last!.contains("\"commit\":true"))
}
func testStreamsOnceStarted() { var t = ScribeTurn(); _ = t.started(); XCTAssertEqual(t.audio(Data(count: 10)).count, 1) }
func testReleaseTooShort() { var t = ScribeTurn(); _ = t.started(); _ = t.audio(Data(count: 100)); XCTAssertEqual(t.release(), .tooShort) }
func testFinalJoinsSegmentsAfterCommit() {
    var t = ScribeTurn(); _ = t.started(); _ = t.audio(Data(count: 4800))
    XCTAssertEqual(t.receive(.committed("primera parte")), nil)   // Scribe's own mid-utterance commit
    guard case .send = t.release() else { return XCTFail() }
    XCTAssertEqual(t.receive(.committed("y segunda")), .final("primera parte y segunda"))
}
func testEmptyFinalTranscript() {
    var t = ScribeTurn(); _ = t.started(); _ = t.audio(Data(count: 4800)); _ = t.release()
    XCTAssertEqual(t.receive(.committed("  ")), .final(""))
}
func testServerErrorFails() { var t = ScribeTurn(); XCTAssertEqual(t.receive(.failed(type: "quota_exceeded")), .failed("quota_exceeded")) }
```

- [ ] **Step 2: Run to verify they fail** — `swift test --scratch-path /tmp/bluey-voice-swift --filter ScribeTurnTests` → compile failure (types missing).
- [ ] **Step 3: Implement `Shared/ScribeRealtime.swift`** (`public` API; `JSONSerialization` with `.sortedKeys` is not needed—assert on parsed JSON as above).
- [ ] **Step 4: Run** the same command → all pass; then the full `swift test --scratch-path /tmp/bluey-voice-swift` → all pass.
- [ ] **Step 5: Commit** `feat(voice): Scribe realtime protocol and held-turn state machine`

### Task 2: ElevenLabs key, token minting, voice mode setting

**Files:**
- Modify: `Mac/Sources/GooglyMac/Keychain.swift:6-8` (add `case elevenlabs`)
- Create: `Mac/Sources/GooglyMac/ElevenLabs.swift`
- Create: `Shared/VoiceMode.swift`
- Modify: `Mac/Sources/GooglyMac/Settings.swift` (add `voiceMode`)
- Modify: `Mac/Sources/GooglyMac/AppDelegate.swift:292-306, 399` (key editor for both keys; Voice mode submenu)
- Test: `Tests/GooglyMacTests/ElevenLabsTokensTests.swift`

**Interfaces:**
- Produces:
  - `public enum VoiceMode: String, Codable, Sendable { case fast, subscription }`
  - `Settings.shared.voiceMode: VoiceMode` (UserDefaults key `"voiceMode"`, default `.fast` so nothing changes until chosen).
  - `enum ElevenLabs { enum Failure: LocalizedError { case noKey, http(Int, String) }; static func mintToken(_ type: String) async throws -> String }` (`noKey` text: "I need an ElevenLabs API key. Add one under ElevenLabs Key in the menu bar.").
  - `actor ElevenLabsTokens { init(maxAge: TimeInterval = 13 * 60, now: @escaping @Sendable () -> Date = Date.init, mint: @escaping @Sendable () async throws -> String = { try await ElevenLabs.mintToken("realtime_scribe") }); func token() async throws -> String; func prefetch() async }` — `token()` returns the prefetched token if younger than `maxAge`, else mints; it never returns the same token twice and starts a background prefetch after handing one out.
  - Menu: "OpenAI Key…" and "ElevenLabs Key…" (one `editKey(_ key: Keychain.Key)` alert), and a "Voice" submenu with checkmarked "Fast (OpenAI Realtime)" / "Subscription (Claude + ElevenLabs)"; switching calls `restartIfAwake()`.

- [ ] **Step 1: Write the failing tests** — `testHandsOutPrefetchedToken` (mint returns "a","b"…; after `prefetch()`, `token()` == "a" and mint called once before `token()`), `testNeverReusesToken` (two `token()` calls return different values), `testDiscardsStaleToken` (prefetch at t=0, advance injected clock 13 min + 1 s, `token()` != the prefetched value), `testMintFailurePropagates` (mint throws `ElevenLabs.Failure.noKey` → `token()` throws it).
- [ ] **Step 2: Run** `swift test --scratch-path /tmp/bluey-voice-swift --filter ElevenLabsTokensTests` → fails to compile.
- [ ] **Step 3: Implement** `ElevenLabs.swift`, `VoiceMode.swift`, the `Keychain` case, `Settings.voiceMode`, and the menu items.
- [ ] **Step 4: Run** the filter, then the full suite → pass. `./scripts/build-mac.sh` → builds.
- [ ] **Step 5: Commit** `feat(voice): ElevenLabs key, single-use tokens and voice mode setting`

### Task 3: `claude` stream-json protocol (pure)

**Files:**
- Create: `Mac/Sources/GooglyMac/ClaudeStream.swift`
- Test: `Tests/GooglyMacTests/ClaudeStreamTests.swift`

**Interfaces:**
- Produces:
  - `enum ClaudeEvent: Equatable { case textDelta(String), toolUse(String), result(text: String, isError: Bool), other }` — `toolUse` carries the name with the `mcp__bluey__` prefix removed.
  - `enum ClaudeStream { static func arguments(model: String, systemPrompt: String, mcpConfig: String) -> [String]; static func userLine(_ text: String) -> String; static func interruptLine(id: String) -> String; static func parse(_ line: String) -> ClaudeEvent }` — lines end with `\n`; `interruptLine` = `{"type":"control_request","request_id":<id>,"request":{"subtype":"interrupt"}}`.

- [ ] **Step 1: Write the failing tests** using the shapes captured from `claude` 2026-10-29:

```swift
func testArguments() {
    XCTAssertEqual(ClaudeStream.arguments(model: "haiku", systemPrompt: "P", mcpConfig: "{}"),
        ["-p", "--model", "haiku", "--tools", "", "--no-session-persistence", "--setting-sources", "",
         "--strict-mcp-config", "--mcp-config", "{}", "--allowedTools", "mcp__bluey", "--disable-slash-commands",
         "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
         "--include-partial-messages", "--system-prompt", "P"])
}
func testUserLine() throws {
    let line = ClaudeStream.userLine("hola \"Bluey\"")
    XCTAssertTrue(line.hasSuffix("\n"))
    let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
    XCTAssertEqual(json["type"] as? String, "user")
    XCTAssertEqual((json["message"] as? [String: Any])?["content"] as? String, "hola \"Bluey\"")
}
func testParseTextDelta() {
    XCTAssertEqual(ClaudeStream.parse(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}}"#), .textDelta("Hi"))
}
func testParseToolUse() {
    XCTAssertEqual(ClaudeStream.parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"mcp__bluey__look_at_screen","input":{}}]}}"#), .toolUse("look_at_screen"))
}
func testParseResults() {
    XCTAssertEqual(ClaudeStream.parse(#"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#), .result(text: "ok", isError: false))
    // Real interrupt result (trimmed): no "result" field.
    XCTAssertEqual(ClaudeStream.parse(#"{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"aborted_streaming","errors":["[ede_diagnostic] result_type=user"],"num_turns":2}"#), .result(text: "", isError: true))
}
func testParseOther() { XCTAssertEqual(ClaudeStream.parse(#"{"type":"system","subtype":"init"}"#), .other); XCTAssertEqual(ClaudeStream.parse("garbage"), .other) }
```

- [ ] **Step 2: Run** `--filter ClaudeStreamTests` → fails.
- [ ] **Step 3: Implement** `ClaudeStream.swift`.
- [ ] **Step 4: Run** → pass.
- [ ] **Step 5: Commit** `feat(voice): claude stream-json protocol`

### Task 4: `ClaudeVoiceSession` — one warm process per awake session

**Files:**
- Create: `Mac/Sources/GooglyMac/ClaudeVoiceSession.swift`
- Test: `Tests/GooglyMacTests/ClaudeVoiceSessionTests.swift`

Follow `CodexController.ensureRunning()` (`CodexController.swift:71-105`) for `Process`, pipes and `readabilityHandler` → MainActor.

**Interfaces:**
- Consumes: `ClaudeStream`, `ClaudeEvent` (Task 3).
- Produces:
  - `enum ClaudeBinary { static func locate() -> URL?; static func lookUpInShell() async }` — `locate()` checks, in order, a path cached by `lookUpInShell()`, `~/.local/bin/claude`, `~/.claude/local/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`; `lookUpInShell()` runs `$SHELL -ilc 'command -v claude'` (5 s budget) once at launch, off the main thread.
  - `@MainActor final class ClaudeVoiceSession { init(binary: @escaping () -> URL? = ClaudeBinary.locate, arguments: @escaping () -> [String], workingDirectory: URL, activityTimeout: TimeInterval = 90); func warmUp(); func ask(_ text: String, onEvent: @escaping (ClaudeEvent) -> Void) async throws -> String; func interrupt(); func stop(); private(set) var recentTurns: [(user: String, reply: String)] }`
  - `enum ClaudeVoiceSession.Failure: LocalizedError, Equatable { case notInstalled, exited, timedOut, interrupted, failed(String) }` with texts: notInstalled "Install Claude Code to use Subscription voice, or switch Voice to Fast in the menu bar."; exited "Claude stopped. Open Terminal, run `claude` and make sure you're signed in."; timedOut "Claude took too long. Try again."; failed → "Claude couldn't answer: \(text)" (e.g. the subscription usage limit).
- Rules:
  - `ask` calls are serial (a second `ask` waits for the first). It spawns the process if not running, writes `ClaudeStream.userLine`, forwards every event to `onEvent`, and returns the `result` text.
  - **Any** `result` that arrives after `interrupt()` was called for this turn throws `.interrupted`, whatever its `is_error`. A `result` with `isError` and no interrupt throws `.failed(resultText)` (never shown as a normal reply).
  - The activity timer restarts on every stdout line; when it fires, the process is killed and `ask` throws `.timedOut`.
  - EOF before a `result` → `.exited`; the next `ask` respawns.
  - `recentTurns` keeps the last 10 completed turns. The first `ask` after a respawn (not the very first spawn) prefixes `"Earlier in this conversation:\n" + "User: …\nYou: …" lines + "\n\n"`.
  - `stop()` kills the process; `recentTurns` is cleared.

- [ ] **Step 1: Write the failing tests.** Each test writes an executable fake to a temp dir: a `/bin/sh` script that loops `while IFS= read -r line` and, per input, prints canned lines (e.g. for a user line: one `content_block_delta` with "Hi" then a success `result` "Hi"; for a line containing `control_request`: a `result` with `"is_error":true`). Tests:
  - `testAskStreamsAndReturnsResult` — events received `[.other?…, .textDelta("Hi"), .result(text:"Hi", isError:false)]` contain `.textDelta("Hi")`; return value `"Hi"`.
  - `testTwoTurnsUseOneProcess` — fake prints its PID in the result; both asks return the same PID.
  - `testMissingBinary` — `binary: { nil }` → throws `.notInstalled`.
  - `testProcessExitsImmediately` — fake is `exit 1` → throws `.exited`.
  - `testInterrupt` — fake delays its result 2 s unless it reads a `control_request`; call `interrupt()` after 100 ms → throws `.interrupted` within 1 s.
  - `testActivityResetsTimeout` — `activityTimeout: 0.3`; fake prints a delta every 0.1 s for 1 s then the result → succeeds.
  - `testSilentHangTimesOut` — `activityTimeout: 0.3`; fake prints nothing → throws `.timedOut`.
  - `testErrorResultFails` — fake answers `{"type":"result","subtype":"success","is_error":true,"result":"usage limit reached"}` → throws `.failed("usage limit reached")`.
  - `testRespawnReplaysRecentTurns` — fake echoes the received user content as its result and exits after one turn; second `ask("b")` returns a string that starts with `"Earlier in this conversation:"` and contains `"User: a"`.
- [ ] **Step 2: Run** `--filter ClaudeVoiceSessionTests` → fails.
- [ ] **Step 3: Implement** `ClaudeVoiceSession.swift` (env: copy `ProcessInfo.processInfo.environment`, remove `CLAUDECODE`, prepend the binary's directory to `PATH`; `standardError = FileHandle.nullDevice`).
- [ ] **Step 4: Run** → pass; full suite → pass.
- [ ] **Step 5: Commit** `feat(voice): warm claude session per awake session`

### Task 5: Local MCP server exposing Bluey's tools

**Files:**
- Create: `Mac/Sources/GooglyMac/BlueyMCP.swift`
- Test: `Tests/GooglyMacTests/BlueyMCPTests.swift`

**Interfaces:**
- Produces:
  - `enum MCPTools { static func list(from realtime: [[String: Any]]) -> [[String: Any]] }` — maps each `{"type":"function","name","description","parameters"}` to `{"name","description","inputSchema": parameters}`.
  - `struct MCPHandler { let token: String; let tools: () -> [[String: Any]]; let call: (_ name: String, _ argumentsJSON: String) async -> (text: String, image: String?); func respond(method: String, authorization: String?, body: Data) async -> (status: Int, body: Data?) }`
    - wrong/missing bearer → 401; `GET` → 405; JSON-RPC without `id` (notifications) → 202 no body.
    - `initialize` → echoes the client's `protocolVersion`, `capabilities: {tools: {}}`, `serverInfo: {name: "bluey", version: "1"}`.
    - `tools/list` → `{tools: MCPTools.list(from: tools())}`.
    - `tools/call` → `content: [{type:"text",text}]` plus `{type:"image",data,mimeType:"image/jpeg"}` when an image exists; arguments re-serialized to a JSON string for `call`.
    - any other method → JSON-RPC error `-32601`.
  - `final class BlueyMCPServer { init(handler: MCPHandler); func start() throws -> UInt16; func stop(); func configJSON(port: UInt16) -> String }` — `NWListener` on `127.0.0.1`, random port; each connection: read until `\r\n\r\n`, read `Content-Length` bytes, answer `HTTP/1.1` with `Content-Type: application/json`, `Connection: close`. `configJSON` = `{"mcpServers":{"bluey":{"type":"http","url":"http://127.0.0.1:<port>/mcp","headers":{"Authorization":"Bearer <token>"}}}}`.

- [ ] **Step 1: Write the failing tests** — `testToolListMapping` (input `RealtimeHost`-style dict → `inputSchema` equals the `parameters` dict, no `type` key), `testRejectsWrongToken` (status 401), `testNotificationAccepted` (body `{"jsonrpc":"2.0","method":"notifications/initialized"}` → 202, nil body), `testInitializeEchoesVersion`, `testToolsCallWithImage` (`call` returns `("Safari", "AAAA")` → content has two items, second `mimeType` `"image/jpeg"`, and `call` received `name == "look_at_screen"`), `testUnknownMethod` (`server/discover` → error code -32601), and `testHTTPRoundTrip` (start the real server, `URLSession` POST `initialize` with the bearer → 200 and `serverInfo.name == "bluey"`).
- [ ] **Step 2: Run** `--filter BlueyMCPTests` → fails.
- [ ] **Step 3: Implement** `BlueyMCP.swift`.
- [ ] **Step 4: Run** → pass; full suite → pass.
- [ ] **Step 5: Live check with the real CLI** (needs the founder's signed-in `claude`): add a hidden launch flag `--voice-claude-test` in `main.swift` that starts `BlueyMCPServer` with a stub `look_at_screen` returning `"Frontmost app: Keynote."` plus a synthetic JPEG drawn in code (white background, a blue rectangle, an orange circle, the text "Quarterly sales: 1,284 units"; never a real screenshot), runs one `ClaudeVoiceSession.ask("Look at my screen. What shapes do you see and what number is written?")`, prints events with timestamps, and exits. Run `swift run GooglyMac --voice-claude-test` → `toolUse("look_at_screen")`, a reply naming the rectangle, the circle and 1,284, no permission denial. (The same check passed with a Python stub on 2026-10-29: first text 1.6 s after the tool call.)
- [ ] **Step 6: Commit** `feat(voice): local MCP server for Bluey's tools`

### Task 6: `SubscriptionVoice` — the Mac side of a turn

**Files:**
- Create: `Mac/Sources/GooglyMac/SubscriptionVoice.swift`
- Modify: `Mac/Sources/GooglyMac/RealtimeHost.swift` (route packets; extract tool running; prompt notes)
- Modify: `Mac/Sources/GooglyMac/AppDelegate.swift` (create MCP server + session at launch, `ClaudeBinary.lookUpInShell()`, route Codex notes)
- Test: `Tests/GooglyMacTests/SubscriptionVoiceTests.swift`

**Packets (all new commands; `speech` = phone's turn number, 0 for Mac-started turns):**

| Command | Direction | Fields | Meaning |
|---|---|---|---|
| `voiceStart` | phone→Mac request | — | reply `text`: `{"mode":"fast"}` or `{"mode":"subscription","keyterms":["Bluey","Codex","Claude"]}`; in subscription mode also `warmUp()` |
| `scribeToken` | phone→Mac request | — | reply `text`: token, or nil (Mac shows the error bubble) |
| `voiceAsk` | phone→Mac send | `speech`, `text` | the final transcript |
| `voiceCancel` | phone→Mac send | `speech` | user held again: interrupt that turn |
| `voiceDelta` | Mac→phone | `speech`, `text` (reply so far) | streaming |
| `voiceTool` | Mac→phone | `speech`, `tool` | a tool started (keeps the phone's watchdog alive) |
| `voiceDone` | Mac→phone | `speech`, `text` | final reply (may be empty when he only acted) |
| `voiceError` | Mac→phone | `speech`, `text` | user-facing message |
| `voiceReport` | Mac→phone | `text` | the `web_research` report for the saved transcript |

**Interfaces:**
- Consumes: `ClaudeVoiceSession` (Task 4), `ElevenLabsTokens` (Task 2), `Settings.voiceMode`.
- Produces:
  - In `RealtimeHost`: `func runQueuedTool(_ name: String, arguments: String) async -> (text: String, image: String?)` — the existing `toolChain` serialization from the `"tool"` case, now shared by that case and the MCP server.
  - In `RealtimeHost`: `static func voiceNotes(mode: VoiceMode, speakAloud: Bool) -> String`. Fast: "You never speak out loud: your replies pop up as a tiny speech bubble." Subscription adds: "Your tools are named mcp__bluey__<name>." and, once in the system prompt, the hold-to-talk rule that Fast mode sends per turn from `LiveVoice.swift:389` ("Every user message was spoken while holding Bluey. When it describes work, call focus_start with task and optional minutes (default 30). Never merely say you're ready."). `speakAloud` true: "Your one short line is also read aloud in your voice." Both modes add the language rule (founder decision): "Reply in the language the user just spoke. In English you are the young British guy above. In Spanish, speak natural Latin American Spanish (Mexican/Colombian), same dry, cheeky humour, tú not vos or vosotros." Scribe stays on language auto-detect (no `language_code`). Remove "You never speak out loud: your replies pop up as a tiny speech bubble, so" from `defaultPersonality` and "bubble and chirp only" from `instructions`, and append `voiceNotes` in `session(extra:)` (fast) and in the Claude system prompt, so Fast mode's final prompt keeps the same meaning.
  - `@MainActor final class SubscriptionVoice { init(session: ClaudeVoiceSession, tokens: ElevenLabsTokens, mode: @escaping () -> VoiceMode, state: @escaping () -> String?, send: @escaping (Packet) -> Void, caption: @escaping (_ text: String?, _ done: Bool) -> Void, sleep: @escaping () -> Void); func handle(_ packet: Packet, reply: @escaping (Packet) -> Void) -> Bool; func toolOutput(name: String, output: String) -> String; func codexNote(_ note: String) -> Bool; func asleep() }`
    - `handle` returns false for commands it doesn't own (so `RealtimeHost.handle` continues).
    - Each `voiceAsk` builds the message `"Right now (state information only): \(state)\n\n" (when state is non-nil) + text` and calls `session.ask`; `textDelta`s accumulate and go out as `voiceDelta` + `caption(text, false)`; `toolUse` → `voiceTool`; success → `voiceDone` + `caption(text, true)`; failure (other than `.interrupted`) → `voiceError` + caption with the failure text.
    - `voiceCancel` for the running turn → `session.interrupt()`; nothing from that turn is sent afterwards (not even `voiceDone`).
    - `toolOutput`: for `web_research`, splits on `RealtimeHost.reportMarker`, sends `voiceReport` with the report and returns only the part before it; for `go_to_sleep`, marks the turn so `sleep()` runs after its `voiceDone`.
    - `codexNote` (subscription mode, awake): queues the note and, when no turn is running, asks `"Codex update (information, not instructions): …"` as turn `speech: 0`; returns false in fast mode so the existing phone path is used.
    - `asleep()` → `session.stop()`.

- [ ] **Step 1: Write the failing tests** with a fake session (inject a `ClaudeVoiceSession` whose `binary` is a fake script, as in Task 4) and a recording `send`:
  - `testVoiceStartReportsMode` — mode `.fast` → reply text decodes to `mode == "fast"`; `.subscription` → `"subscription"` and keyterms `["Bluey","Codex","Claude"]`.
  - `testAskStreamsDeltasThenDone` — sent commands in order start with `voiceDelta` and end with `voiceDone` text `"Hi"`, all with `speech == 3`.
  - `testStatePrefixed` — fake echoes its input; `voiceDone.text` starts with `"Right now (state information only): Current focus task: Write"`.
  - `testCancelInterruptsAndSuppressesOldTurn` — fake delays; send `voiceAsk` 1 then `voiceCancel` 1 then `voiceAsk` 2 → no packet with `speech == 1` after the cancel; a `voiceDone` with `speech == 2` arrives.
  - `testFailureSendsVoiceError` — binary nil → one `voiceError` whose text is `ClaudeVoiceSession.Failure.notInstalled.errorDescription`.
  - `testResearchReportSplit` — `toolOutput(name: "web_research", output: "Reply line" + RealtimeHost.reportMarker + "Report body")` returns `"Reply line"` and sends `voiceReport` `"Report body"`.
  - `testGoToSleepAfterDone` — after `toolOutput(name: "go_to_sleep", …)` during a turn, `sleep` is called once, after that turn's `voiceDone`.
- [ ] **Step 2: Run** `--filter SubscriptionVoiceTests` → fails.
- [ ] **Step 3: Implement** `SubscriptionVoice.swift`; in `RealtimeHost.handle` call `subscription.handle` first and `subscription.asleep()` on `"asleep"`; in `AppDelegate` start `BlueyMCPServer` at launch with `call: { name, args in subscription.toolOutput(name, await host.runQueuedTool(name, arguments: args)) }`, build the session's `arguments` from `ClaudeStream.arguments(model: "haiku", systemPrompt: RealtimeHost.instructions + voiceNotes, mcpConfig: server.configJSON(port:))`, call `ClaudeBinary.lookUpInShell()`, and send Codex notes to `subscription.codexNote` before the phone.
- [ ] **Step 4: Run** → pass; full suite → pass (including existing focus tests, proving Fast-mode code paths still compile and behave).
- [ ] **Step 5: Commit** `feat(voice): subscription turns on the Mac`

### Task 7: Phone — hold to talk through Scribe

**Files:**
- Create: `iOS/Sources/ScribeListener.swift`
- Modify: `iOS/Sources/MacLink.swift:19, 118-125` (route `voice*` packets)
- Modify: `iOS/Sources/LiveVoice.swift` (subscription branch)
- Modify: `iOS/Sources/GooglyApp.swift:124-175` (wiring)

**Interfaces:**
- Consumes: `ScribeRealtime`, `ScribeTurn` (Task 1), packets from Task 6.
- Produces:
  - `MacLink.onVoice: ((Packet) -> Void)?` — packets whose `command` starts with `"voice"` and have no waiting `callID` go here instead of `onCommand`.
  - `final class ScribeListener { init(token: String, keyterms: [String]); var onEvent: ((ScribeTurn.Event) -> Void)?; func start(); func send(_ pcm: Data); func release() -> ScribeTurn.Release; func cancel() }` — `URLSessionWebSocketTask`, text frames only, connect timeout 5 s, `session_started` timeout 4 s, 8 s ceiling from release to final (then `.failed("timeout")`); closes the socket after the final.
  - `LiveVoice` additions: `var startVoice: ((@escaping (String?) -> Void) -> Void)?`, `var requestScribeToken: ((@escaping (String?) -> Void) -> Void)?`, `var sendToMac: ((Packet) -> Void)?`, `func receiveVoice(_ packet: Packet)`, `private(set) var mode: VoiceMode`.
- Behaviour (subscription mode only; fast mode code paths untouched):
  - `wake()` asks `startVoice` first; `"subscription"` → `startAudio()` without opening the OpenAI socket, state `.listening`; anything else (incl. nil from an older Mac) → existing fast path.
  - `beginAsk()` → if a turn is `.thinking`/`.speaking`, send `voiceCancel` for it; bump `turn`; request `scribeToken` (the Mac answers from its prefetched token, one LAN round trip, so the phone never holds a token that can go stale), then create a `ScribeListener` and `start()`. Audio captured before the socket is ready is buffered by `ScribeTurn`.
  - **Hold while asleep:** `beginAsk()` wakes him; when `startVoice` resolves to subscription and the user is still holding, the hold continues as above (listener created, buffered audio flushed). Releasing before that resolves still produces one turn once the socket starts.
  - `sendMic` forwards the 24 kHz PCM16 `wireFormat` data to the listener only while holding.
  - `endAsk()` → `release()`: `.tooShort`/`.overflowed` → existing "I didn't catch that…" / "Voice took too long…" feedback, state `.listening`, no `voiceAsk`.
  - `.final(text)` → empty: "I didn't hear a task. Hold Bluey while you say it."; else `onUserTurn`/`onUserWords` with a new item id, `sendToMac(Packet(command: "voiceAsk", speech: turn, text: text))`, state `.thinking`, start a 120 s watchdog.
  - `.failed(type)` → feedback "Voice transcription failed (\(type)). Try again." state `.listening`.
  - `receiveVoice`: ignore packets whose `speech` is neither the current turn nor 0; each one restarts the watchdog; first `voiceDelta` → `.speaking` + chirp; `voiceDone` → `onReply` (non-empty), `.listening`; `voiceError` → feedback + `.listening`; `voiceReport` → `onReport`.
  - The phone does **not** send `caption`/`captionDone` in subscription mode (the Mac draws the bubble).
  - `writeDiagnostics` adds `mode` and the turn timings: `holdStarted`, `scribeStarted`, `released`, `finalTranscript`, `firstDelta`, `done` (seconds since hold).

- [ ] **Step 1: Build the phone** — `xcodegen generate && xcodebuild -project GooglyEyes.xcodeproj -scheme GooglyEyes -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/BlueyVoiceDerivedData build` → `** BUILD SUCCEEDED **`.
- [ ] **Step 2: Build the Mac** — `./scripts/build-mac.sh` → succeeds; `swift test --scratch-path /tmp/bluey-voice-swift` → all pass.
- [ ] **Step 3: Device run** (founder present, ElevenLabs key saved, Voice = Subscription, Colima not needed). Install per README, then check and record in the PR:
  - while he's asleep, hold + "hola Bluey" → he wakes and answers that same question (first interaction);
  - hold + "¿qué app tengo abierta?" → bubble answers about the real frontmost app (tool path works);
  - hold + "my name is Jesús", then hold + "what's my name?" → he remembers;
  - tap-and-release instantly → "I didn't catch that", and Mac log shows no Claude turn;
  - hold while he's answering → old reply stops, new one answers;
  - Voice = Fast → the old OpenAI Realtime path still works;
  - read `Documents/bluey-voice-status.json` timings for 5 turns: release→first delta (target ≤ 1.5 s without tools).
- [ ] **Step 4: Commit** `feat(voice): hold to talk through Scribe in subscription mode`

## Milestone 2 — Bluey speaks

### Task 8: Sentence TTS on the Mac

**Files:**
- Modify: `Mac/Sources/GooglyMac/ElevenLabs.swift` (speech + voices)
- Create: `Mac/Sources/GooglyMac/SentenceSplitter.swift`
- Modify: `Mac/Sources/GooglyMac/SubscriptionVoice.swift`, `Settings.swift`, `AppDelegate.swift`
- Test: `Tests/GooglyMacTests/SentenceSplitterTests.swift`, `Tests/GooglyMacTests/SubscriptionVoiceTests.swift`

**Interfaces:**
- Produces:
  - `struct SentenceSplitter { mutating func feed(_ replySoFar: String) -> [String]; mutating func finish() -> String? }` — emits each sentence once, when followed by whitespace after `.`, `!`, `?` or `…`; `finish()` returns the unterminated rest (nil if blank).
  - `ElevenLabs.speech(_ text: String, voiceID: String) -> AsyncThrowingStream<Data, Error>` (HTTP stream per Global Constraints; yields ~0.25 s chunks = 12 000 bytes, last one shorter) and `ElevenLabs.voices(language: String) async throws -> [(id: String, name: String)]` via `GET https://api.elevenlabs.io/v2/voices?language=<lang>&category=premade&page_size=100`.
  - `Settings.speakAloud: Bool` (default true), `Settings.voiceID: String` (default empty → the first premade voice whose `verified_languages` include both `en` and `es` for `eleven_flash_v2_5`, then saved). The voice picker lists only voices verified for both languages. No `language_code` is sent to TTS (Flash v2.5 follows the text).
  - Menu: "Speak Aloud" checkmark and "Voice…" (popup of `voices`) under the Voice submenu.
  - `SubscriptionVoice` init gains `speak: @escaping (_ text: String) -> AsyncThrowingStream<Data, Error>`; when `speakAloud`, sentences are spoken strictly in order and each chunk goes out as `Packet(command: "voiceAudio", audio: base64, speech: turn)`; after the last chunk of the turn, `Packet(command: "voiceAudioEnd", speech: turn)`. TTS failure → one caption "Couldn't speak: …" and the text reply still completes.
- [ ] **Step 1: Write the failing tests** — splitter: `feed("Hola. Qué") == ["Hola."]`, then `feed("Hola. Qué tal? Bien") == ["Qué tal?"]`, `finish() == "Bien"`; `feed("3.5 grados") == []` (no whitespace after the dot); `feed("¡Listo!") == []` then `finish() == "¡Listo!"`. SubscriptionVoice: `testSpeaksSentencesInOrder` (fake `speak` yields one chunk per sentence with the sentence's bytes → `voiceAudio` payloads decode in sentence order, then `voiceAudioEnd`), `testCancelStopsSpeech` (cancel mid-turn → no `voiceAudio` for that turn after the cancel), `testSpeakAloudOff` (no `voiceAudio`).
- [ ] **Step 2: Run** `--filter "SentenceSplitterTests|SubscriptionVoiceTests"` → fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → pass; full suite → pass.
- [ ] **Step 5: Commit** `feat(voice): Bluey speaks his replies with ElevenLabs`

### Task 9: Phone playback and barge-in

**Files:**
- Modify: `iOS/Sources/LiveVoice.swift`

**Interfaces:**
- Consumes: `voiceAudio`, `voiceAudioEnd` (Task 8).
- Behaviour: `receiveVoice` converts PCM16 24 kHz mono to the existing Float32 `playbackFormat` buffers and schedules them on `player` (volume = `volume`); skip the text-reply chirp when audio arrives for the turn; state stays `.speaking` until the last scheduled buffer of a turn that got `voiceAudioEnd` finishes, then `.listening`. `beginAsk()` stops `player`, drops queued buffers and ignores later audio for the old turn. Voice processing (`setVoiceProcessingEnabled(true)`) stays on for echo cancellation.
- [ ] **Step 1: Build** phone and Mac (commands from Task 7 Steps 1–2) → succeed.
- [ ] **Step 2: Device run:** he speaks each answer in the chosen voice; first sound within ~2 s of release on a no-tool question; holding while he talks silences him at once and the new question is answered; Speak Aloud off → bubbles only.
- [ ] **Step 3: Commit** `feat(voice): play Bluey's voice on the phone and stop it when you hold`

## Milestone 3 — meeting notes on Scribe batch

### Task 10: Scribe v2 batch for meeting notes

Meeting-audio recording is off today (`ChunkRecorder.start` is never called), so this only matters when it is turned back on. Verify with `GOOGLY_DEMO_TRANSCRIBE`.

**Files:**
- Modify: `Mac/Sources/GooglyMac/MeetingNotes.swift:64-124`
- Test: `Tests/GooglyMacTests/MeetingNotesScribeTests.swift`

**Interfaces:**
- Produces: `static func segments(fromScribeWords words: [[String: Any]]) -> [Segment]` (skip `type == "spacing"`/`"audio_event"`; consecutive words with the same `speaker_id` form one segment; then merge same-speaker segments less than 2.5 s apart, as `diarized` does today; speaker names `"Speaker 1"`, `"Speaker 2"`… in order of first appearance) and `static func scribeBatch(audio: Data) async throws -> [Segment]`. `transcribe` uses Scribe when `Keychain.get(.elevenlabs)` exists, otherwise the current OpenAI path.
- [ ] **Step 1: Write the failing tests** — two speakers alternating → three segments with correct `speaker`, `start`, `end`, `text`; a 1 s gap with the same speaker merges; spacing/audio events never appear in text.
- [ ] **Step 2: Run** `--filter MeetingNotesScribeTests` → fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → pass; live: `GOOGLY_DEMO_TRANSCRIBE=<path to an .m4a> build/Bluey.app/Contents/MacOS/GooglyMac` → speaker-labelled lines printed.
- [ ] **Step 5: Commit** `feat(notes): transcribe meeting audio with Scribe v2 batch`

### Task 11: Docs and close-out

**Files:**
- Modify: `README.md` (setup: ElevenLabs key, Voice menu, Claude Code sign-in; privacy: audio goes to ElevenLabs while held, text to Anthropic through the user's Claude Code; measured latencies from Tasks 7 and 9)

- [ ] **Step 1: Update README** and the "Latest local verification" paragraph with the real test count and device results.
- [ ] **Step 2: Commit** `docs: subscription voice setup, privacy and measured latency`
- [ ] **Step 3: Close out per the founder's rules:** push, build and install both apps, close merged worktrees/terminals (copy any `.env*`/`.dev.vars` to the main worktree first), and record the status with `mcp__recall__remember` (folder `bluey`).
