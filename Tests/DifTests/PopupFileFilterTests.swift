import XCTest
@testable import DifKit

final class PopupFileFilterTests: XCTestCase {
    func testPopupFileFilterMatchesPaths() {
        let allPass = PopupFileFilter(excludeTestGo: false, onlyGoFiles: false)
        XCTAssertTrue(allPass.matches(path: "foo_test.go"))
        XCTAssertTrue(allPass.matches(path: "README.md"))

        let noTestGo = PopupFileFilter(excludeTestGo: true, onlyGoFiles: false)
        XCTAssertFalse(noTestGo.matches(path: "foo_test.go"))
        XCTAssertFalse(noTestGo.matches(path: "test.go"))
        XCTAssertFalse(noTestGo.matches(path: "a/b/bar_test.go"))
        XCTAssertFalse(noTestGo.matches(path: "a/b/UPPER_TEST.GO"))
        XCTAssertTrue(noTestGo.matches(path: "testing.go"))
        XCTAssertTrue(noTestGo.matches(path: "test_helper.go"))
        XCTAssertTrue(noTestGo.matches(path: "main.go"))
        XCTAssertTrue(noTestGo.matches(path: "schema.proto"))
        XCTAssertTrue(noTestGo.matches(path: "FooTests.swift"))

        let onlyGo = PopupFileFilter(excludeTestGo: false, onlyGoFiles: true)
        XCTAssertTrue(onlyGo.matches(path: "main.go"))
        XCTAssertTrue(onlyGo.matches(path: "a/b/foo_test.go"))
        XCTAssertTrue(onlyGo.matches(path: "pkg/SERVER.GO"))
        XCTAssertFalse(onlyGo.matches(path: "api.proto"))
        XCTAssertFalse(onlyGo.matches(path: "README.md"))
        XCTAssertFalse(onlyGo.matches(path: "config.json"))
        XCTAssertFalse(onlyGo.matches(path: "deploy.yaml"))
        XCTAssertFalse(onlyGo.matches(path: "App.swift"))
        XCTAssertFalse(onlyGo.matches(path: "go.mod"))

        let onlyProdGo = PopupFileFilter(excludeTestGo: true, onlyGoFiles: true)
        XCTAssertTrue(onlyProdGo.matches(path: "main.go"))
        XCTAssertTrue(onlyProdGo.matches(path: "internal/testing.go"))
        XCTAssertTrue(onlyProdGo.matches(path: "internal/test_helper.go"))
        XCTAssertFalse(onlyProdGo.matches(path: "internal/handler_test.go"))
        XCTAssertFalse(onlyProdGo.matches(path: "test.go"))
        XCTAssertFalse(onlyProdGo.matches(path: "README.md"))
        XCTAssertFalse(onlyProdGo.matches(path: "service.proto"))
    }

    func testUserDefaultsPersistencePerScope() {
        let suiteName = "PopupFileFilterTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(PopupFileFilter.load(scope: .references, defaults: defaults), PopupFileFilter())
        XCTAssertEqual(PopupFileFilter.load(scope: .findInPath, defaults: defaults), PopupFileFilter())

        PopupFileFilter(excludeTestGo: true, onlyGoFiles: false).save(scope: .references, defaults: defaults)
        PopupFileFilter(excludeTestGo: false, onlyGoFiles: true).save(scope: .findInPath, defaults: defaults)

        XCTAssertEqual(
            PopupFileFilter.load(scope: .references, defaults: defaults),
            PopupFileFilter(excludeTestGo: true, onlyGoFiles: false)
        )
        XCTAssertEqual(
            PopupFileFilter.load(scope: .findInPath, defaults: defaults),
            PopupFileFilter(excludeTestGo: false, onlyGoFiles: true)
        )
    }

    @MainActor
    func testReferencesPickerModelFilteringAndSelectionClamping() {
        let suiteName = "PopupFileFilterTests.Refs.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        func makeItem(id: Int, path: String, line: Int, preview: String) -> ReferenceItem {
            let url = URL(fileURLWithPath: "/tmp/repo/\(path)")
            let loc = LSPLocation(
                uri: url.absoluteString,
                range: LSPRange(start: LSPPosition(line: line - 1, character: 0), end: LSPPosition(line: line - 1, character: 4))
            )
            return ReferenceItem(
                id: id,
                location: loc,
                fileURL: url,
                displayPath: path,
                lineNumber: line,
                column: 0,
                endColumn: 4,
                linePreview: preview,
                matchRangeInPreview: nil,
                isDeclaration: false
            )
        }

        let items = [
            makeItem(id: 0, path: "pkg/handler_test.go", line: 10, preview: "Greet()"),
            makeItem(id: 1, path: "pkg/handler.go", line: 20, preview: "func Greet()"),
            makeItem(id: 2, path: "pkg/testing.go", line: 30, preview: "helper Greet()"),
            makeItem(id: 3, path: "docs/README.md", line: 4, preview: "Greet docs"),
        ]

        let cachedFiles: [URL: CachedPreviewFile] = [
            items[1].fileURL: CachedPreviewFile(
                lines: Array(repeating: "func Greet()", count: 25),
                language: .detect(path: "handler.go"),
                spans: []
            ),
        ]

        let model = ReferencesPickerModel(defaults: defaults)
        model.setItemsForTesting(symbolName: "Greet", title: "Greet", items: items, cachedFiles: cachedFiles)
        XCTAssertEqual(model.filteredItems.map(\.id), [0, 1, 2, 3])

        // Select the last item (.md), then turn on onlyGoFiles -> selection clamps safely to 0.
        model.select(3)
        XCTAssertEqual(model.selectedIndex, 3)

        model.onlyGoFiles = true
        XCTAssertEqual(model.filteredItems.map(\.id), [0, 1, 2])
        XCTAssertEqual(model.selectedIndex, 0)

        // Select handler.go (index 1), then exclude *test.go -> handler.go stays selected and preview updates.
        model.select(1)
        XCTAssertEqual(model.selectedItem?.id, 1)

        model.excludeTestGo = true
        XCTAssertEqual(model.filteredItems.map(\.id), [1, 2])
        XCTAssertEqual(model.selectedItem?.id, 1)
        XCTAssertEqual(model.previewContext?.displayPath, "pkg/handler.go")

        // Combine with text filterQuery.
        model.filterQuery = "testing"
        XCTAssertEqual(model.filteredItems.map(\.id), [2])
        XCTAssertEqual(model.selectedIndex, 0)

        // Persisted toggles survive reopening a new model instance.
        let reopened = ReferencesPickerModel(defaults: defaults)
        XCTAssertTrue(reopened.excludeTestGo)
        XCTAssertTrue(reopened.onlyGoFiles)
    }

    @MainActor
    func testFindInPathModelFilteringAndRestoration() {
        let suiteName = "PopupFileFilterTests.Find.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let projectID = UUID()
        let rawHits = [
            FindInPathModel.Hit(id: 0, projectID: projectID, path: "pkg/service_test.go", line: 12, text: "Run()", match: 0..<3),
            FindInPathModel.Hit(id: 1, projectID: projectID, path: "pkg/service.go", line: 45, text: "func Run()", match: 5..<8),
            FindInPathModel.Hit(id: 2, projectID: projectID, path: "pkg/test_helper.go", line: 8, text: "Run()", match: 0..<3),
            FindInPathModel.Hit(id: 3, projectID: projectID, path: "api/service.proto", line: 3, text: "rpc Run", match: 4..<7),
        ]

        let model = FindInPathModel(defaults: defaults)
        model.setHitsForTesting(rawHits)
        XCTAssertEqual(model.totalHitCount, 4)
        XCTAssertEqual(model.hits.count, 4)
        XCTAssertEqual(model.fileCount, 4)

        // Select the proto hit (index 3), then enable onlyGoFiles -> clamps to valid index.
        model.select(3)
        model.onlyGoFiles = true
        XCTAssertEqual(model.hits.map(\.path), ["pkg/service_test.go", "pkg/service.go", "pkg/test_helper.go"])
        XCTAssertEqual(model.fileCount, 3)
        XCTAssertEqual(model.selected, 0)

        // Select service.go (index 1), then enable excludeTestGo -> service.go stays selected!
        model.select(1)
        model.excludeTestGo = true
        XCTAssertEqual(model.hits.map(\.path), ["pkg/service.go", "pkg/test_helper.go"])
        XCTAssertEqual(model.fileCount, 2)
        XCTAssertEqual(model.hits[model.selected].path, "pkg/service.go")

        // Turning both off restores all original hits cleanly.
        model.onlyGoFiles = false
        model.excludeTestGo = false
        XCTAssertEqual(model.hits.count, 4)
        XCTAssertEqual(model.fileCount, 4)

        // Persistence check.
        model.excludeTestGo = true
        let reopened = FindInPathModel(defaults: defaults)
        XCTAssertTrue(reopened.excludeTestGo)
        XCTAssertFalse(reopened.onlyGoFiles)
    }
}
