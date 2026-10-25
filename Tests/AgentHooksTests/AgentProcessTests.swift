import AgentHooks
import Darwin
import Foundation
import Testing
@testable import AgentHooksWire

/// The agent's own process, found above the hook, and whether it still
/// runs: against the tests' own process and its parents.
@Suite struct AgentProcessTests {
    /// The process `pid`, as `find` would name it.
    func process(_ pid: Int32) throws -> AgentProcess {
        let info = try #require(AgentProcess.info(pid))
        return AgentProcess(pid: pid, started: AgentProcess.startTime(info))
    }

    @Test func aRunningProcessRunsAndOneThatStartedAnotherTimeDoesnt() throws {
        let me = try process(getpid())
        #expect(AgentProcess.isRunning(me))
        #expect(!AgentProcess.isRunning(AgentProcess(pid: me.pid, started: me.started + 1)), "its pid, reused")
        #expect(!AgentProcess.isRunning(AgentProcess(pid: 99_999_999, started: me.started)), "no such process")
        #expect(me.started <= Int64(Date().timeIntervalSince1970 * 1000))
        #expect(me.started > 1_700_000_000_000, "milliseconds since 1970")
    }

    /// The first parent that isn't a shell or a launcher, else Claude's
    /// own pid when it's one of the parents.
    @Test func theAgentIsFoundAboveTheHook() throws {
        var expected: AgentProcess?
        var pid = getppid()
        var ancestors: [AgentProcess] = []
        for _ in 0..<8 where pid > 1 {
            let info = try #require(AgentProcess.info(pid))
            let p = try process(pid)
            ancestors.append(p)
            if expected == nil, !AgentProcess.launchers.contains(AgentProcess.name(info)) { expected = p }
            pid = info.kp_eproc.e_ppid
        }
        let found = AgentProcess.find(agent: "codex", env: [:])
        #expect(found == expected)
        if let found { #expect(AgentProcess.isRunning(found)) }
        #expect(AgentProcess.find(agent: "claude", env: ["CLAUDE_PID": "99999999"]) == expected, "not a parent: ignored")
        if let last = ancestors.last {
            #expect(AgentProcess.find(agent: "claude", env: ["CLAUDE_PID": "\(last.pid)"]) == last)
            #expect(AgentProcess.find(agent: "codex", env: ["CLAUDE_PID": "\(last.pid)"]) == expected, "Claude's alone")
        }
        #expect(AgentProcess.find(agent: "codex", env: [:], levels: 0) == nil)
    }

    /// Up a made-up tree: past the shells and the wrappers that run a
    /// command for someone, to the agent. Claude Code, as `node` or as
    /// its installer's version, is the agent, never a launcher;
    /// `CLAUDE_PID` wins when it's one of them.
    @Test func theAgentIsFoundPastShellsAndWrappers() {
        // Each pid's program and parent; each started at its pid.
        let tree: [Int32: (name: String, parent: Int32)] = [
            10: ("sh", 11), 11: ("timeout", 12), 12: ("caffeinate", 13), 13: ("node", 14), 14: ("nice", 15),
            15: ("zsh", 16), 16: ("login", 1),
            20: ("bash", 21), 21: ("sudo", 22), 22: ("nohup", 23), 23: ("script", 24), 24: ("env", 25),
            25: ("2.1.304", 26), 26: ("zsh", 1),
        ]
        func find(_ agent: String, from pid: Int32, env: [String: String] = [:], levels: Int = 8) -> Int32? {
            AgentProcess.find(agent: agent, env: env, from: pid, levels: levels) { pid in
                tree[pid].map { AgentProcess.Ancestor(name: $0.name, parent: $0.parent, started: Int64(pid)) }
            }?.pid
        }
        #expect(find("claude", from: 10) == 13, "node is Claude Code")
        #expect(find("codex", from: 20) == 25)
        #expect(find("claude", from: 10, env: ["CLAUDE_PID": "16"]) == 16, "CLAUDE_PID, a parent")
        #expect(find("claude", from: 10, env: ["CLAUDE_PID": "99"]) == 13, "not a parent: ignored")
        #expect(find("codex", from: 10, env: ["CLAUDE_PID": "16"]) == 13, "Claude's alone")
        #expect(find("codex", from: 99) == nil, "no such process")
        #expect(find("codex", from: 20, levels: 3) == nil, "past the levels")
        #expect(AgentProcess.launchers == ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh",
                                          "env", "nice", "nohup", "timeout", "caffeinate", "script", "sudo"])
        #expect(!AgentProcess.launchers.contains("node") && !AgentProcess.launchers.contains("claude"))
    }

    /// A process names its program while it runs, so a wrong one taken
    /// for the agent shows (`agent-hooks tail --sessions`).
    @Test func aRunningProcessNamesItsProgram() throws {
        let me = try process(getpid())
        let info = try #require(AgentProcess.info(getpid()))
        #expect(me.program() == AgentProcess.name(info))
        #expect(me.program()?.isEmpty == false)
        #expect(AgentProcess(pid: me.pid, started: me.started + 1).program() == nil, "its pid, reused")
        #expect(AgentProcess(pid: 99_999_999, started: me.started).program() == nil, "no such process")
    }

    /// It rides every line, to the event and its session.
    @Test func itRidesTheLineToTheSession() throws {
        let raw = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1"}"#.utf8)
        let agent = AgentProcess(pid: 4242, started: 1_791_707_031_722)
        let line = try #require(HookLine.extract(agent: "claude", payload: raw, ts: 1, process: agent))
        let wire = String(decoding: line.encoded(), as: UTF8.self)
        #expect(wire.contains(#""pid":4242"#) && wire.contains(#""pid_start":1791707031722"#))
        #expect(HookLine.decode(line.encoded()) == line)
        #expect(HookLine.decode(Data(#"{"agent":"claude","hook":"Stop","session":"s1","pid":-3,"pid_start":1}"#.utf8))?.process == nil)
        #expect(HookLine.decode(Data(#"{"agent":"claude","hook":"Stop","session":"s1","pid":3}"#.utf8))?.process == nil)
        let event = try #require(Mapping.event(from: line))
        #expect(event.process == agent)
        #expect(try JSONDecoder().decode(AgentEvent.self, from: Data(event.jsonLine.utf8)) == event)
        let tracker = SessionTracker()
        tracker.handle(event)
        #expect(tracker.sessions["claude/s1"]?.process == agent)
    }
}
