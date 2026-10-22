import AgentHooksWire
import Foundation

/// Where a thread opens on the Mac: the thread itself
/// in the Claude or Codex app, its tab in a terminal that can be scripted
/// (iTerm2, Terminal.app, or a tmux pane in any terminal), else the app the
/// agent runs in brought to the front.
public enum ThreadLink {
    public static let iterm = "com.googlecode.iterm2"
    public static let terminalApp = "com.apple.Terminal"

    public enum Target: Equatable, Sendable {
        /// A link its app opens the thread at.
        case url(String)
        /// An app to bring forward, by bundle ID.
        case app(String)
        /// A tab in a terminal app, by bundle ID, which `steps` open.
        case terminal(app: String, tab: TerminalTab)

        /// What `open` is given: for a terminal, its app, brought forward
        /// when the tab can't be opened.
        public var arguments: [String] {
            switch self {
            case .url(let url): [url]
            case .app(let id), .terminal(let id, _): ["-b", id]
            }
        }
    }

    /// The target for `thread`, or nil when nothing says where it runs.
    public static func target(_ thread: ThreadRef) -> Target? {
        switch thread.agent {
        case "claude":
            // The Claude app opens a session by its own ID, which the hook
            // got from the app, not by Claude Code's.
            if let id = thread.appSession, id.range(of: #"^local_[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil {
                return .url("claude://code/continue?session=\(id)")
            }
        case "codex":
            // The Codex app opens a thread by its ID, which is the hook's
            // session. With no app or terminal named, it's the Codex app's:
            // a terminal would have named itself.
            if thread.app == HostApp.codex || (thread.app == nil && thread.terminal == nil),
               let id = thread.session.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(["-", "_"])) {
                return .url("codex://threads/\(id)")
            }
        default:
            break
        }
        guard let app = thread.app else { return nil }
        if let tab = thread.terminal, opensTab(app: app, tab) { return .terminal(app: app, tab: tab) }
        return .app(app)
    }

    /// Whether `tab` in `app` can be opened: a tmux pane anywhere, an iTerm2
    /// session by its id or its tty, or a Terminal.app tab by its tty.
    static func opensTab(app: String, _ tab: TerminalTab) -> Bool {
        if TerminalTab.valid(tab.tmuxPane, TerminalTab.paneShape) { return true }
        return script(app: app, tab) != nil
    }

    /// The AppleScript that selects `tab` in `app` and brings it forward,
    /// printing `true`, or `false` when no tab matches; nil for an app it
    /// can't script or a tab without an id it has. The id is checked
    /// against its shape before it's put in the script, so it can only be
    /// a quoted UUID or tty path.
    public static func script(app: String, _ tab: TerminalTab) -> String? {
        switch app {
        case iterm:
            let match: String
            if TerminalTab.valid(tab.itermSession, TerminalTab.sessionShape), let id = tab.itermSession {
                match = "unique id of s is \"\(id)\""
            } else if TerminalTab.valid(tab.tty, TerminalTab.ttyShape), let tty = tab.tty {
                match = "tty of s is \"\(tty)\""
            } else {
                return nil
            }
            return """
            tell application id "\(iterm)"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if \(match) then
                                select w
                                tell t to select
                                tell s to select
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
        case terminalApp:
            guard TerminalTab.valid(tab.tty, TerminalTab.ttyShape), let tty = tab.tty else { return nil }
            return """
            tell application id "\(terminalApp)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        default:
            return nil
        }
    }

    /// tmux's commands that show `tab`'s pane: its client switched to the
    /// pane's session, then its window and the pane selected, each as
    /// tmux's arguments; empty without a pane. The pane and socket are
    /// checked against their shapes, and passed as arguments, never through
    /// a shell.
    public static func tmuxCommands(_ tab: TerminalTab) -> [[String]] {
        guard TerminalTab.valid(tab.tmuxPane, TerminalTab.paneShape), let pane = tab.tmuxPane else { return [] }
        let socket = TerminalTab.valid(tab.tmuxSocket, TerminalTab.socketShape) ? tab.tmuxSocket.map { ["-S", $0] } ?? [] : []
        return [["switch-client", "-t", pane], ["select-window", "-t", pane], ["select-pane", "-t", pane]]
            .map { socket + $0 }
    }

    /// Where tmux is: an app started from the Finder doesn't have your
    /// shell's `PATH`.
    static let tmuxPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux", "/usr/bin/tmux"]

    /// Opens `target`. A link or an app goes to `/usr/bin/open`, which
    /// starts the app if it isn't running, and isn't waited on. A terminal
    /// tab is opened in the background. In tmux, its pane is selected and
    /// the app brought forward: a tmux pane's tty and inherited session
    /// ids aren't the outer tab's, so the outer tab isn't looked for.
    /// Otherwise the script runs with `osascript`, and when that fails or
    /// doesn't find the tab, the app is brought forward as for `.app`. The
    /// first time an app scripts iTerm2 or Terminal.app, macOS asks you to
    /// allow it (Automation). Returns whether it started.
    @Sendable public static func openOnMac(_ target: Target) -> Bool {
        guard case .terminal(let app, let tab) = target else { return run("/usr/bin/open", target.arguments) }
        DispatchQueue.global(qos: .userInitiated).async {
            let tmux = tmuxCommands(tab)
            var opened = false
            if !tmux.isEmpty {
                if let path = tmuxPaths.first(where: FileManager.default.isExecutableFile) {
                    for arguments in tmux { _ = run(path, arguments, waitUpTo: 5) }
                }
            } else if let script = script(app: app, tab) {
                opened = output(of: "/usr/bin/osascript", ["-e", script], waitUpTo: 60) == "true"
            }
            if !opened { _ = run("/usr/bin/open", target.arguments) }
        }
        return true
    }

    /// Runs `path`, its output thrown away, and returns whether it started.
    /// With `waitUpTo`, waits for it that many seconds at most (an
    /// Automation prompt can sit unanswered), then stops it.
    @discardableResult
    static func run(_ path: String, _ arguments: [String], waitUpTo seconds: Double? = nil) -> Bool {
        output(of: path, arguments, waitUpTo: seconds, keep: false) != nil
    }

    /// What `path` printed, trimmed; nil when it didn't start, or when
    /// waited on, failed or ran out of time.
    static func output(of path: String, _ arguments: [String], waitUpTo seconds: Double?, keep: Bool = true) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = keep ? pipe : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        guard let seconds else { return "" }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
        let data = keep ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        timer.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One agent thread, as much as opening it on the Mac needs
/// (`ThreadLink`): the agent's session ID, the app it runs in, that
/// app's own ID for it, and its tab in a terminal.
public struct ThreadRef: Equatable, Sendable {
    /// `claude` or `codex`.
    public var agent: String
    public var session: String
    /// The app's bundle ID (`HostApp`), when the hooks said.
    public var app: String?
    /// The Claude app's `local_…` ID.
    public var appSession: String?
    /// Where in a terminal it runs (`TerminalTab`), when the hooks said.
    public var terminal: TerminalTab?

    public init(agent: String, session: String, app: String? = nil, appSession: String? = nil,
                terminal: TerminalTab? = nil) {
        self.agent = agent
        self.session = session
        self.app = app
        self.appSession = appSession
        self.terminal = terminal
    }
}
