import AppKit

/// Explicit opt-in developer probe: one real `claude -p` question through `BlueyMCPServer`.
/// `look_at_screen` is a stub with a synthetic image, never the user's desktop.
enum ClaudeVoiceProbe {
    private static let question = "Look at my screen. What shapes do you see and what number is written?"
    private static let prompt = "You are Bluey, a terse voice assistant on the user's Mac. Use your tools when asked about the screen. Answer in one or two short sentences."

    @MainActor static func run() async -> Int32 {
        let start = Date()
        let stamp: @Sendable (String) -> Void = { print(String(format: "%6.2fs  ", Date().timeIntervalSince(start)) + $0) }
        guard let jpeg = syntheticScreen() else { print("Could not draw the synthetic screen"); return 1 }
        await ClaudeBinary.lookUpInShell()
        guard let binary = ClaudeBinary.locate() else { print("claude not found"); return 1 }
        stamp("claude at \(binary.path)")

        let tools = RealtimeHost.tools.filter { $0["name"] as? String == "look_at_screen" }
        let toolCalls = Counter()
        let handler = MCPHandler(token: MCPHandler.randomToken(),
                                 tools: { stamp("MCP tools/list"); return tools },
                                 call: { name, arguments in
                                     toolCalls.increment()
                                     stamp("MCP tools/call \(name) \(arguments)")
                                     return ("Frontmost app: Keynote.", jpeg.base64EncodedString())
                                 })
        let server = BlueyMCPServer(handler: handler)
        let port: UInt16
        do { port = try server.start() } catch { print("MCP server failed: \(error)"); return 1 }
        stamp("MCP server on 127.0.0.1:\(port)")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bluey-voice-probe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = server.configJSON(port: port)
        let session = ClaudeVoiceSession(arguments: { ClaudeStream.arguments(model: "haiku", systemPrompt: prompt, mcpConfig: config) },
                                         workingDirectory: directory)
        defer {
            session.stop()
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        session.warmUp()
        stamp("spawned; asking: \(question)")

        var sawEvent = false, sawText = false, toolUses: [String] = []
        let reply: String
        do {
            reply = try await session.ask(question) { event in
                if !sawEvent { sawEvent = true; stamp("first event") }
                switch event {
                case .toolUse(let name): toolUses.append(name); stamp("toolUse(\(name))")
                case .textDelta: if !sawText { sawText = true; stamp("first text") }
                case .result(_, let isError): stamp("result isError=\(isError)")
                case .other: break
                }
            }
        } catch {
            stamp("ask failed: \(error.localizedDescription)")
            return 1
        }
        stamp("reply: \(reply)")
        let lower = reply.lowercased()
        let passed = toolUses.contains("look_at_screen") && toolCalls.value > 0
            && (lower.contains("rectangle") || lower.contains("square")) && lower.contains("circle")
            && (reply.contains("1,284") || reply.contains("1284"))
        print(passed ? "PASS" : "FAIL (toolUses=\(toolUses), tool calls served=\(toolCalls.value))")
        return passed ? 0 : 1
    }

    /// White page with a blue rectangle, an orange circle and a line of text.
    @MainActor private static func syntheticScreen() -> Data? {
        let size = NSSize(width: 960, height: 600)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        NSColor.systemBlue.setFill(); NSRect(x: 80, y: 120, width: 300, height: 180).fill()
        NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: NSRect(x: 560, y: 120, width: 200, height: 200)).fill()
        ("Quarterly sales: 1,284 units" as NSString).draw(at: NSPoint(x: 80, y: 440),
            withAttributes: [.font: NSFont.boldSystemFont(ofSize: 40), .foregroundColor: NSColor.black])
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

/// Thread-safe count of tool calls served.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
