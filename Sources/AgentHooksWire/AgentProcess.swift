import Darwin

/// The agent's own process, which the hook client finds above itself, so
/// an app can tell an agent that's waiting on you from one that's gone
/// (its terminal closed, it crashed) without a `SessionEnd`. A pid can be
/// reused once its process ends, so the process's start time goes with it.
public struct AgentProcess: Equatable, Codable, Sendable {
    public var pid: Int32
    /// When the process started, in milliseconds since 1970.
    public var started: Int64

    public init(pid: Int32, started: Int64) {
        self.pid = pid
        self.started = started
    }

    /// What the process asks `sh -c` or `env` to run is never the agent.
    static let launchers: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "env"]

    /// The agent that runs this hook, walking up from the hook's parent at
    /// most `levels`: Claude's `CLAUDE_PID` when it's one of those, else
    /// the first that isn't a shell or a launcher. Nil when none is found.
    public static func find(agent: String, env: [String: String], levels: Int = 8) -> AgentProcess? {
        let claudePID = agent == "claude" ? env["CLAUDE_PID"].flatMap { Int32($0) }.flatMap { $0 > 1 ? $0 : nil } : nil
        var pid = getppid()
        var first: AgentProcess?
        for _ in 0..<levels where pid > 1 {
            guard let info = info(pid) else { break }
            let process = AgentProcess(pid: pid, started: startTime(info))
            if pid == claudePID { return process }
            if first == nil, !launchers.contains(name(info)) {
                first = process
                if claudePID == nil { break }
            }
            pid = info.kp_eproc.e_ppid
        }
        return first
    }

    /// Whether the process still runs: a process with its pid that started
    /// when it did, and isn't a zombie. When the system won't say, it
    /// counts as running, so nothing ends on a guess.
    @Sendable public static func isRunning(_ process: AgentProcess) -> Bool {
        let (answered, info) = ask(process.pid)
        guard answered else { return true }
        return info.map { $0.kp_proc.p_stat != SZOMB && startTime($0) == process.started } ?? false
    }

    /// A process's details from `sysctl`, or nil when there's none or the
    /// system won't say.
    static func info(_ pid: Int32) -> kinfo_proc? { ask(pid).info }

    /// Asks `sysctl` about `pid`: whether it answered, and the process's
    /// details, nil when there's no such process.
    static func ask(_ pid: Int32) -> (answered: Bool, info: kinfo_proc?) {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return (false, nil) }
        return (true, size > 0 ? info : nil)
    }

    /// When it started, in milliseconds since 1970.
    static func startTime(_ info: kinfo_proc) -> Int64 {
        let t = info.kp_proc.p_un.__p_starttime
        return Int64(t.tv_sec) * 1000 + Int64(t.tv_usec) / 1000
    }

    /// Its program's name (`p_comm`), without a login shell's leading `-`.
    static func name(_ info: kinfo_proc) -> String {
        var comm = info.kp_proc.p_comm
        let name = withUnsafeBytes(of: &comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return name.hasPrefix("-") ? String(name.dropFirst()) : name
    }
}
