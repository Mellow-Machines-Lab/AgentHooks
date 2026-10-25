import AgentHooksWire

/// How long a session lasts when no `SessionEnd` comes, by where its
/// agent runs: whether its agent's process ending ends it, and whether
/// that process runs one thread at a time, so a newer one starting in it
/// ends this one. An agent added to `Agent` gets its own case here.
public struct Lifetime: Equatable, Sendable {
    /// The session lasts only as long as its agent's process.
    public let endsWithProcess: Bool
    /// Its agent's process runs one thread at a time.
    public let oneThreadPerProcess: Bool

    public init(endsWithProcess: Bool, oneThreadPerProcess: Bool) {
        self.endsWithProcess = endsWithProcess
        self.oneThreadPerProcess = oneThreadPerProcess
    }

    /// A session's, from what its events said of where it runs.
    public static func of(_ thread: ThreadRef) -> Lifetime {
        switch Agent(rawValue: thread.agent) {
        case .claude?:
            // The Claude app keeps a thread whose process ended, and starts
            // it again when you open it: its record says when it's gone
            // (`ThreadArchive`). Claude Code anywhere else, in a terminal or
            // by Remote Control, is one process to a thread at a time, and
            // the thread is over when it ends.
            let inApp = thread.appSession.map(HostApp.isAppSession) == true
            return Lifetime(endsWithProcess: !inApp, oneThreadPerProcess: !inApp)
        case .codex?:
            // The Codex app's one server runs every thread, the CLI one at
            // a time. With no app or terminal named, it's the app's, as
            // `ThreadLink` has it.
            let inApp = thread.app == HostApp.codex || (thread.app == nil && thread.terminal == nil)
            return Lifetime(endsWithProcess: true, oneThreadPerProcess: !inApp)
        case nil:
            return Lifetime(endsWithProcess: false, oneThreadPerProcess: false)
        }
    }
}
