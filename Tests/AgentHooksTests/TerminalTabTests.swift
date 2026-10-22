import AgentHooks
import Foundation
import Testing
@testable import AgentHooksWire

/// Where in a terminal an agent runs, from its hook's environment.
@Suite struct TerminalTabTests {
    static let uuid = "6A3E1F2C-0B7D-4C3A-9E1F-2B3C4D5E6F70"

    @Test func testITerm2sSessionIsThePartAfterTheColon() throws {
        let tab = try #require(TerminalTab.from(env: ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t1p0:\(Self.uuid)",
                                                      "TERM_SESSION_ID": "w0t1p0:\(Self.uuid)"], tty: "/dev/ttys004"))
        #expect(tab == TerminalTab(program: "iTerm.app", itermSession: Self.uuid, termSession: "w0t1p0:\(Self.uuid)",
                                   tty: "/dev/ttys004"))
    }

    @Test func testTerminalAppAndTmux() throws {
        let terminal = try #require(TerminalTab.from(env: ["TERM_PROGRAM": "Apple_Terminal", "TERM_SESSION_ID": Self.uuid],
                                                     tty: "/dev/ttys003"))
        #expect(terminal == TerminalTab(program: "Apple_Terminal", termSession: Self.uuid, tty: "/dev/ttys003"))
        let tmux = try #require(TerminalTab.from(env: ["TERM_PROGRAM": "tmux", "TMUX": "/private/tmp/tmux-501/default,123,0",
                                                       "TMUX_PANE": "%12"]))
        #expect(tmux == TerminalTab(program: "tmux", tmuxPane: "%12", tmuxSocket: "/private/tmp/tmux-501/default"))
    }

    /// A value without its shape is dropped, so nothing else can reach a
    /// script; with nothing left, it isn't a terminal.
    @Test func testOnlyValuesWithTheirShapeAreKept() {
        let env = ["ITERM_SESSION_ID": "w0:\" & do shell script \"x", "TMUX_PANE": "%1; rm", "TMUX": "rel/path,1,0",
                   "TERM_PROGRAM": "a\"b", "TERM_SESSION_ID": "x y"]
        #expect(TerminalTab.from(env: env, tty: "/dev/ttys1\"") == nil)
        #expect(TerminalTab.from(env: [:]) == nil)
        #expect(TerminalTab.from(env: ["HOME": "/Users/x", "PATH": "/bin"]) == nil, "only its own variables")
        #expect(!TerminalTab.valid("%a", TerminalTab.paneShape), "a pane is digits")
        #expect(!TerminalTab.valid("/dev/tty", TerminalTab.ttyShape))
        #expect(!TerminalTab.valid("/dev/ttys0000000000", TerminalTab.ttyShape))
    }

    /// The hook has no terminal of its own; the agent above it does. Under
    /// a test runner there may be none at all.
    @Test func testTheControllingTTYHasItsShapeOrIsNil() {
        let tty = TerminalTab.controllingTTY()
        #expect(tty == nil || TerminalTab.valid(tty, TerminalTab.ttyShape))
        #expect(TerminalTab.controllingTTY(levels: 0) == nil)
    }

    /// It rides the line to the event, the session and its thread.
    @Test func testItReachesTheSessionsThread() throws {
        let raw = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/w/landing"}"#.utf8)
        let line = try #require(HookLine.extract(agent: "claude", payload: raw, ts: 1,
                                                 env: ["__CFBundleIdentifier": "com.googlecode.iterm2",
                                                       "ITERM_SESSION_ID": "w0t0p0:\(Self.uuid)", "HOME": "/Users/secret"],
                                                 tty: "/dev/ttys009"))
        let wire = String(decoding: line.encoded(), as: UTF8.self)
        #expect(wire.contains(#""iterm_session":"\#(Self.uuid)""#))
        #expect(!wire.contains("secret"))
        #expect(HookLine.decode(line.encoded()) == line)
        let event = try #require(Mapping.event(from: line))
        #expect(event.terminal?.tty == "/dev/ttys009")
        #expect(try JSONDecoder().decode(AgentEvent.self, from: Data(event.jsonLine.utf8)) == event)
        let tracker = SessionTracker()
        _ = tracker.handle(event)
        let thread = try #require(tracker.sessions["claude/s1"]?.thread)
        #expect(thread.terminal == line.terminal)
        #expect(ThreadLink.target(thread) == .terminal(app: ThreadLink.iterm, tab: try #require(line.terminal)))
    }
}
