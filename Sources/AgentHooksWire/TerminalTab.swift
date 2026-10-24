import Darwin
import Foundation

/// Where in a terminal an agent runs, from its hook's environment, so an
/// app can open the exact tab, not just bring the terminal forward. Only
/// these few variables are read, and each value is kept only when it has
/// its expected shape, since an app may put it into a script.
public struct TerminalTab: Equatable, Codable, Sendable {
    /// `TERM_PROGRAM`: `iTerm.app`, `Apple_Terminal`, `ghostty`, `tmux`…
    public var program: String?
    /// iTerm2's session `unique id`: the part of `ITERM_SESSION_ID`
    /// (`w0t1p0:6A3E…`) after the colon.
    public var itermSession: String?
    /// `TERM_SESSION_ID`, which Terminal.app sets (iTerm2 too). Nothing
    /// opens a tab by it; it tells two tabs apart.
    public var termSession: String?
    /// The agent's controlling terminal, `/dev/ttys003`: how Terminal.app's
    /// tab is found.
    public var tty: String?
    /// tmux's pane, `TMUX_PANE`: `%3`.
    public var tmuxPane: String?
    /// The tmux server's socket, the first part of `TMUX`.
    public var tmuxSocket: String?

    public init(program: String? = nil, itermSession: String? = nil, termSession: String? = nil, tty: String? = nil,
                tmuxPane: String? = nil, tmuxSocket: String? = nil) {
        self.program = program
        self.itermSession = itermSession
        self.termSession = termSession
        self.tty = tty
        self.tmuxPane = tmuxPane
        self.tmuxSocket = tmuxSocket
    }

    enum CodingKeys: String, CodingKey {
        case program, tty
        case itermSession = "iterm_session", termSession = "term_session", tmuxPane = "tmux_pane",
             tmuxSocket = "tmux_socket"
    }

    /// A value's expected shape: a fixed start, then 1 to `max` characters
    /// from a small ASCII set: digits, letters unless `letters` is false,
    /// and `extra`. Checked by hand, not with a regular
    /// expression, which would cost the hook client a few milliseconds.
    public struct Shape: Sendable {
        public let prefix: String
        public let extra: String
        public let max: Int
        public var letters = true

        /// Whether `value` is non-nil and has this shape.
        public func matches(_ value: String?) -> Bool {
            guard let value, value.hasPrefix(prefix) else { return false }
            let rest = value.utf8.dropFirst(prefix.utf8.count)
            return !rest.isEmpty && rest.count <= max && rest.allSatisfy { c in
                (c >= 0x30 && c <= 0x39) || letters && ((c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)) || extra.utf8.contains(c)
            }
        }
    }

    // The shapes kept. Each is checked again before it goes into a script
    // or a command (`ThreadLink`).
    public static let programShape = Shape(prefix: "", extra: "._ -", max: 64)
    /// iTerm2's unique id is a UUID.
    public static let sessionShape = Shape(prefix: "", extra: "-", max: 64)
    public static let termSessionShape = Shape(prefix: "", extra: ":.-", max: 100)
    public static let ttyShape = Shape(prefix: "/dev/tty", extra: "", max: 8)
    public static let paneShape = Shape(prefix: "%", extra: "", max: 6, letters: false)
    public static let socketShape = Shape(prefix: "/", extra: "._/+@-", max: 200)

    /// Whether `value` is non-nil and has `shape`.
    public static func valid(_ value: String?, _ shape: Shape) -> Bool { shape.matches(value) }

    /// The tab, from the hook's environment and its agent's controlling
    /// terminal (`controllingTTY`); nil when nothing says it's a terminal.
    public static func from(env: [String: String], tty: String? = nil) -> TerminalTab? {
        func kept(_ value: String?, _ shape: Shape) -> String? { valid(value, shape) ? value : nil }
        let iterm = env["ITERM_SESSION_ID"].map { $0.split(separator: ":", maxSplits: 1).last.map(String.init) ?? $0 }
        let socket = env["TMUX"].flatMap { $0.split(separator: ",", maxSplits: 1).first.map(String.init) }
        let tab = TerminalTab(program: kept(env["TERM_PROGRAM"], programShape),
                              itermSession: kept(iterm, sessionShape),
                              termSession: kept(env["TERM_SESSION_ID"], termSessionShape),
                              tty: kept(tty, ttyShape),
                              tmuxPane: kept(env["TMUX_PANE"], paneShape),
                              tmuxSocket: kept(socket, socketShape))
        return tab == TerminalTab() ? nil : tab
    }

    /// The controlling terminal of the agent that runs the hook,
    /// `/dev/ttys003`, or nil. A hook's own stdin, stdout and stderr are
    /// pipes and it has no controlling terminal of its own, but the agent
    /// that runs it does: so this walks up from the hook's process to the
    /// first ancestor with one (`sysctl`'s `e_tdev`), at most `levels` up.
    public static func controllingTTY(levels: Int = 8) -> String? {
        var pid = getpid()
        for _ in 0..<levels {
            guard let info = AgentProcess.info(pid) else { return nil }
            let dev = info.kp_eproc.e_tdev
            if dev != -1, let name = devname(dev, S_IFCHR) {
                let path = "/dev/" + String(cString: name)
                if valid(path, ttyShape) { return path }
            }
            pid = info.kp_eproc.e_ppid
            if pid <= 1 { return nil }
        }
        return nil
    }
}
