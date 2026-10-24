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

    /// The apps listed: each link, its app open or closed, and each socket
    /// something listens at; not a socket left behind, nor anything else.
    @Test func testTheAppsListed() throws {
        let root = NSTemporaryDirectory() + "ah-listed-\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let env = ["AGENT_HOOKS_DIR": root]
        let dir = HookSocket.directory(environment: env)
        #expect(HookSocket.listed(environment: env).isEmpty, "no folder")
        try HookSocket.register(root + "/closed-app.sock", as: "closed", environment: env)
        let live = HookServer(path: dir + "/tail-1.sock") { _ in }
        try live.start()
        defer { live.stop() }
        // A crashed listener's socket: still there, nobody listening.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try #require(HookSocket.unixAddress(dir + "/tail-2.sock"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        close(fd)
        FileManager.default.createFile(atPath: dir + "/notes.txt", contents: Data())
        #expect(HookSocket.listed(environment: env) == ["closed", "tail-1"])
    }
}
