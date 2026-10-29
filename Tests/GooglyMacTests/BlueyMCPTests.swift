import Network
import XCTest
@testable import GooglyMac

final class BlueyMCPTests: XCTestCase {
    private static let token = "test-token"
    private static let bearer = "Bearer test-token"

    private final class Calls: @unchecked Sendable {
        var received: [(name: String, arguments: String)] = []
    }

    private func handler(calls: Calls = Calls(), reply: (text: String, image: String?) = ("ok", nil)) -> MCPHandler {
        MCPHandler(token: Self.token,
                   tools: { [["type": "function", "name": "look_at_screen", "description": "Look.",
                              "parameters": ["type": "object", "properties": [:], "required": []]]] },
                   call: { name, arguments in
                       calls.received.append((name, arguments))
                       return reply
                   })
    }

    private func rpc(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    func testToolListMapping() throws {
        let parameters: [String: Any] = ["type": "object", "properties": ["x": ["type": "number"]], "required": ["x"]]
        let list = MCPTools.list(from: [["type": "function", "name": "point_at_spot", "description": "Point.", "parameters": parameters]])
        XCTAssertEqual(list.count, 1)
        let tool = list[0]
        XCTAssertEqual(tool["name"] as? String, "point_at_spot")
        XCTAssertEqual(tool["description"] as? String, "Point.")
        XCTAssertNil(tool["type"])
        XCTAssertEqual(tool["inputSchema"] as? NSDictionary, parameters as NSDictionary)
    }

    func testRejectsWrongToken() async {
        let body = rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let wrong = await handler().respond(method: "POST", authorization: "Bearer nope", body: body)
        XCTAssertEqual(wrong.status, 401)
        let missing = await handler().respond(method: "POST", authorization: nil, body: body)
        XCTAssertEqual(missing.status, 401)
        let bare = await handler().respond(method: "POST", authorization: Self.token, body: body)
        XCTAssertEqual(bare.status, 401)
    }

    func testGetNotAllowed() async {
        let response = await handler().respond(method: "GET", authorization: Self.bearer, body: Data())
        XCTAssertEqual(response.status, 405)
    }

    func testNotificationAccepted() async {
        let response = await handler().respond(method: "POST", authorization: Self.bearer,
                                               body: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        XCTAssertEqual(response.status, 202)
        XCTAssertNil(response.body)
    }

    func testInitializeEchoesVersion() async throws {
        let response = await handler().respond(method: "POST", authorization: Self.bearer, body: rpc(
            ["jsonrpc": "2.0", "id": "a1", "method": "initialize",
             "params": ["protocolVersion": "2099-01-01", "capabilities": [:], "clientInfo": ["name": "claude"]]]))
        XCTAssertEqual(response.status, 200)
        let reply = try json(response.body)
        XCTAssertEqual(reply["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(reply["id"] as? String, "a1")
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2099-01-01")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "bluey")
    }

    func testToolsList() async throws {
        let response = await handler().respond(method: "POST", authorization: Self.bearer,
                                               body: rpc(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        let reply = try json(response.body)
        XCTAssertEqual(reply["id"] as? Int, 2)
        let tools = try XCTUnwrap((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["look_at_screen"])
        XCTAssertNotNil(tools[0]["inputSchema"])
    }

    func testToolsCallWithImage() async throws {
        let calls = Calls()
        let response = await handler(calls: calls, reply: ("Safari", "AAAA")).respond(method: "POST", authorization: Self.bearer, body: rpc(
            ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "look_at_screen", "arguments": ["x": 5]]]))
        XCTAssertEqual(response.status, 200)
        let reply = try json(response.body)
        XCTAssertEqual(reply["id"] as? Int, 7)
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "Safari")
        XCTAssertEqual(content[1]["type"] as? String, "image")
        XCTAssertEqual(content[1]["data"] as? String, "AAAA")
        XCTAssertEqual(content[1]["mimeType"] as? String, "image/jpeg")
        XCTAssertEqual(calls.received.map(\.name), ["look_at_screen"])
        let arguments = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(calls.received[0].arguments.utf8)) as? [String: Any])
        XCTAssertEqual(arguments["x"] as? Int, 5)
    }

    func testToolsCallWithoutArguments() async throws {
        let calls = Calls()
        let response = await handler(calls: calls).respond(method: "POST", authorization: Self.bearer, body: rpc(
            ["jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": ["name": "focus_status"]]))
        let content = try XCTUnwrap((try json(response.body)["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(calls.received.first?.arguments, "{}")
    }

    func testUnknownMethod() async throws {
        let response = await handler().respond(method: "POST", authorization: Self.bearer,
                                               body: rpc(["jsonrpc": "2.0", "id": 3, "method": "server/discover"]))
        let error = try XCTUnwrap(try json(response.body)["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    func testMalformedJSON() async throws {
        let response = await handler().respond(method: "POST", authorization: Self.bearer, body: Data("{nope".utf8))
        let reply = try json(response.body)
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertTrue(reply["id"] is NSNull)
    }

    func testHTTPRoundTrip() async throws {
        let server = BlueyMCPServer(handler: handler())
        let port = try server.start()
        defer { server.stop() }
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(server.configJSON(port: port).utf8)) as? [String: Any])
        let bluey = try XCTUnwrap((config["mcpServers"] as? [String: Any])?["bluey"] as? [String: Any])
        XCTAssertEqual(bluey["type"] as? String, "http")
        XCTAssertEqual(bluey["url"] as? String, "http://127.0.0.1:\(port)/mcp")
        XCTAssertEqual((bluey["headers"] as? [String: Any])?["Authorization"] as? String, Self.bearer)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue(Self.bearer, forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = rpc(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let result = try XCTUnwrap(try json(data)["result"] as? [String: Any])
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "bluey")

        request.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
        let (_, rejected) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 401)
    }

    func testHTTPFraming() async throws {
        let server = BlueyMCPServer(handler: handler())
        let port = try server.start()
        defer { server.stop() }
        // Wrong token is answered from the headers alone, without waiting for the promised body.
        let unauthorized = await raw("POST /mcp HTTP/1.1\r\nauthorization: Bearer nope\r\nContent-Length: 500\r\n\r\n", port: port)
        XCTAssertTrue(unauthorized.hasPrefix("HTTP/1.1 401"), unauthorized)
        let noLength = await raw("POST /mcp HTTP/1.1\r\nAUTHORIZATION: \(Self.bearer)\r\n\r\n", port: port)
        XCTAssertTrue(noLength.hasPrefix("HTTP/1.1 411"), noLength)
        let tooBig = await raw("POST /mcp HTTP/1.1\r\nAuthorization: \(Self.bearer)\r\nContent-Length: 2000000\r\n\r\n", port: port)
        XCTAssertEqual(tooBig, "")
        let hugeHeaders = await raw("POST /mcp HTTP/1.1\r\nX-Pad: \(String(repeating: "a", count: 20_000))\r\n\r\n", port: port)
        XCTAssertEqual(hugeHeaders, "")
    }

    /// Sends raw bytes and returns everything the server writes before closing.
    private func raw(_ request: String, port: UInt16) async -> String {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "raw")
        connection.start(queue: queue)
        connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
        let data = await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            var collected = Data()
            func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    if let data { collected.append(data) }
                    if isComplete || error != nil { continuation.resume(returning: collected) } else { read() }
                }
            }
            read()
        }
        connection.cancel()
        return String(decoding: data, as: UTF8.self)
    }
}
