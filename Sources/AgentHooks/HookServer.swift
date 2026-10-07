import AgentHooksWire
import Darwin
import Foundation

/// An app's hook socket: accepts `agent-hook` connections and
/// hands each line on. It never writes anything back, so a hook can't be
/// answered. List its path in `HookSocket.directory` (`HookSocket.register`)
/// so the client sends to it.
public final class HookServer: @unchecked Sendable {
    public let path: String
    private let state: State

    /// What the accepting thread needs, apart from the server, so letting
    /// go of the server stops it: a thread holding the server itself would
    /// keep it, and its socket, for good.
    private final class State: @unchecked Sendable {
        let onLine: @Sendable (HookLine) -> Void
        let onOther: (@Sendable (Data) -> Void)?
        let lock = NSLock()
        var listener: Int32 = -1

        init(onLine: @escaping @Sendable (HookLine) -> Void, onOther: (@Sendable (Data) -> Void)?) {
            self.onLine = onLine
            self.onOther = onOther
        }
    }

    /// `onLine` gets each line on the server's own thread. `onOther` gets
    /// lines that aren't hook lines, for an app's own commands; without it
    /// they're dropped.
    public init(path: String, onLine: @escaping @Sendable (HookLine) -> Void,
                onOther: (@Sendable (Data) -> Void)? = nil) {
        self.path = path
        state = State(onLine: onLine, onOther: onOther)
    }

    public enum StartError: Error { case pathTooLong, socket(Int32), bind(Int32), listen(Int32) }

    public func start() throws {
        guard var address = HookSocket.unixAddress(path) else { throw StartError.pathTooLong }
        // A new folder is this user's alone, so nobody else can reach the
        // socket in the moment between `bind` and `chmod`.
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socket(errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let error = errno
            close(fd)
            throw StartError.bind(error)
        }
        chmod(path, 0o600)
        guard listen(fd, 128) == 0 else {
            let error = errno
            close(fd)
            throw StartError.listen(error)
        }
        let state = state
        state.lock.withLock { state.listener = fd }
        let thread = Thread { HookServer.acceptLoop(fd, state) }
        thread.name = "agent-hooks.server"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    public func stop() {
        let state = state
        let fd = state.lock.withLock { () -> Int32 in
            defer { state.listener = -1 }
            return state.listener
        }
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path)
    }

    deinit { stop() }

    /// Runs until `stop()`. Any other failed `accept` (out of file
    /// descriptors, an aborted connection) is waited out, so hooks keep
    /// arriving once it passes. Each connection gets its own autorelease
    /// pool: this thread never returns, so what decoding a line leaves
    /// autoreleased would otherwise pile up for good.
    private static func acceptLoop(_ fd: Int32, _ state: State) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                let error = errno
                if state.lock.withLock({ state.listener }) != fd { return }  // closed by stop()
                if error != EINTR { usleep(10_000) }
                continue
            }
            autoreleasepool { handle(client, state) }
        }
    }

    /// A hook writes one short line and closes. Read it with a short timeout
    /// so a stuck client can't hold up the next one.
    private static func handle(_ client: Int32, _ state: State) {
        defer { close(client) }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 64 * 1024 {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        for part in data.split(separator: 0x0A) where !part.isEmpty {
            if let line = HookLine.decode(Data(part)) {
                state.onLine(line)
            } else {
                state.onOther?(Data(part))
            }
        }
    }
}
