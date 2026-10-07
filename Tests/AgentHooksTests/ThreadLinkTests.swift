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
