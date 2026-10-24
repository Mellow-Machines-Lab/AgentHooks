import Foundation

/// How big an edit was: lines added and lines removed, worked out from
/// the tool's input or result in memory. Only the two counts leave this
/// function; the text they're counted from never does.
public enum EditSize {
    /// Lines added and removed by an edit tool's call, or nil for a tool
    /// that isn't one or a payload that doesn't say.
    ///
    /// - Claude's `Edit`, `MultiEdit` and `Write`: the result's
    ///   `structuredPatch` when there is one (a `PostToolUse`), each hunk's
    ///   `+` and `-` lines, which counts `replace_all` and a `Write` over an
    ///   existing file exactly. Otherwise the input: an edit's
    ///   `old_string` and `new_string`, less the lines they share at either
    ///   end, and a `Write`'s `content`, all added.
    /// - Codex's `apply_patch`: its patch's `+` and `-` lines.
    public static func of(tool: String?, input: Any?, response: Any? = nil) -> (added: Int, removed: Int)? {
        switch tool {
        case "Edit", "MultiEdit", "Write":
            if let counts = structuredPatch(response) { return counts }
            guard let input = input as? [String: Any] else { return nil }
            if tool == "Write" {
                guard let content = input["content"] as? String else { return nil }
                return (lines(content).count, 0)
            }
            let edits = tool == "MultiEdit" ? (input["edits"] as? [[String: Any]] ?? []) : [input]
            var total: (added: Int, removed: Int)?
            for edit in edits {
                guard let old = edit["old_string"] as? String, let new = edit["new_string"] as? String else { continue }
                let counts = replaced(old, new)
                total = ((total?.added ?? 0) + counts.added, (total?.removed ?? 0) + counts.removed)
            }
            return total
        case "apply_patch":
            return patch(input).map(patchCounts)
        default:
            return nil
        }
    }

    /// The lines of `text`, a final newline ending the last rather than
    /// starting another.
    static func lines(_ text: String) -> [Substring] {
        if text.isEmpty { return [] }
        var all = text.split(separator: "\n", omittingEmptySubsequences: false)
        if text.hasSuffix("\n") { all.removeLast() }
        return all
    }

    /// `old` replaced by `new`, less the lines both start and end with.
    static func replaced(_ old: String, _ new: String) -> (added: Int, removed: Int) {
        let a = lines(old), b = lines(new)
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start] { start += 1 }
        var end = 0
        while end < a.count - start, end < b.count - start, a[a.count - 1 - end] == b[b.count - 1 - end] { end += 1 }
        return (b.count - start - end, a.count - start - end)
    }

    /// Claude's result's hunks: `[{"lines": ["-old", "+new", " same"]}]`.
    static func structuredPatch(_ response: Any?) -> (added: Int, removed: Int)? {
        guard let hunks = (response as? [String: Any])?["structuredPatch"] as? [[String: Any]] else { return nil }
        var added = 0, removed = 0
        for hunk in hunks {
            for line in hunk["lines"] as? [String] ?? [] {
                if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
            }
        }
        return (added, removed)
    }

    /// An `apply_patch` body: the input itself, or under `input`, `patch`
    /// or `command` (a string, or the last of an argv).
    static func patch(_ input: Any?) -> String? {
        if let text = input as? String { return text }
        guard let object = input as? [String: Any] else { return nil }
        for key in ["input", "patch", "command"] {
            if let text = object[key] as? String { return text }
            if let argv = object[key] as? [String], let last = argv.last, last.contains("*** Begin Patch") { return last }
        }
        return nil
    }

    /// A patch's `+` and `-` lines, inside its `*** ` file sections. An
    /// added file's lines are all `+`; a deleted file names no lines.
    static func patchCounts(_ patch: String) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("***") { continue }
            if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
        }
        return (added, removed)
    }
}
