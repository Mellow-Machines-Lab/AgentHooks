import Foundation
import Testing
@testable import AgentHooks

/// The listening end: the server an app keeps.
@Suite struct HookServerTests {
    /// Letting go of a running server stops it, as `stop()` would: its
    /// accepting thread doesn't keep it, so the socket closes and its file
    /// goes, and no hook reaches a server nobody holds.
    @Test func testLettingGoOfTheServerStopsIt() throws {
        let path = NSTemporaryDirectory() + "ah-letgo-\(getpid()).sock"
        let received = Received()
        let line = HookLine(agent: "claude", hook: "Stop", session: "s1", ts: 1)
        weak var gone: HookServer?
        do {
            let server = HookServer(path: path) { line in received.add(line) }
            try server.start()
            gone = server
            // The thread is accepting before the server is let go.
            #expect(HookSocket.send(line.encoded(), to: path))
            let deadline = Date().addingTimeInterval(2)
            while received.count < 1 && Date() < deadline { usleep(10_000) }
            #expect(received.count == 1)
        }
        #expect(gone == nil, "the accepting thread let go of the server")
        #expect(!(FileManager.default.fileExists(atPath: path)))
        #expect(!(HookSocket.send(line.encoded(), to: path)))
        #expect(received.count == 1)
    }
}
