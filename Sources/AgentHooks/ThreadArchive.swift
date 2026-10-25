import AgentHooksWire
import Foundation

/// Whether a thread was archived in its agent's app, from the app's own
/// records, so a session archived there, which sends no `SessionEnd`,
/// ends here too. Neither app documents its records, so one that can't
/// be read, or has lost its shape, says the thread is open: none is
/// taken for archived on a guess. Only that one fact is kept.
public enum ThreadArchive {
    public enum State: Equatable, Sendable {
        /// Kept in its app, or nothing says otherwise.
        case open
        /// Archived in its app.
        case archived
        /// Its app keeps no record of it: deleted there. Only the Claude
        /// app's own threads say so.
        case missing
    }

    /// Where `thread` stands in its app: the Claude app's record of a
    /// session it runs (`isArchived`); Codex's folder of archived threads.
    /// A Claude Code session anywhere else (a terminal, Remote Control) has
    /// no record, and is open: by Remote Control, archiving it on
    /// claude.ai ends its process. `home` is where the Claude app keeps
    /// its records, and `codexHome` Codex's (`ThreadName.codexHome`).
    public static func state(_ thread: ThreadRef, home: String = NSHomeDirectory(),
                             codexHome: String = ThreadName.codexHome) -> State {
        switch thread.agent {
        case "claude":
            guard let id = thread.appSession, HostApp.isAppSession(id) else { return .open }
            switch HostApp.appRecord(id, home: home) {
            case .found(let record): return record["isArchived"] as? Bool == true ? .archived : .open
            case .none: return .missing
            case .unreadable: return .open
            }
        case "codex":
            return codexArchived(thread.session, codexHome: codexHome) ? .archived : .open
        default:
            return .open
        }
    }

    /// Whether Codex archived the thread: it moves an archived thread's
    /// rollout into `archived_sessions/` in its home, named for the thread
    /// (`rollout-<date>-<thread>.jsonl`, compressed `.jsonl.zst`), and
    /// back when you unarchive it.
    static func codexArchived(_ thread: String, codexHome: String) -> Bool {
        guard !thread.isEmpty, !thread.contains("/"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: codexHome + "/archived_sessions")
        else { return false }
        let tail = "-" + thread + ".jsonl"
        return names.contains { $0.hasPrefix("rollout-") && ($0.hasSuffix(tail) || $0.hasSuffix(tail + ".zst")) }
    }
}
