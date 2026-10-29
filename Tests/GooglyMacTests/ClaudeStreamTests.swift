import XCTest
@testable import GooglyMac

final class ClaudeStreamTests: XCTestCase {
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
    func testUserLineIsSingleLine() throws {
        let line = ClaudeStream.userLine("uno\ndos\r\ntres")
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(line.hasSuffix("\n"))
        let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        XCTAssertEqual((json["message"] as? [String: Any])?["content"] as? String, "uno\ndos\r\ntres")
    }
    func testInterruptLine() throws {
        let line = ClaudeStream.interruptLine(id: "req-1")
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(line.hasSuffix("\n"))
        let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "control_request")
        XCTAssertEqual(json["request_id"] as? String, "req-1")
        XCTAssertEqual((json["request"] as? [String: Any])?["subtype"] as? String, "interrupt")
    }
    func testParseTextDelta() {
        XCTAssertEqual(ClaudeStream.parse(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}}"#), .textDelta("Hi"))
    }
    func testParseToolUse() {
        XCTAssertEqual(ClaudeStream.parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"mcp__bluey__look_at_screen","input":{}}]}}"#), .toolUse("look_at_screen"))
    }
    func testParseToolUseFirstBlockAndUnprefixedName() {
        XCTAssertEqual(ClaudeStream.parse(#"{"type":"assistant","message":{"content":[{"type":"text","text":"x"},{"type":"tool_use","id":"a","name":"web_research","input":{}},{"type":"tool_use","id":"b","name":"mcp__bluey__other","input":{}}]}}"#), .toolUse("web_research"))
    }
    func testParseAssistantWithoutToolUseIsOther() {
        XCTAssertEqual(ClaudeStream.parse(#"{"type":"assistant","message":{"content":[{"type":"text","text":"hola"}]}}"#), .other)
    }
    func testParseResults() {
        XCTAssertEqual(ClaudeStream.parse(#"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#), .result(text: "ok", isError: false))
        // Real interrupt result (trimmed): no "result" field.
        XCTAssertEqual(ClaudeStream.parse(#"{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"aborted_streaming","errors":["[ede_diagnostic] result_type=user"],"num_turns":2}"#), .result(text: "", isError: true))
    }
    func testParseOther() { XCTAssertEqual(ClaudeStream.parse(#"{"type":"system","subtype":"init"}"#), .other); XCTAssertEqual(ClaudeStream.parse("garbage"), .other) }
}
