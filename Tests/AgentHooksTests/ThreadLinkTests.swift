import AgentHooks
import Foundation
import Testing

/// Where a thread opens on the Mac.
@Suite struct ThreadLinkTests {
    func target(_ agent: String, _ session: String = "s1", app: String? = nil,
                appSession: String? = nil) -> ThreadLink.Target? {
        ThreadLink.target(ThreadRef(agent: agent, session: session, app: app, appSession: appSession))
    }

    @Test func testClaudeOpensInTheClaudeAppByItsOwnID() {
        #expect((target("claude", app: HostApp.claude, appSession: "local_7db526ef-3ac2")) == (.url("claude://code/continue?session=local_7db526ef-3ac2")))
        #expect((target("claude", app: HostApp.claude)) == .app(HostApp.claude), "no ID: the app, forward")
        #expect((target("claude", app: HostApp.claude, appSession: "local_x&q=1")) == .app(HostApp.claude), "an ID that isn't one isn't put in a link")
    }

    @Test func testCodexOpensInTheCodexAppByItsThreadID() {
        #expect((target("codex", "01a0e6fd-587d-74a2", app: HostApp.codex)) == (.url("codex://threads/01a0e6fd-587d-74a2")))
        #expect((target("codex", "01a0e6fd")) == (.url("codex://threads/01a0e6fd")), "no app named: Codex's own")
        #expect((target("codex", "a/b")) == (.url("codex://threads/a%2Fb")))
    }

    @Test func testATerminalIsBroughtForward() {
        #expect((target("claude", app: "com.mitchellh.ghostty")) == .app("com.mitchellh.ghostty"))
        #expect((target("codex", app: "com.googlecode.iterm2")) == .app("com.googlecode.iterm2"))
        #expect(ThreadLink.Target.app("com.mitchellh.ghostty").arguments == (["-b", "com.mitchellh.ghostty"]))
        #expect(target("claude") == nil, "nothing says where it runs")
    }
}

/// A terminal's own tab, when the hooks say where it is.
@Suite struct TerminalLinkTests {
    let uuid = TerminalTabTests.uuid

    func target(_ agent: String = "claude", app: String?, _ tab: TerminalTab?) -> ThreadLink.Target? {
        ThreadLink.target(ThreadRef(agent: agent, session: "s1", app: app, terminal: tab))
    }

    @Test func testTheTabIsChosenWhenItsAppCanOpenIt() {
        let iterm = TerminalTab(program: "iTerm.app", itermSession: uuid)
        #expect(target(app: ThreadLink.iterm, iterm) == .terminal(app: ThreadLink.iterm, tab: iterm))
        #expect(target("codex", app: ThreadLink.iterm, iterm) == .terminal(app: ThreadLink.iterm, tab: iterm))
        let byTTY = TerminalTab(tty: "/dev/ttys003")
        #expect(target(app: ThreadLink.iterm, byTTY) == .terminal(app: ThreadLink.iterm, tab: byTTY), "iTerm2 by tty too")
        #expect(target(app: ThreadLink.terminalApp, byTTY) == .terminal(app: ThreadLink.terminalApp, tab: byTTY))
        let tmux = TerminalTab(tmuxPane: "%3")
        #expect(target(app: "com.mitchellh.ghostty", tmux) == .terminal(app: "com.mitchellh.ghostty", tab: tmux),
                "tmux in any terminal")
        #expect(target(app: ThreadLink.terminalApp, TerminalTab(itermSession: uuid)) == .app(ThreadLink.terminalApp),
                "Terminal.app has no session ids")
        #expect(target(app: "com.mitchellh.ghostty", byTTY) == .app("com.mitchellh.ghostty"), "a terminal it can't script")
        #expect(target(app: nil, tmux) == nil, "no app to bring forward")
        #expect(target("codex", app: nil, tmux) == nil, "a terminal, so not the Codex app")
        #expect(target(app: ThreadLink.iterm, TerminalTab(itermSession: "x\" & y")) == .app(ThreadLink.iterm),
                "a value without its shape isn't scripted")
        #expect(ThreadLink.Target.terminal(app: ThreadLink.iterm, tab: iterm).arguments == ["-b", ThreadLink.iterm],
                "falls back to the app")
    }

    @Test func testITermsScriptSelectsTheSessionByItsUniqueID() throws {
        let script = try #require(ThreadLink.script(app: ThreadLink.iterm, TerminalTab(itermSession: uuid, tty: "/dev/ttys003")))
        #expect(script.contains(#"tell application id "com.googlecode.iterm2""#))
        #expect(script.contains(#"if unique id of s is "\#(uuid)" then"#))
        #expect(script.contains("tell s to select") && script.contains("activate") && script.contains("return false"))
        let byTTY = try #require(ThreadLink.script(app: ThreadLink.iterm, TerminalTab(tty: "/dev/ttys003")))
        #expect(byTTY.contains(#"if tty of s is "/dev/ttys003" then"#))
    }

    @Test func testTerminalAppsScriptFindsTheTabByItsTTY() throws {
        let script = try #require(ThreadLink.script(app: ThreadLink.terminalApp, TerminalTab(tty: "/dev/ttys003")))
        #expect(script.contains(#"tell application id "com.apple.Terminal""#))
        #expect(script.contains(#"if tty of t is "/dev/ttys003" then"#))
        #expect(script.contains("set selected of t to true") && script.contains("set index of w to 1"))
        #expect(ThreadLink.script(app: ThreadLink.terminalApp, TerminalTab(tty: "/dev/ttys0\" & x")) == nil)
        #expect(ThreadLink.script(app: "com.mitchellh.ghostty", TerminalTab(tty: "/dev/ttys003")) == nil)
    }

    @Test func testTmuxSelectsThePaneOnItsServer() {
        #expect(ThreadLink.tmuxCommands(TerminalTab(tmuxPane: "%3", tmuxSocket: "/private/tmp/tmux-501/default")) == [
            ["-S", "/private/tmp/tmux-501/default", "switch-client", "-t", "%3"],
            ["-S", "/private/tmp/tmux-501/default", "select-window", "-t", "%3"],
            ["-S", "/private/tmp/tmux-501/default", "select-pane", "-t", "%3"],
        ])
        #expect(ThreadLink.tmuxCommands(TerminalTab(tmuxPane: "%3", tmuxSocket: "rel")) == [
            ["switch-client", "-t", "%3"], ["select-window", "-t", "%3"], ["select-pane", "-t", "%3"],
        ], "a socket without its shape: the default server")
        #expect(ThreadLink.tmuxCommands(TerminalTab(tmuxPane: "%3;x")).isEmpty)
        #expect(ThreadLink.tmuxCommands(TerminalTab(tty: "/dev/ttys003")).isEmpty)
    }
}
