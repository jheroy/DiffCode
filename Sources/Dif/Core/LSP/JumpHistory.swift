import Foundation

/// A recorded position for IDE-style Back (`⌘[`) / Forward (`⌘]`) navigation.
struct JumpLocation: Equatable, Hashable, Sendable {
    var fileURL: URL
    var projectID: UUID?
    var relativePath: String?
    /// 1-based line number.
    var line: Int
    /// 0-based UTF-16 column offset.
    var column: Int
    var isExternal: Bool
}

/// Bounded Back/Forward navigation history stack for definition jumps.
struct JumpHistory: Equatable, Sendable {
    let maxEntries: Int
    private(set) var backStack: [JumpLocation] = []
    private(set) var forwardStack: [JumpLocation] = []

    init(maxEntries: Int = 100) {
        self.maxEntries = max(1, maxEntries)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Records the origin before executing a jump, clearing the forward stack.
    /// Deduplicates consecutive entries pointing to the same canonical file and line.
    mutating func push(_ location: JumpLocation) {
        let normalized = Self.canonicalize(location)
        forwardStack.removeAll()
        if let last = backStack.last, Self.isSameSpot(last, normalized) {
            backStack[backStack.count - 1] = normalized
            return
        }
        backStack.append(normalized)
        if backStack.count > maxEntries {
            backStack.removeFirst(backStack.count - maxEntries)
        }
    }

    /// Pops the previous location from the back stack and records `current` on the forward stack.
    mutating func back(from current: JumpLocation?) -> JumpLocation? {
        let normalizedCurrent = current.map(Self.canonicalize)
        while let target = backStack.popLast() {
            if let normalizedCurrent, Self.isSameSpot(target, normalizedCurrent) {
                continue
            }
            if let normalizedCurrent {
                appendDeduped(normalizedCurrent, to: &forwardStack)
            }
            return target
        }
        return nil
    }

    /// Pops the next location from the forward stack and records `current` on the back stack.
    mutating func forward(from current: JumpLocation?) -> JumpLocation? {
        let normalizedCurrent = current.map(Self.canonicalize)
        while let target = forwardStack.popLast() {
            if let normalizedCurrent, Self.isSameSpot(target, normalizedCurrent) {
                continue
            }
            if let normalizedCurrent {
                appendDeduped(normalizedCurrent, to: &backStack)
            }
            return target
        }
        return nil
    }

    mutating func clear() {
        backStack.removeAll()
        forwardStack.removeAll()
    }

    private func appendDeduped(_ location: JumpLocation, to stack: inout [JumpLocation]) {
        if let last = stack.last, Self.isSameSpot(last, location) {
            stack[stack.count - 1] = location
            return
        }
        stack.append(location)
        if stack.count > maxEntries {
            stack.removeFirst(stack.count - maxEntries)
        }
    }

    private static func canonicalize(_ location: JumpLocation) -> JumpLocation {
        var copy = location
        copy.fileURL = LSPURI.canonicalFileURL(location.fileURL)
        return copy
    }

    private static func isSameSpot(_ a: JumpLocation, _ b: JumpLocation) -> Bool {
        a.fileURL == b.fileURL && a.line == b.line
    }
}

/// How a resolved LSP definition location maps onto DiffCode's projects and viewer.
enum LSPNavigationTarget: Equatable, Sendable {
    /// Inside the currently selected project.
    case activeProject(projectID: UUID, relativePath: String, fileURL: URL, line: Int, column: Int)
    /// Inside another open project in `AppStore.projects` (e.g. a sibling `go.work` repository already added).
    case otherProject(projectID: UUID, relativePath: String, fileURL: URL, line: Int, column: Int)
    /// Outside all open projects: a sibling `go.work` repository not added to DiffCode, or an external file (`$GOROOT`, `pkg/mod`, …).
    case externalReadOnly(fileURL: URL, repoRoot: URL?, workspaceRoot: URL?, displayPath: String, line: Int, column: Int)
}

/// Pure resolver mapping LSP `textDocument/definition` responses to project or external read-only targets.
enum LSPTargetResolver {
    struct ProjectRef: Equatable, Sendable {
        var id: UUID
        var rootURL: URL
    }

    /// Picks the best definition location: prefers the first location whose canonical file or 0-based line
    /// differs from the clicked origin; falls back to the first valid file location.
    static func pickBestLocation(
        from locations: [LSPLocation],
        originFileURL: URL,
        originLine: Int
    ) -> LSPLocation? {
        let valid = locations.filter { $0.fileURL != nil }
        guard !valid.isEmpty else { return nil }
        let canonicalOrigin = LSPURI.canonicalFileURL(originFileURL)
        if let different = valid.first(where: { loc in
            guard let url = loc.fileURL else { return false }
            return LSPURI.canonicalFileURL(url) != canonicalOrigin || loc.range.start.line != originLine
        }) {
            return different
        }
        return valid.first
    }

    /// Resolves an `LSPLocation` into an active-project, other-project, or external read-only navigation target.
    static func resolve(
        location: LSPLocation,
        originFileURL: URL,
        originRepoRoot: URL?,
        activeProject: ProjectRef?,
        openProjects: [ProjectRef]
    ) -> LSPNavigationTarget? {
        guard let rawURL = location.fileURL else { return nil }
        let targetURL = LSPURI.canonicalFileURL(rawURL)
        let targetLine = max(1, location.range.start.line + 1)
        let targetCol = max(0, location.range.start.character)

        return resolve(
            fileURL: targetURL,
            line: targetLine,
            column: targetCol,
            originFileURL: originFileURL,
            originRepoRoot: originRepoRoot,
            activeProject: activeProject,
            openProjects: openProjects
        )
    }

    /// Resolves a canonical local file URL + 1-based line into a navigation target.
    static func resolve(
        fileURL: URL,
        line: Int,
        column: Int,
        originFileURL: URL?,
        originRepoRoot: URL?,
        activeProject: ProjectRef?,
        openProjects: [ProjectRef]
    ) -> LSPNavigationTarget {
        let targetURL = LSPURI.canonicalFileURL(fileURL)
        let targetLine = max(1, line)
        let targetCol = max(0, column)

        // Pick the most specific matching open project (deepest root path wins when nested).
        let matching = openProjects
            .filter { LSPURI.isPath(targetURL, inside: $0.rootURL) }
            .sorted { LSPURI.canonicalFileURL($0.rootURL).path.count > LSPURI.canonicalFileURL($1.rootURL).path.count }

        if let active = activeProject, LSPURI.isPath(targetURL, inside: active.rootURL) {
            // If a more specific nested open project owns the file, prefer it; otherwise keep active project.
            if let best = matching.first, best.id != active.id,
               LSPURI.canonicalFileURL(best.rootURL).path.count > LSPURI.canonicalFileURL(active.rootURL).path.count,
               let rel = relativePath(of: targetURL, inside: best.rootURL) {
                return .otherProject(projectID: best.id, relativePath: rel, fileURL: targetURL, line: targetLine, column: targetCol)
            }
            if let rel = relativePath(of: targetURL, inside: active.rootURL) {
                return .activeProject(projectID: active.id, relativePath: rel, fileURL: targetURL, line: targetLine, column: targetCol)
            }
        }

        if let other = matching.first, let rel = relativePath(of: targetURL, inside: other.rootURL) {
            return .otherProject(projectID: other.id, relativePath: rel, fileURL: targetURL, line: targetLine, column: targetCol)
        }

        // Case 3: External read-only file (sibling `go.work` repo not in `openProjects`, or stdlib / pkg cache).
        let goWork = originFileURL.flatMap { GoWorkspaceResolver.resolve(for: $0, repoRoot: originRepoRoot) }
            ?? GoWorkspaceResolver.resolve(for: targetURL, repoRoot: nil)
        let containingRepo: URL?
        if let originFileURL {
            containingRepo = GoWorkspaceResolver.containingRepoRoot(
                for: targetURL,
                relativeTo: originFileURL,
                repoRoot: originRepoRoot
            )
        } else {
            containingRepo = GoWorkspaceResolver.containingRepoRoot(
                for: targetURL,
                relativeTo: targetURL,
                repoRoot: nil
            )
        }
        // Keep the active go.work root or origin module workspace root when jumping into external files
        // ($GOROOT, ~/go/pkg/mod) so chained jumps reuse the already-running language server.
        let originWorkspaceRoot: URL? = originFileURL.map {
            GoWorkspaceResolver.workspaceRoot(for: $0, repoRoot: originRepoRoot)
        } ?? originRepoRoot.map { LSPURI.canonicalFileURL($0) }
        let workspaceRoot = goWork?.rootURL ?? originWorkspaceRoot ?? containingRepo
        let display = displayPath(for: targetURL, containingRepo: containingRepo)
        return .externalReadOnly(
            fileURL: targetURL,
            repoRoot: containingRepo,
            workspaceRoot: workspaceRoot,
            displayPath: display,
            line: targetLine,
            column: targetCol
        )
    }

    /// Computes the relative path of `child` inside `parent`, or `nil` if `child` is not strictly inside `parent`.
    static func relativePath(of child: URL, inside parent: URL) -> String? {
        let childPath = LSPURI.canonicalFileURL(child).path
        let parentPath = LSPURI.canonicalFileURL(parent).path
        let prefix = parentPath == "/" ? "/" : parentPath + "/"
        guard childPath.hasPrefix(prefix) else { return nil }
        let rel = String(childPath.dropFirst(prefix.count))
        return rel.isEmpty ? nil : rel
    }

    /// Formats a clear header label for an external file: `<repoName>/<relPath>` when inside a known repo/module,
    /// otherwise a `~`-shortened path.
    static func displayPath(for fileURL: URL, containingRepo: URL?) -> String {
        let canonical = LSPURI.canonicalFileURL(fileURL)
        if let repo = containingRepo, let rel = relativePath(of: canonical, inside: repo) {
            let repoName = LSPURI.canonicalFileURL(repo).lastPathComponent
            if !repoName.isEmpty {
                return "\(repoName)/\(rel)"
            }
        }
        return shortenedPath(canonical)
    }

    /// Replaces the user's home directory prefix with `~` for compact display.
    static func shortenedPath(_ fileURL: URL) -> String {
        let path = LSPURI.canonicalFileURL(fileURL).path
        let home = LSPURI.canonicalFileURL(URL(fileURLWithPath: Sandbox.realHome)).path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~/" + String(path.dropFirst(home.count + 1))
        }
        return path
    }
}
