import XCTest
@testable import GooglyMac

final class ElevenLabsTokensTests: XCTestCase {
    /// Hands out "a", "b", … and counts calls.
    final class Minter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func next() -> String {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return String(UnicodeScalar(UInt8(96 + calls)))
        }
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = Date(timeIntervalSince1970: 1_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return time }
        func advance(_ seconds: TimeInterval) { lock.lock(); time += seconds; lock.unlock() }
    }

    func testHandsOutPrefetchedToken() async throws {
        let minter = Minter()
        let tokens = ElevenLabsTokens(mint: { minter.next() })
        await tokens.prefetch()
        XCTAssertEqual(minter.count, 1)
        let token = try await tokens.token()
        XCTAssertEqual(token, "a")
    }

    func testNeverReusesToken() async throws {
        let minter = Minter()
        let tokens = ElevenLabsTokens(mint: { minter.next() })
        await tokens.prefetch()
        let first = try await tokens.token()
        let second = try await tokens.token()
        XCTAssertNotEqual(first, second)
    }

    func testConcurrentPrefetchAndTokenNeverShareAToken() async throws {
        let minter = Minter()
        let tokens = ElevenLabsTokens(mint: { try await Task.sleep(nanoseconds: 5_000_000); return minter.next() })
        let handed = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<6 {
                group.addTask { await tokens.prefetch(); return try await tokens.token() }
            }
            var all: [String] = []
            for try await t in group { all.append(t) }
            return all
        }
        XCTAssertEqual(Set(handed).count, handed.count)
    }

    func testDiscardsStaleToken() async throws {
        let minter = Minter()
        let clock = Clock()
        let tokens = ElevenLabsTokens(now: { clock.now }, mint: { minter.next() })
        await tokens.prefetch()
        clock.advance(13 * 60 + 1)
        let token = try await tokens.token()
        XCTAssertNotEqual(token, "a")
    }

    func testMintFailurePropagates() async {
        let tokens = ElevenLabsTokens(mint: { throw ElevenLabs.Failure.noKey })
        do {
            _ = try await tokens.token()
            XCTFail("expected noKey")
        } catch ElevenLabs.Failure.noKey {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
