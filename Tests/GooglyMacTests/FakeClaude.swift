import Foundation

/// Fake `claude` binaries for tests: `/bin/sh` scripts, no real CLI or network.
enum FakeClaude {
    /// Writes an executable `/bin/sh` script into `directory` and returns its URL.
    static func script(_ body: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("claude-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
