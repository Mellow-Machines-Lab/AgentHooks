import Darwin
import Foundation

/// Where hook lines go. Every app that listens has a socket,
/// or a link to one, in one folder, and the client sends each line to
/// all of them, so any number of apps can listen with nothing else
/// running.
public enum HookSocket {
    /// The folder apps listen in: `$AGENT_HOOKS_DIR/sockets`, else
    /// `~/.agent-hooks/sockets`. Short, since a socket's path has room for
    /// 103 bytes.
    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let root = environment["AGENT_HOOKS_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (environment["HOME"] ?? NSHomeDirectory()) + "/.agent-hooks"
        return root + "/sockets"
    }

    /// Where a hook line goes: `$AGENT_HOOKS_SOCKET` alone when it's set
    /// (tests and checks), else every `*.sock` in `directory`, in name order,
    /// and nowhere if that folder isn't `isPrivate`: another user who could
    /// add a link there would hear every hook.
    public static func destinations(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        if let path = environment["AGENT_HOOKS_SOCKET"], !path.isEmpty { return [path] }
        let dir = directory(environment: environment)
        guard isPrivate(dir) else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasSuffix(".sock") }.sorted().map { dir + "/" + $0 }
    }

    /// Lists an app's socket at `path` in `directory` as `name.sock`, a
    /// link unless it's there already, so the client sends to it. Once is
    /// enough: a link left behind while the app is closed costs a hook
    /// nothing, since connecting fails at once.
    public static func register(_ path: String, as name: String,
                                environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let dir = directory(environment: environment)
        let link = dir + "/" + name + ".sock"
        guard link != path else { return }
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        tighten(dir)
        if (try? fm.destinationOfSymbolicLink(atPath: link)) == path { return }
        try? fm.removeItem(atPath: link)
        try fm.createSymbolicLink(atPath: link, withDestinationPath: path)
    }

    /// Whether the client may send to the sockets in `dir`: a real folder,
    /// not a link, owned by this user and writable by nobody else.
    public static func isPrivate(_ dir: String) -> Bool {
        var info = stat()
        guard lstat(dir, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        return info.st_uid == getuid() && info.st_mode & 0o022 == 0
    }

    /// Makes a folder of this user's, as a version before 0700 made it,
    /// readable by this user alone.
    static func tighten(_ dir: String) {
        var info = stat()
        guard lstat(dir, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o077 != 0 else { return }
        chmod(dir, 0o700)
    }

    /// Writes `data` to the socket and returns whether it was sent. Gives up
    /// if the socket is missing or doesn't accept within `timeoutMs`; never
    /// blocks longer than that. Connecting and writing share the one
    /// budget.
    @discardableResult
    public static func send(_ data: Data, to path: String, timeoutMs: Int32 = 50) -> Bool {
        send(data, to: path, deadline: DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeoutMs)) * 1_000_000)
    }

    /// `send` against a deadline in `DispatchTime` uptime nanoseconds.
    static func send(_ data: Data, to path: String, deadline: UInt64) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        guard var address = unixAddress(path) else { return false }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN, let ms = msLeft(until: deadline),
                  wait(fd, for: Int16(POLLOUT), ms: ms) else {
                return false
            }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
            guard error == 0 else { return false }
        }

        // The write gets what the connect left of the budget, not a fresh one.
        var offset = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            while offset < raw.count {
                let n = write(fd, base + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                    continue
                }
                guard n < 0, errno == EAGAIN, let ms = msLeft(until: deadline),
                      wait(fd, for: Int16(POLLOUT), ms: ms) else { return false }
            }
            return true
        }
    }

    /// Whole milliseconds to the deadline, rounded up; nil once it's passed.
    static func msLeft(until deadline: UInt64) -> Int32? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return nil }
        return Int32(min(UInt64(Int32.max), (deadline - now + 999_999) / 1_000_000))
    }

    static func wait(_ fd: Int32, for events: Int16, ms: Int32) -> Bool {
        var entry = pollfd(fd: fd, events: events, revents: 0)
        return poll(&entry, 1, ms) == 1 && entry.revents & events != 0
    }

    /// A `sockaddr_un` for `path`, or nil if the path doesn't fit (104 bytes).
    public static func unixAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (i, byte) in bytes.enumerated() { buffer[i] = byte }
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
}
