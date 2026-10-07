import Darwin
import Foundation

/// A thread's name, as the agent's own app shows it, so the
/// apps name threads as you do. Only the name leaves this
/// type: the transcript it's read from is looked at in memory and dropped.
public enum ThreadName {
    /// Where Codex keeps names, in `session_index.jsonl`: `$CODEX_HOME`,
    /// or `~/.codex`. Claude keeps them in the session's transcript.
    public static var codexHome: String {
        ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    }

    /// Claude re-appends its title records every so often, so the name is
    /// almost always in the last few KB; a long turn can leave megabytes
    /// after it. The tail is read first, then a wider window.
    static let windows = [256 * 1024, 4 * 1024 * 1024]

    /// The name of the thread a hook payload is from, or nil. Without
    /// `wide`, only Claude's first window is read.
    public static func find(agent: String, json: [String: Any], session: String, codexHome: String,
                            wide: Bool = true) -> String? {
        switch agent {
        case "claude":
            return (json["transcript_path"] as? String).flatMap { claude(transcript: $0, wide: wide) }
        case "codex":
            return codex(thread: session, index: (codexHome as NSString).appendingPathComponent("session_index.jsonl"))
        default:
            return nil
        }
    }

    /// The last title in a Claude transcript: one you or the app gave it
    /// (`custom-title`) over the one Claude made up (`ai-title`).
    static func claude(transcript path: String, wide: Bool = true) -> String? {
        var aiTitle: String?
        for window in wide ? windows : [windows[0]] {
            guard let (data, whole) = tail(of: path, bytes: window) else { return nil }
            for line in lines(in: data, containing: "-title\"").reversed() {
                guard let object = object(line) else { continue }
                switch object["type"] as? String {
                case "custom-title":
                    if let title = clean(object["customTitle"]) { return title }
                case "ai-title":
                    if aiTitle == nil { aiTitle = clean(object["aiTitle"]) }
                default:
                    break
                }
            }
            if aiTitle != nil || whole { break }
        }
        return aiTitle
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
