import Foundation
import Network
import Security

/// Bluey's Realtime tool definitions in MCP shape.
enum MCPTools {
    static func list(from realtime: [[String: Any]]) -> [[String: Any]] {
        realtime.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            return ["name": name, "description": tool["description"] as? String ?? "",
                    "inputSchema": tool["parameters"] ?? ["type": "object", "properties": [String: Any]()]]
        }
    }
}

/// Answers MCP (streamable HTTP, JSON responses only) requests; no networking.
struct MCPHandler {
    let token: String
    let tools: () -> [[String: Any]]
    /// Runs a tool with its arguments as a JSON object string; `image` is raw base64 JPEG.
    let call: (_ name: String, _ argumentsJSON: String) async -> (text: String, image: String?)

    /// 32 random bytes as hex.
    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return (0..<4).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time check of an `Authorization` header value.
    func authorizes(_ authorization: String?) -> Bool {
        let given = Array((authorization ?? "").utf8), expected = Array("Bearer \(token)".utf8)
        var difference: UInt8 = given.count == expected.count ? 0 : 1
        for index in expected.indices { difference |= expected[index] ^ (index < given.count ? given[index] : 0) }
        return difference == 0
    }

    func respond(method: String, authorization: String?, body: Data) async -> (status: Int, body: Data?) {
        guard authorizes(authorization) else { return (401, nil) }
        guard method == "POST" else { return (405, nil) }
        guard let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return (200, Self.error(id: NSNull(), code: -32700, "Parse error"))
        }
        // Notifications (no id) get no answer.
        guard let id = request["id"] else { return (202, nil) }
        let params = request["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch request["method"] as? String {
        case "initialize":
            result = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                      "capabilities": ["tools": [String: Any]()],
                      "serverInfo": ["name": "bluey", "version": "1"]]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": MCPTools.list(from: tools())]
        case "tools/call":
            guard let name = params["name"] as? String else { return (200, Self.error(id: id, code: -32602, "Missing tool name")) }
            let arguments = (params["arguments"] as? [String: Any])
                .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            let output = await call(name, arguments)
            var content: [[String: Any]] = [["type": "text", "text": output.text]]
            if let image = output.image { content.append(["type": "image", "data": image, "mimeType": "image/jpeg"]) }
            result = ["content": content, "isError": false]
        default:
            return (200, Self.error(id: id, code: -32601, "Method not found"))
        }
        return (200, Self.encode(["jsonrpc": "2.0", "id": id, "result": result]))
    }

    private static func error(id: Any, code: Int, _ message: String) -> Data {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}

/// Minimal HTTP/1.1 server on 127.0.0.1 that feeds `MCPHandler`; one request per connection.
final class BlueyMCPServer: @unchecked Sendable {
    enum Failure: Error { case notReady }

    private static let maxHeader = 16 * 1024
    private static let maxBody = 1024 * 1024
    /// How long a client gets to send its whole request (tool calls themselves aren't limited).
    private static let readDeadline: TimeInterval = 10

    private let handler: MCPHandler
    private let queue = DispatchQueue(label: "bluey.mcp")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(handler: MCPHandler) {
        self.handler = handler
    }

    /// Starts listening and returns the port. Don't call on `queue`.
    func start() throws -> UInt16 {
        stop()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        let port = Box<UInt16?>(nil)
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready: port.value = listener?.port?.rawValue; ready.signal()
            case .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        queue.sync { self.listener = listener }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success, let bound = port.value, bound != 0 else {
            stop()
            throw Failure.notReady
        }
        listener.stateUpdateHandler = nil
        return bound
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            connections.values.forEach { $0.cancel() }
            connections = [:]
        }
    }

    func configJSON(port: UInt16) -> String {
        let config: [String: Any] = ["mcpServers": ["bluey": [
            "type": "http", "url": "http://127.0.0.1:\(port)/mcp",
            "headers": ["Authorization": "Bearer \(handler.token)"]]]]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Connections (all on `queue`)

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections[id] = nil
            default: break
            }
        }
        let deadline = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + Self.readDeadline, execute: deadline)
        connection.start(queue: queue)
        receive(connection, buffer: Data(), deadline: deadline)
    }

    private func receive(_ connection: NWConnection, buffer: Data, deadline: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch self.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil { connection.cancel() } else { self.receive(connection, buffer: buffer, deadline: deadline) }
            case .tooLarge:
                connection.cancel()
            case .respond(let status):
                deadline.cancel()
                self.reply(connection, status: status, body: nil)
            case .request(let method, let authorization, let body):
                deadline.cancel()
                let handler = self.handler
                Task {
                    let response = await handler.respond(method: method, authorization: authorization, body: body)
                    self.queue.async { self.reply(connection, status: response.status, body: response.body) }
                }
            }
        }
    }

    private enum Parsed {
        case incomplete, tooLarge
        case respond(Int)
        case request(method: String, authorization: String?, body: Data)
    }

    /// Reads one request; rejects a bad token before waiting for the body.
    private func parse(_ buffer: Data) -> Parsed {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > Self.maxHeader ? .tooLarge : .incomplete
        }
        guard end.lowerBound - buffer.startIndex <= Self.maxHeader else { return .tooLarge }
        let lines = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let method = lines.first?.split(separator: " ").first.map(String.init) ?? ""
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let authorization = headers["authorization"]
        guard handler.authorizes(authorization) else { return .respond(401) }
        let length: Int
        if let value = headers["content-length"] {
            guard let parsed = Int(value), parsed >= 0 else { return .tooLarge }
            length = parsed
        } else if method == "POST" {
            return .respond(411)
        } else {
            length = 0
        }
        guard length <= Self.maxBody else { return .tooLarge }
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return .incomplete }
        return .request(method: method, authorization: authorization, body: Data(body.prefix(length)))
    }

    private func reply(_ connection: NWConnection, status: Int, body: Data?) {
        let reason = [200: "OK", 202: "Accepted", 401: "Unauthorized", 405: "Method Not Allowed", 411: "Length Required"][status] ?? "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body?.count ?? 0)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + (body ?? Data()), isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// A value handed from the listener's queue to the thread waiting in `start()`.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
