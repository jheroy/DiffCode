import XCTest
@testable import DifKit

final class LogTabsTests: XCTestCase {
    private var root: URL!
    private var storageDir: URL!
    private let fm = FileManager.default

    private let alice = AuthorFilter(name: "Alice", email: "alice@example.com")
    private let bob = AuthorFilter(name: "Bob", email: "bob@example.com")

    override func setUp() async throws {
        let suffix = UUID().uuidString
        root = fm.temporaryDirectory.appendingPathComponent("dif-log-tabs-\(suffix)")
        storageDir = fm.temporaryDirectory.appendingPathComponent("dif-log-tabs-storage-\(suffix)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: storageDir, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")

        // c1 (Alice): app.swift, notes.txt
        try write("app.swift", "let v = 1\nlet keep = true\nlet tail = 1\n")
        try write("notes.txt", "n1\n")
        try git("add", "-A")
        try commit(by: alice, message: "c1 alice init", date: "2026-01-01T10:00:00Z")

        // c2 (Bob): notes.txt
        try write("notes.txt", "n1\nn2\n")
        try git("add", "-A")
        try commit(by: bob, message: "c2 bob notes", date: "2026-01-02T10:00:00Z")

        // c3 (Alice): app.swift line 1, extra.swift
        try write("app.swift", "let v = 2\nlet keep = true\nlet tail = 1\n")
        try write("extra.swift", "let extra = 1\n")
        try git("add", "-A")
        try commit(by: alice, message: "c3 alice update v and extra", date: "2026-01-03T10:00:00Z")

        // c4 (Bob): app.swift line 3
        try write("app.swift", "let v = 2\nlet keep = true\nlet tail = 2\n")
        try git("add", "-A")
        try commit(by: bob, message: "c4 bob update tail", date: "2026-01-04T10:00:00Z")

        // c5 (Alice): app.swift line 1, extra.swift
        try write("app.swift", "let v = 3\nlet keep = true\nlet tail = 2\n")
        try write("extra.swift", "let extra = 2\n")
        try git("add", "-A")
        try commit(by: alice, message: "c5 alice bump v", date: "2026-01-05T10:00:00Z")
    }

    override func tearDown() async throws {
        if let root { try? fm.removeItem(at: root) }
        if let storageDir { try? fm.removeItem(at: storageDir) }
    }

    // MARK: - Tests

    @MainActor
    func testShowHistoryOpensNewTabPreservingAuthorFilterAndMultiCommitSelection() async throws {
        try await withIsolatedStore { store, _ in
            let project = Project(url: root)
            project.tab = .log
            store.projects = [project]
            store.selectedProjectID = project.id

            // Filter by Alice -> [c5, c3, c1]
            project.toggleLogAuthor(alice)
            try await waitUntil { !project.isLoadingLog && project.commits.count == 3 }
            let aliceCommits = project.commits
            let c5 = aliceCommits[0]
            let c1 = aliceCommits[2]

            // Select non-contiguous pair [c5, c1] and pick extra.swift
            project.setCommitSelection(primary: c1.id, ids: [c5.id, c1.id])
            await loadSelectedCommitAndSync(project, store: store)
            XCTAssertTrue(project.commitSelectionIsNonContiguous)
            project.selectedCommitFileID = ChangeRow.fileID("extra.swift")
            store.commitFileSelectionChanged(project)
            let originalRequest = store.viewer.request
            XCTAssertEqual(originalRequest?.path, "extra.swift")

            let tab1ID = project.activeLogTabID
            XCTAssertEqual(project.logTabs.count, 1)

            // Simulate user pressing ⌘B -> Open in Log for line 3 of app.swift (changed in c4 by Bob)
            let allCommits = try await Git.log(in: root, skip: 0, limit: 20, query: "", allBranches: false)
            let c4 = try XCTUnwrap(allCommits.first { $0.subject.hasPrefix("c4 ") })
            let lineFilter = HistoryFilter(path: "app.swift", lines: 3...3, rev: "HEAD")
            store.showHistory(lineFilter, in: project, select: c4.hash)

            try await waitUntil {
                !project.isLoadingLog && !project.isLoadingCommit && project.history == lineFilter && project.selectedCommitID == c4.hash
            }

            XCTAssertEqual(project.logTabs.count, 2)
            let tab2ID = project.activeLogTabID
            XCTAssertNotEqual(tab2ID, tab1ID)
            XCTAssertEqual(project.history, lineFilter)
            XCTAssertTrue(project.logAuthors.isEmpty)
            XCTAssertEqual(project.selectedCommitID, c4.hash)
            XCTAssertEqual(store.viewer.request?.path, "app.swift")

            // Switch back to Tab 1: author filter, non-contiguous multi-commit selection, file & diff must all be intact!
            store.selectLogTab(tab1ID, in: project)
            XCTAssertEqual(project.activeLogTabID, tab1ID)
            XCTAssertNil(project.history)
            XCTAssertEqual(project.logAuthors, [alice])
            XCTAssertEqual(project.selectedCommitIDs, [c5.id, c1.id])
            XCTAssertEqual(project.selectedCommitID, c1.id)
            XCTAssertTrue(project.commitSelectionIsNonContiguous)
            XCTAssertEqual(project.selectedCommitFileID, ChangeRow.fileID("extra.swift"))
            XCTAssertEqual(store.viewer.request, originalRequest)

            // Switch back to Tab 2 instantaneously
            store.selectLogTab(tab2ID, in: project)
            XCTAssertEqual(project.activeLogTabID, tab2ID)
            XCTAssertEqual(project.history, lineFilter)
            XCTAssertEqual(project.selectedCommitID, c4.hash)
            XCTAssertEqual(store.viewer.request?.path, "app.swift")
        }
    }

    @MainActor
    func testShowHistoryReusesExistingTabForSameFilterAndCreatesThirdForDifferentFilter() async throws {
        try await withIsolatedStore { store, _ in
            let allCommits = try await Git.log(in: root, skip: 0, limit: 20, query: "", allBranches: false)
            let c4 = try XCTUnwrap(allCommits.first { $0.subject.hasPrefix("c4 ") })
            let c1 = try XCTUnwrap(allCommits.first { $0.subject.hasPrefix("c1 ") })

            let project = Project(url: root)
            project.tab = .log
            store.projects = [project]
            store.selectedProjectID = project.id
            store.loadActiveLogTab(for: project)
            try await waitUntil { !project.isLoadingLog && project.commits.count == 5 }

            let filter1 = HistoryFilter(path: "app.swift", lines: 3...3, rev: "HEAD")
            store.showHistory(filter1, in: project, select: c4.hash)
            try await waitUntil { !project.isLoadingLog && !project.isLoadingCommit && project.selectedCommitID == c4.hash }
            XCTAssertEqual(project.logTabs.count, 2)
            let tab2ID = project.activeLogTabID

            // Same filter with a different commit reuses Tab 2 instead of creating a duplicate
            store.showHistory(filter1, in: project, select: c1.hash)
            try await waitUntil { !project.isLoadingLog && !project.isLoadingCommit && project.selectedCommitID == c1.hash }
            XCTAssertEqual(project.logTabs.count, 2)
            XCTAssertEqual(project.activeLogTabID, tab2ID)

            // Different line range opens a third tab
            let filter2 = HistoryFilter(path: "app.swift", lines: 1...1, rev: "HEAD")
            store.showHistory(filter2, in: project)
            try await waitUntil { !project.isLoadingLog && !project.isLoadingCommit && project.history == filter2 }
            XCTAssertEqual(project.logTabs.count, 3)
            XCTAssertNotEqual(project.activeLogTabID, tab2ID)
        }
    }

    @MainActor
    func testManualTabDeletionCloseMRUAndResetLastTab() async throws {
        try await withIsolatedStore { store, _ in
            let project = Project(url: root)
            project.tab = .log
            store.projects = [project]
            store.selectedProjectID = project.id
            store.loadActiveLogTab(for: project)
            try await waitUntil { !project.isLoadingLog && !project.isLoadingCommit && project.commits.count == 5 }

            let tab1ID = project.activeLogTabID
            let f1 = HistoryFilter(path: "app.swift", lines: 1...1, rev: "HEAD")
            let f2 = HistoryFilter(path: "notes.txt", lines: nil, rev: "HEAD")

            store.showHistory(f1, in: project)
            try await waitUntil { !project.isLoadingLog && project.history == f1 }
            let tab2ID = project.activeLogTabID

            store.showHistory(f2, in: project)
            try await waitUntil { !project.isLoadingLog && project.history == f2 }
            let tab3ID = project.activeLogTabID
            XCTAssertEqual(project.logTabs.count, 3)

            // Close inactive tab2: active tab3 remains active
            store.closeLogTab(tab2ID, in: project)
            XCTAssertEqual(project.logTabs.map(\.id), [tab1ID, tab3ID])
            XCTAssertEqual(project.activeLogTabID, tab3ID)

            // Close active tab3: returns to MRU tab1
            store.closeLogTab(tab3ID, in: project)
            XCTAssertEqual(project.logTabs.map(\.id), [tab1ID])
            XCTAssertEqual(project.activeLogTabID, tab1ID)
            XCTAssertNil(project.history)

            // Open two more history tabs, then close all history tabs at once
            store.showHistory(f1, in: project)
            try await waitUntil { !project.isLoadingLog && project.history == f1 }
            store.showHistory(f2, in: project)
            try await waitUntil { !project.isLoadingLog && project.history == f2 }
            XCTAssertEqual(project.logTabs.count, 3)

            store.closeHistoryLogTabs(in: project)
            XCTAssertEqual(project.logTabs.count, 1)
            XCTAssertEqual(project.activeLogTabID, tab1ID)
            XCTAssertNil(project.history)

            // Customize sole remaining tab, then close/reset it
            project.toggleLogAuthor(bob)
            try await waitUntil { !project.isLoadingLog && project.commits.count == 2 }
            store.closeLogTab(tab1ID, in: project)
            try await waitUntil { !project.isLoadingLog && project.commits.count == 5 }
            XCTAssertEqual(project.logTabs.count, 1)
            XCTAssertTrue(project.logAuthors.isEmpty)
            XCTAssertNil(project.history)

            // Close other tabs
            store.showHistory(f1, in: project)
            try await waitUntil { !project.isLoadingLog && project.history == f1 }
            let keepID = project.activeLogTabID
            store.closeOtherLogTabs(keeping: keepID, in: project)
            XCTAssertEqual(project.logTabs.map(\.id), [keepID])
            XCTAssertEqual(project.activeLogTabID, keepID)
        }
    }

    func testLogStateStorageSaveReloadSymlinkAndCorruptionResilience() throws {
        let storageFile = storageDir.appendingPathComponent("nested/log-state.json")
        let realRepo = storageDir.appendingPathComponent("real-repo")
        try fm.createDirectory(at: realRepo, withIntermediateDirectories: true)
        let linkRepo = storageDir.appendingPathComponent("link-repo")
        try fm.createSymbolicLink(at: linkRepo, withDestinationURL: realRepo)

        let tab1 = PersistedLogTab(
            id: UUID(),
            history: nil,
            logQuery: "bump",
            logAuthors: [alice, bob],
            logAllBranches: true,
            logRef: nil,
            selectedCommitID: String(repeating: "a", count: 40),
            selectedCommitIDs: [String(repeating: "a", count: 40), String(repeating: "b", count: 40)],
            selectedCommitFileID: "f:app.swift",
            commitCollapsed: ["d:c:Sources"]
        )
        let tab2 = PersistedLogTab(
            id: UUID(),
            history: HistoryFilter(path: "app.swift", lines: 2...5, rev: "HEAD"),
            logQuery: "",
            logAuthors: [],
            logAllBranches: false,
            logRef: nil,
            selectedCommitID: String(repeating: "c", count: 40),
            selectedCommitIDs: [String(repeating: "c", count: 40)],
            selectedCommitFileID: "f:app.swift",
            commitCollapsed: []
        )
        let state = PersistedLogState(activeProjectTab: "log", activeTabID: tab1.id, tabs: [tab1, tab2])

        let writer = LogStateStorage(fileURL: storageFile)
        writer.save(state, for: realRepo)
        XCTAssertTrue(fm.fileExists(atPath: storageFile.path))

        let reader = LogStateStorage(fileURL: storageFile)
        XCTAssertEqual(reader.load(for: linkRepo), state)
        XCTAssertEqual(reader.allKeys().count, 1)

        // Saving empty tabs removes record and file
        reader.save(PersistedLogState(activeProjectTab: "log", activeTabID: nil, tabs: []), for: realRepo)
        XCTAssertNil(reader.load(for: realRepo))
        XCTAssertFalse(fm.fileExists(atPath: storageFile.path))

        // Corrupted JSON falls back cleanly
        try fm.createDirectory(at: storageFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not-valid-json".utf8).write(to: storageFile)
        let corrupted = LogStateStorage(fileURL: storageFile)
        XCTAssertNil(corrupted.load(for: realRepo))
        XCTAssertTrue(corrupted.allKeys().isEmpty)
    }

    @MainActor
    func testRestartRestoresTabsAuthorFiltersNonContiguousSelectionAndViewerFile() async throws {
        let storageFile = storageDir.appendingPathComponent("restart-log-state.json")
        try await withIsolatedStore(storageFile: storageFile) { store, _ in
            // Session 1: configure Tab 1 (Alice filter + non-contiguous [c5, c1] + extra.swift) and Tab 2 (line history at c4)
            let project1 = Project(url: root)
            project1.tab = .log
            store.projects = [project1]
            store.selectedProjectID = project1.id

            project1.toggleLogAuthor(alice)
            try await waitUntil { !project1.isLoadingLog && project1.commits.count == 3 }
            let c5 = project1.commits[0]
            let c1 = project1.commits[2]
            project1.setCommitSelection(primary: c1.id, ids: [c5.id, c1.id])
            await loadSelectedCommitAndSync(project1, store: store)
            project1.selectedCommitFileID = ChangeRow.fileID("extra.swift")
            store.commitFileSelectionChanged(project1)

            let tab1ID = project1.activeLogTabID
            let allCommits = try await Git.log(in: root, skip: 0, limit: 20, query: "", allBranches: false)
            let c4 = try XCTUnwrap(allCommits.first { $0.subject.hasPrefix("c4 ") })
            let lineFilter = HistoryFilter(path: "app.swift", lines: 3...3, rev: "HEAD")

            store.showHistory(lineFilter, in: project1, select: c4.hash)
            try await waitUntil { !project1.isLoadingLog && !project1.isLoadingCommit && project1.selectedCommitID == c4.hash }
            let tab2ID = project1.activeLogTabID

            // Return focus to Tab 1 and flush state as on quit
            store.selectLogTab(tab1ID, in: project1)
            store.flushAllPersistedLogStates()

            // Simulate app relaunch with a fresh storage reader and brand new Project instance
            store.logStateStorage = LogStateStorage(fileURL: storageFile)
            let project2 = Project(url: root)
            store.projects = [project2]
            store.selectedProjectID = project2.id
            store.restoreLogState(for: project2)

            XCTAssertEqual(project2.tab, .log)
            XCTAssertEqual(project2.logTabs.count, 2)
            XCTAssertEqual(project2.activeLogTabID, tab1ID)
            XCTAssertEqual(project2.logAuthors, [alice])
            XCTAssertEqual(project2.selectedCommitIDs, [c5.id, c1.id])
            XCTAssertEqual(project2.selectedCommitID, c1.id)
            XCTAssertEqual(project2.selectedCommitFileID, ChangeRow.fileID("extra.swift"))

            // Trigger initial log load as LogPanel.onAppear / syncViewer does on startup
            store.loadActiveLogTab(for: project2)
            try await waitUntil { !project2.isLoadingLog && !project2.isLoadingCommit && !project2.commitFiles.isEmpty }

            XCTAssertEqual(project2.selectedCommitIDs, [c5.id, c1.id])
            XCTAssertEqual(project2.selectedCommitID, c1.id)
            XCTAssertTrue(project2.commitSelectionIsNonContiguous)
            XCTAssertEqual(project2.selectedCommitFileID, ChangeRow.fileID("extra.swift"))
            XCTAssertEqual(store.viewer.request?.path, "extra.swift")

            // Switching to restored Tab 2 lazily loads Tab 2 and preserves c4!
            store.selectLogTab(tab2ID, in: project2)
            try await waitUntil { !project2.isLoadingLog && !project2.isLoadingCommit && !project2.commits.isEmpty }
            XCTAssertEqual(project2.history, lineFilter)
            XCTAssertEqual(project2.selectedCommitID, c4.hash)
            XCTAssertEqual(store.viewer.request?.path, "app.swift")
        }
    }

    @MainActor
    func testRestoreMissingCommitHashFallsBackGracefully() async throws {
        let storageFile = storageDir.appendingPathComponent("missing-hash.json")
        try await withIsolatedStore(storageFile: storageFile) { store, storage in
            let bogus = String(repeating: "f", count: 40)
            let saved = PersistedLogState(
                activeProjectTab: "log",
                activeTabID: nil,
                tabs: [
                    PersistedLogTab(
                        selectedCommitID: bogus,
                        selectedCommitIDs: [bogus],
                        selectedCommitFileID: "f:nonexistent.swift"
                    )
                ]
            )
            storage.save(saved, for: root)

            let project = Project(url: root)
            store.projects = [project]
            store.selectedProjectID = project.id
            store.restoreLogState(for: project)
            store.loadActiveLogTab(for: project)

            try await waitUntil { !project.isLoadingLog && !project.isLoadingCommit && !project.commits.isEmpty }
            XCTAssertEqual(project.selectedCommitID, project.commits.first?.id)
            XCTAssertEqual(project.selectedCommitIDs, Set(project.commits.first.map { [$0.id] } ?? []))
        }
    }

    @MainActor
    func testLogTabDisplayTitlesAndSymbols() {
        let plain = LogTab()
        XCTAssertEqual(plain.symbolName, "clock")
        XCTAssertEqual(plain.displayTitle, L("Log", "日志"))
        XCTAssertFalse(plain.isCustomized)

        let oneAuthor = LogTab(logAuthors: [alice])
        XCTAssertEqual(oneAuthor.symbolName, "person.fill")
        XCTAssertEqual(oneAuthor.displayTitle, "Alice")
        XCTAssertTrue(oneAuthor.isCustomized)

        let multiAuthorAndCommits = LogTab(
            logAuthors: [alice, bob],
            selectedCommitID: "1111111",
            selectedCommitIDs: ["1111111", "2222222", "3333333"]
        )
        XCTAssertEqual(multiAuthorAndCommits.symbolName, "person.2.fill")
        XCTAssertEqual(
            multiAuthorAndCommits.displayTitle,
            L("Alice +1 · 3", "Alice 等2人 · 3")
        )

        let branchTab = LogTab(logRef: "refs/heads/feature/demo")
        XCTAssertEqual(branchTab.symbolName, "arrow.triangle.branch")
        XCTAssertEqual(branchTab.displayTitle, "feature/demo")

        let lineTab = LogTab(history: HistoryFilter(path: "Sources/App.swift", lines: 12...20, rev: "HEAD"))
        XCTAssertEqual(lineTab.symbolName, "text.line.first.and.arrowtriangle.forward")
        XCTAssertEqual(lineTab.displayTitle, "App.swift:12-20")
        XCTAssertTrue(lineTab.tooltip.contains("Sources/App.swift"))
    }

    // MARK: - Helpers

    @MainActor
    private func withIsolatedStore(
        storageFile: URL? = nil,
        body: (AppStore, LogStateStorage) async throws -> Void
    ) async throws {
        let store = AppStore.shared
        let prevProjects = store.projects
        let prevSelectedProjectID = store.selectedProjectID
        let prevRequest = store.viewer.request
        let prevStorage = store.logStateStorage
        let prevListVisible = store.listVisible

        for (_, task) in store.logPersistTasks { task.cancel() }
        store.logPersistTasks.removeAll()

        let file = storageFile ?? storageDir.appendingPathComponent("isolated-\(UUID().uuidString).json")
        let isolatedStorage = LogStateStorage(fileURL: file)
        store.logStateStorage = isolatedStorage

        defer {
            for (_, task) in store.logPersistTasks { task.cancel() }
            store.logPersistTasks.removeAll()
            store.logStateStorage = prevStorage
            store.projects = prevProjects
            store.selectedProjectID = prevSelectedProjectID
            store.listVisible = prevListVisible
            if let prevRequest {
                store.viewer.open(prevRequest)
            } else {
                store.viewer.clear()
            }
        }

        try await body(store, isolatedStorage)
    }

    @MainActor
    private func loadSelectedCommitAndSync(_ project: Project, store: AppStore) async {
        await withCheckedContinuation { continuation in
            project.loadSelectedCommit {
                store.syncViewer()
                continuation.resume()
            }
        }
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5.0, condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for async condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func commit(by author: AuthorFilter, message: String, date: String) throws {
        try git(
            "-c", "user.name=\(author.name)",
            "-c", "user.email=\(author.email)",
            "commit", "-q", "-m", message, "--date=\(date)"
        )
    }

    @discardableResult
    private func git(_ args: String...) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Git.executable)
        p.arguments = ["--no-pager", "-c", "commit.gpgsign=false"] + args
        p.currentDirectoryURL = root
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "LogTabsTests", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: String(decoding: errData, as: UTF8.self),
            ])
        }
        return String(decoding: outData, as: UTF8.self)
    }
}
