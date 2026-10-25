import Darwin
import Foundation

/// A thread's name, as the agent's own app shows it, so the
/// apps name threads as you do. Only the name leaves this
/// type: the files it's read from are looked at in memory and dropped.
/// Where each agent keeps names isn't documented, so each place is tried
/// in turn, and one that can't be read, or no longer has the shape it
/// had, just gives nothing; a thread with no name found has none.
public enum ThreadName {
    /// Where Codex keeps names, in `session_index.jsonl`: `$CODEX_HOME`,
    /// or `~/.codex`. Claude keeps them in a few places (`claude`).
    public static var codexHome: String {
        ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    }

    /// Claude re-appends its title records every so often, so the name is
    /// almost always in the last few KB; a long turn can leave megabytes
    /// after it. The tail is read first, then a wider window.
    static let windows = [256 * 1024, 4 * 1024 * 1024]

    /// The name of the thread a hook payload is from, or nil. Without
    /// `wide`, only Claude's first window of its transcript is read.
    /// `env` is the hook's environment, `pid` the agent's process
    /// (`AgentProcess`), and `home` where the Claude app and Claude Code
    /// keep their records.
    public static func find(agent: String, json: [String: Any], session: String, codexHome: String,
                            env: [String: String] = [:], pid: Int32? = nil, home: String = NSHomeDirectory(),
                            wide: Bool = true) -> String? {
        switch agent {
        case "claude":
            return claude(json: json, env: env, pid: pid, home: home, wide: wide)
        case "codex":
            return codex(thread: session, index: (codexHome as NSString).appendingPathComponent("session_index.jsonl"))
        default:
            return nil
        }
    }

    /// A Claude thread's name, the first of: the Claude app's, for a
    /// session it runs (`claudeApp`); one you gave it, which the hook
    /// says as `session_title` or the transcript keeps (`custom-title`);
    /// the one in Claude Code's record of the agent's process, which by
    /// Remote Control can be the remote session's (`claudeCode`); and
    /// the one Claude made up, in the transcript (`ai-title`).
    static func claude(json: [String: Any], env: [String: String], pid: Int32?, home: String, wide: Bool) -> String? {
        if let name = claudeApp(env: env, home: home) ?? clean(json["session_title"]) { return name }
        let transcript = (json["transcript_path"] as? String).flatMap { claude(transcript: $0, wide: wide) }
        return transcript?.yours ?? claudeCode(env: env, pid: pid, home: home) ?? transcript?.madeUp
    }

    /// The name the Claude app shows for a session it runs: `title` in its
    /// record of the session (`HostApp.appRecord`), where the ID is
    /// `CLAUDE_CODE_HOST_SESSION_ID`.
    static func claudeApp(env: [String: String], home: String) -> String? {
        guard let id = HookLine.string(env["CLAUDE_CODE_HOST_SESSION_ID"]),
              case .found(let record) = HostApp.appRecord(id, home: home) else { return nil }
        return clean(record["title"])
    }

    /// Where a name in Claude Code's record of a process came from
    /// (`nameSource`) that names the thread: given by you, by another
    /// session or by a hook, or made up, which by Remote Control is the
    /// remote session's title. Not one made from the folder (`derived`),
    /// nor a name with no source said.
    static let recordNameSources: Set<String> = ["user", "auto", "peer", "hook"]

    /// The name in Claude Code's record of the agent's process
    /// (`HostApp.record`), when it says where it came from and that names
    /// the thread.
    static func claudeCode(env: [String: String], pid: Int32?, home: String) -> String? {
        guard let record = HostApp.record(env: env, pid: pid, home: home),
              let source = record["nameSource"] as? String, recordNameSources.contains(source) else { return nil }
        return clean(record["name"])
    }

    /// The last titles in a Claude transcript: one you or the app gave it
    /// (`custom-title`), and the one Claude made up (`ai-title`).
    static func claude(transcript path: String, wide: Bool = true) -> (yours: String?, madeUp: String?)? {
        var aiTitle: String?
        for window in wide ? windows : [windows[0]] {
            guard let (data, whole) = tail(of: path, bytes: window) else { return nil }
            for line in lines(in: data, containing: "-title\"").reversed() {
                guard let object = object(line) else { continue }
                switch object["type"] as? String {
                case "custom-title":
                    if let title = clean(object["customTitle"]) { return (title, aiTitle) }
                case "ai-title":
                    if aiTitle == nil { aiTitle = clean(object["aiTitle"]) }
                default:
                    break
                }
            }
            if aiTitle != nil || whole { break }
        }
        return (nil, aiTitle)
    }

    /// The last name Codex's index gives the thread.
    static func codex(thread: String, index path: String) -> String? {
        guard let (data, _) = tail(of: path, bytes: windows[windows.count - 1]) else { return nil }
        for line in lines(in: data, containing: thread).reversed() {
            if let object = object(line), object["id"] as? String == thread, let name = clean(object["thread_name"]) {
                return name
            }
        }
        return nil
    }

    /// The last `bytes` of a file, and whether that was all of it.
    static func tail(of path: String, bytes: Int) -> (data: Data, whole: Bool)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        // Read the preceding byte too: a window beginning just after a
        // newline has a complete first line, which must not be discarded.
        guard (try? handle.seek(toOffset: start > 0 ? start - 1 : 0)) != nil,
              var data = try? handle.readToEnd() else { return nil }
        if start > 0 { data = data.firstIndex(of: 0x0A).map { data[($0 + 1)...] } ?? Data() }
        return (data, start == 0)
    }

    /// The lines of `data` that contain `needle`, in order. Only they are
    /// decoded: a transcript's other lines can be megabytes.
    static func lines(in data: Data, containing needle: String) -> [Data] {
        let pattern = Array(needle.utf8)
        var found: [Data] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, !pattern.isEmpty else { return }
            let bytes = raw.bindMemory(to: UInt8.self)
            var at = 0
            while at < raw.count, let hit = memmem(base + at, raw.count - at, pattern, pattern.count) {
                let offset = base.distance(to: hit)
                var lo = offset, hi = offset
                while lo > 0 && bytes[lo - 1] != 0x0A { lo -= 1 }
                while hi < raw.count && bytes[hi] != 0x0A { hi += 1 }
                found.append(Data(bytes[lo..<hi]))
                at = hi + 1
            }
        }
        return found
    }

    static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    /// One line of at most `HookLine.maxField` characters, or nil when blank.
    static func clean(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return HookLine.string(flat)
    }
}
