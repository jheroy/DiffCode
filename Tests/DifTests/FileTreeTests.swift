import XCTest
@testable import DifKit

final class FileTreeTests: XCTestCase {
    /// In `git ls-files` order: a directory's files are listed together.
    private let paths = [
        "README.md",
        "app/build.gradle",
        "app/src/main/java/com/shop/Cart.kt",
        "app/src/main/java/com/shop/ui/CartScreen.kt",
        "app/src/main/java/com/shop/ui/Theme.kt",
        "app/src/main/res/values/strings.xml",
        "docs/guide/intro.md",
        "docs/guide/setup.md",
        "settings.gradle",
    ]

    private func rows(expanded: Set<String> = [], changes: [FileChange] = []) -> [TreeRow] {
        FileTree.rows(index: FileTreeIndex(paths: paths), expanded: expanded, changes: changes)
    }

    func testCollapsedTreeShowsFoldersBeforeFiles() {
        let top = rows()
        XCTAssertEqual(top.map(\.name), ["app", "docs/guide", "README.md", "settings.gradle"])
        XCTAssertEqual(top.map(\.isDirectory), [true, true, false, false])
        XCTAssertTrue(top.allSatisfy { $0.depth == 0 && !$0.isExpanded })
    }

    func testSingleChildChainsShareOneRow() {
        // "docs" holds nothing but "guide", so the two fold into one row that opens the inner directory.
        let docs = rows()[1]
        XCTAssertEqual(docs.name, "docs/guide")
        XCTAssertEqual(docs.path, "docs/guide")
        XCTAssertEqual(docs.id, TreeRow.directoryID("docs/guide"))
        XCTAssertEqual(docs.parentPath, "")

        let open = rows(expanded: ["app", "app/src/main"])
        XCTAssertEqual(open.map(\.name), ["app", "src/main", "java/com/shop", "res/values", "build.gradle",
                                          "docs/guide", "README.md", "settings.gradle"])
        XCTAssertEqual(open.map(\.depth), [0, 1, 2, 2, 1, 0, 0, 0])
        XCTAssertEqual(open[2].path, "app/src/main/java/com/shop")
        XCTAssertEqual(open[2].parentPath, "app/src/main")
    }

    func testAChainStopsWhereADirectoryHoldsFiles() {
        // "app" has build.gradle next to "src", so it keeps a row of its own.
        let open = rows(expanded: ["app"])
        XCTAssertEqual(open.prefix(3).map(\.name), ["app", "src/main", "build.gradle"])
        XCTAssertTrue(open[0].isExpanded)
        XCTAssertFalse(open[1].isExpanded)
    }

    func testNamesSortTheWayFinderDoes() {
        let index = FileTreeIndex(paths: ["b10.txt", "b2.txt", "a.txt", "Zeta/x", "alpha/y"])
        XCTAssertEqual(FileTree.rows(index: index, expanded: [], changes: []).map(\.name),
                       ["alpha", "Zeta", "a.txt", "b2.txt", "b10.txt"])
    }

    func testChangesMarkFilesAndCountUpThroughFolders() {
        let changes = [
            FileChange(path: "app/src/main/java/com/shop/ui/CartScreen.kt", oldPath: nil, kind: .modified),
            FileChange(path: "app/src/main/java/com/shop/Cart.kt", oldPath: nil, kind: .modified),
            FileChange(path: "README.md", oldPath: nil, kind: .modified),
        ]
        let open = rows(expanded: ["app", "app/src/main", "app/src/main/java/com/shop", "app/src/main/java/com/shop/ui"],
                        changes: changes)
        func row(_ id: String) -> TreeRow? { open.first { $0.id == id } }
        XCTAssertEqual(row(TreeRow.directoryID("app"))?.changedBelow, 2)
        XCTAssertEqual(row(TreeRow.directoryID("app/src/main"))?.changedBelow, 2)
        XCTAssertEqual(row(TreeRow.directoryID("app/src/main/java/com/shop/ui"))?.changedBelow, 1)
        XCTAssertEqual(row(TreeRow.directoryID("app/src/main/res/values"))?.changedBelow, 0)
        XCTAssertEqual(row(TreeRow.directoryID("docs/guide"))?.changedBelow, 0)
        XCTAssertEqual(row(TreeRow.fileID("app/src/main/java/com/shop/ui/CartScreen.kt"))?.change?.kind, .modified)
        XCTAssertNil(row(TreeRow.fileID("app/src/main/java/com/shop/ui/Theme.kt"))?.change)
        XCTAssertEqual(row(TreeRow.fileID("README.md"))?.change?.kind, .modified)
    }

    func testOpeningEveryAncestorMakesAFileVisible() {
        let path = "app/src/main/java/com/shop/ui/Theme.kt"
        XCTAssertEqual(FileTree.ancestors(of: path),
                       ["app", "app/src", "app/src/main", "app/src/main/java", "app/src/main/java/com",
                        "app/src/main/java/com/shop", "app/src/main/java/com/shop/ui"])
        XCTAssertEqual(FileTree.ancestors(of: "README.md"), [])

        XCTAssertFalse(rows().contains { $0.id == TreeRow.fileID(path) })
        let revealed = rows(expanded: Set(FileTree.ancestors(of: path)))
        XCTAssertTrue(revealed.contains { $0.id == TreeRow.fileID(path) })
    }

    func testEnclosingRowsAreTheFoldersAboveARow() {
        let open = rows(expanded: Set(FileTree.ancestors(of: "app/src/main/java/com/shop/ui/Theme.kt")))
        let index = open.firstIndex { $0.id == TreeRow.fileID("app/src/main/java/com/shop/ui/Theme.kt") }!
        XCTAssertEqual(FileTree.enclosing(open, at: index).map(\.name), ["app", "src/main", "java/com/shop", "ui"])
        XCTAssertEqual(FileTree.enclosing(open, at: 0), [])
        XCTAssertEqual(FileTree.enclosing(open, at: open.count + 3), [])
    }

    func testFilteredRowsAreFlatAndKeepTheirMatchPositions() {
        let matches = Fuzzy.rank(query: "cart", in: paths, limit: 10)
        let flat = FileTree.rows(matches: matches,
                                 changes: [FileChange(path: "app/src/main/java/com/shop/Cart.kt", oldPath: nil, kind: .added)])
        // Fuzzy matching also finds c-a-r-t scattered through "src/main/res/…/strings.xml"; the real hits rank first.
        XCTAssertEqual(Set(flat.prefix(2).map(\.name)), ["Cart.kt", "CartScreen.kt"])
        XCTAssertTrue(flat.allSatisfy { $0.depth == 0 && !$0.isDirectory && !$0.positions.isEmpty })
        XCTAssertEqual(flat.first { $0.name == "Cart.kt" }?.change?.kind, .added)
    }

    func testIndentTightensForDeepTreesInANarrowPanel() {
        let shallow = [TreeRow(id: "d:a", path: "a", name: "a", depth: 1, isDirectory: true)]
        let deep = [TreeRow(id: "d:a", path: "a", name: "a", depth: 12, isDirectory: true)]
        let roomy = FileTreePanel.indent(for: shallow, width: 300)
        let tight = FileTreePanel.indent(for: deep, width: 200)
        XCTAssertGreaterThan(roomy, tight)
        XCTAssertGreaterThanOrEqual(tight, 5)
        // The whole indentation never takes more than about a third of the panel.
        XCTAssertLessThanOrEqual(tight * 12, 200 * 0.3 + 12)
    }
}

final class SidebarLayoutTests: XCTestCase {
    func testAFewProjectsTakeOnlyTheRoomTheyNeed() {
        let one = SidebarView.projectsHeight(count: 1, available: 800)
        let three = SidebarView.projectsHeight(count: 3, available: 800)
        XCTAssertGreaterThanOrEqual(one, SidebarView.rowHeight)
        XCTAssertLessThan(one, SidebarView.rowHeight * 1.5)
        XCTAssertGreaterThan(three, SidebarView.rowHeight * 3)
        XCTAssertLessThan(three, SidebarView.rowHeight * 3.5)
    }

    func testManyProjectsLeaveMostOfTheSidebarToTheTree() {
        let many = SidebarView.projectsHeight(count: 40, available: 800)
        XCTAssertLessThanOrEqual(many, 800 * 0.34)
        // The cut falls mid-row, so the list visibly continues.
        let rows = many / (SidebarView.rowHeight + 2)
        XCTAssertEqual(rows - rows.rounded(.down), 0.5, accuracy: 0.01)
        // Even in a short sidebar a couple of projects stay reachable.
        XCTAssertGreaterThanOrEqual(SidebarView.projectsHeight(count: 40, available: 200), SidebarView.rowHeight * 2)
    }

    /// The divider goes where it is dragged, from a row and a half down to the file tree's bar.
    func testADraggedHeightIsKeptAsItIs() {
        let room: CGFloat = 700
        let mostOfIt = SidebarView.projectsHeight(count: 40, available: 800, chosen: 600, room: room)
        XCTAssertEqual(mostOfIt, 600)
        // Dragged all the way down, the tree keeps its bar.
        let all = SidebarView.projectsHeight(count: 40, available: 800, chosen: 5000, room: room)
        XCTAssertEqual(all, (room - 1 - SidebarView.treeMinimum).rounded())
        // With a few projects the space under them stays, to drop folders on.
        XCTAssertEqual(SidebarView.projectsHeight(count: 3, available: 800, chosen: 600, room: room), 600)
        // Dragged up, a row and a half stays.
        let least = SidebarView.projectsHeight(count: 40, available: 800, chosen: 0, room: room)
        XCTAssertEqual(least, ((SidebarView.rowHeight + 2) * 1.5).rounded())
    }

    /// A terminal dragged as high as it goes leaves the sidebar its least, and in that the projects, however the
    /// divider was dragged, and the tree's bar still fit between the heading and the footer.
    @MainActor
    func testTheLeastHeightHoldsWhatTheSidebarCannotDoWithout() {
        let titlebar: CGFloat = 38
        let least = SidebarView.minimumHeight(titlebar: titlebar)
        // Less the title bar's strip, the heading, the line over the footer and the footer.
        let room = least - titlebar - (UI.s(24) + 4) - 1 - UI.s(34)
        for chosen in [nil, 0, 120, 5000] as [Double?] {
            let projects = SidebarView.projectsHeight(count: 40, available: least, chosen: chosen, room: room)
            XCTAssertLessThanOrEqual(projects + 1 + SidebarView.treeMinimum, room, "chosen \(String(describing: chosen))")
        }
    }
}

final class ShellTests: XCTestCase {
    func testPlainPathsAreTypedAsTheyAre() {
        XCTAssertEqual(Shell.quote("app/src/main/Cart.kt"), "app/src/main/Cart.kt")
        XCTAssertEqual(Shell.quote("app/src/main/Cart.kt:12-18"), "app/src/main/Cart.kt:12-18")
    }

    func testAnythingTheShellWouldInterpretIsQuoted() {
        XCTAssertEqual(Shell.quote("My Notes/a b.txt"), "'My Notes/a b.txt'")
        XCTAssertEqual(Shell.quote("it's.txt"), "'it'\\''s.txt'")
        XCTAssertEqual(Shell.quote("$(rm -rf ~).txt"), "'$(rm -rf ~).txt'")
        XCTAssertEqual(Shell.quote("a;b&c|d.txt"), "'a;b&c|d.txt'")
        XCTAssertEqual(Shell.quote("文档/说明.md"), "'文档/说明.md'")
        XCTAssertEqual(Shell.quote(""), "''")
    }

    func testTheTerminalEnvironmentDescribesAnXtermAndDropsTheAppsOwnSwitches() {
        setenv("DIF_ACTIONS", "files", 1)
        defer { unsetenv("DIF_ACTIONS") }
        let env = Shell.environment(directory: "/tmp/project")
        XCTAssertTrue(env.contains("TERM=xterm-256color"))
        XCTAssertTrue(env.contains("TERM_PROGRAM=DiffCode"))
        XCTAssertFalse(env.contains { $0.hasPrefix("DIF_") })
        XCTAssertTrue(env.contains { $0.hasPrefix("LANG=") || $0.hasPrefix("LC_ALL=") || $0.hasPrefix("LC_CTYPE=") })
    }
}
