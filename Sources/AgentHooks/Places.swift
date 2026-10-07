import Foundation

/// Where a session works: its project, and the workspace that tells two
/// threads in one project apart.
public struct Place: Equatable, Sendable {
    public var project: String
    public var workspace: String?
    public init(project: String, workspace: String? = nil) {
        self.project = project
        self.workspace = workspace
    }

    /// Where `cwd` works, from one look at its
    /// `.git`, or at the nearest one above it, so a subfolder is its
    /// repository's place. The project is the last folder, except that a
    /// git worktree maps to its main repository's name, so `landing` and
    /// `landing/.worktrees/fix-nav` both give `landing`. The workspace is a
    /// linked worktree's folder name, else the checked-out branch, else nil
    /// (the default branch, a detached head, or no git), cleaned by
    /// `cleanWorkspace`.
    public static func at(cwd: String, home: String = NSHomeDirectory()) -> Place {
        var path = cwd
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty, path != "/" else { return Place(project: "unknown") }

        // Common worktree folders, even when the folder itself isn't readable:
        // `<repo>/.worktrees/<name>` and `<repo>/.<tool>/worktrees/<name>`.
        let parts = path.split(separator: "/").map(String.init)
        let parent = parts.count >= 3 ? parts[parts.count - 2] : nil
        var project = parts.last ?? "unknown"
        if parent == ".worktrees" {
            project = parts[parts.count - 3]
        } else if parent == "worktrees", parts.count >= 4, parts[parts.count - 3].hasPrefix(".") {
            project = parts[parts.count - 4]
        }

        let git = (path as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: git, isDirectory: &isDirectory) else {
            // A common worktree folder that can't be read still names itself.
            let named = parent == ".worktrees" || parent == "worktrees"
            if !named, let repo = repository(above: path, home: home) { return at(cwd: repo, home: home) }
            return Place(project: project, workspace: named ? cleanWorkspace(parts[parts.count - 1]) : nil)
        }
        if !isDirectory.boolValue {
            // A linked worktree: `gitdir: <repo>/.git/worktrees/<name>`.
            guard let text = try? String(contentsOfFile: git, encoding: .utf8),
                  let range = text.range(of: "/.git/worktrees/") else { return Place(project: project) }
            let prefix = text[..<range.lowerBound]
            let repo = prefix.hasPrefix("gitdir:") ? prefix.dropFirst("gitdir:".count) : prefix
            let name = (repo.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
            return Place(project: name.isEmpty ? project : name,
                         workspace: cleanWorkspace(text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        let prefix = "ref: refs/heads/"
        guard let head = try? String(contentsOfFile: (git as NSString).appendingPathComponent("HEAD"), encoding: .utf8),
              head.hasPrefix(prefix)
        else { return Place(project: project) }
        let branch = head.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return Place(project: project, workspace: defaultBranches.contains(branch) ? nil : cleanWorkspace(branch))
    }

    /// Folders `repository(above:home:)` looks up.
    static let lookUp = 8

    /// The nearest folder above `path` with a `.git`, looking at most
    /// `lookUp` folders up and stopping at the home folder, so a dotfiles
    /// repo there doesn't name every folder outside git.
    static func repository(above path: String, home: String) -> String? {
        var folder = path
        for _ in 0..<lookUp {
            folder = (folder as NSString).deletingLastPathComponent
            if folder == "/" || folder == home || folder.isEmpty { return nil }
            if FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(".git")) { return folder }
        }
        return nil
    }

    static let defaultBranches: Set<String> = ["main", "master", "trunk", "develop"]

    /// An agent chooses its branch names, so a workspace is cleaned before
    /// anything sees it: a leading `word/` and a trailing hash (`-7a22ea`)
    /// go, it's lowercased, only `a-z`, `0-9` and `-` stay, and it's cut to
    /// 40 characters. Nothing left is nil.
    public static func cleanWorkspace(_ raw: String) -> String? {
        var name = raw.lowercased()
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if let range = name.range(of: "-[0-9a-f]{6,}$", options: .regularExpression) { name.removeSubrange(range) }
        name = String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        name = String(name.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return name.isEmpty ? nil : name
    }
}

/// Places by working directory, so a folder's `.git` is read at most
/// once every 30 s rather than on every hook, and a checkout's new
/// branch still shows. Touch it from one queue.
public final class Places {
    var places: [String: (place: Place, readAt: TimeInterval)] = [:]
    /// Folders remembered before the cache starts again.
    static let limit = 512
    /// Seconds a folder's place is kept before it's read again.
    static let keepFor: TimeInterval = 30
    let now: () -> TimeInterval

    public init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    public func place(cwd: String) -> Place {
        let now = now()
        if let kept = places[cwd], now - kept.readAt < Self.keepFor { return kept.place }
        if places[cwd] == nil, places.count >= Self.limit { places.removeAll() }
        let place = Place.at(cwd: cwd)
        places[cwd] = (place, now)
        return place
    }
}
