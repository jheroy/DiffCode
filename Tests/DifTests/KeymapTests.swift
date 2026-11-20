import AppKit
import XCTest
@testable import DifKit

final class KeymapTests: XCTestCase {
    private struct ShortcutKey: Hashable {
        let key: String
        let modifiers: UInt
    }

    @MainActor
    func testVimSettingsDefaultsAndPersistence() throws {
        let suiteName = "KeymapTests.Vim.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = Settings(defaults: defaults)
        XCTAssertTrue(initial.vimMode, "vimMode should default to true")
        XCTAssertFalse(initial.vimRelativeLineNumbers, "vimRelativeLineNumbers should default to false")

        initial.vimMode = false
        initial.vimRelativeLineNumbers = true
        initial.save()

        let reloaded = Settings(defaults: defaults)
        XCTAssertFalse(reloaded.vimMode)
        XCTAssertTrue(reloaded.vimRelativeLineNumbers)

        reloaded.vimMode = true
        reloaded.vimRelativeLineNumbers = false
        reloaded.save()

        let reloadedAgain = Settings(defaults: defaults)
        XCTAssertTrue(reloadedAgain.vimMode)
        XCTAssertFalse(reloadedAgain.vimRelativeLineNumbers)
    }

    @MainActor
    func testGoLandKeymapBindingsMatchMacOSCopy() {
        let commands = AppStore.shared.commands
        func command(_ id: String) -> AppCommand? {
            commands.first { $0.id == id }
        }

        let goToFile = command("nav.file")
        XCTAssertEqual(goToFile?.key, "p")
        XCTAssertEqual(goToFile?.modifiers, .command)

        let findInPath = command("nav.findInPath")
        XCTAssertEqual(findInPath?.key, "f")
        XCTAssertEqual(findInPath?.modifiers, .command)

        let fileSymbols = command("nav.fileSymbols")
        XCTAssertEqual(fileSymbols?.key, "r")
        XCTAssertEqual(fileSymbols?.modifiers, .command)

        let gitRefresh = command("git.refresh")
        XCTAssertNotNil(gitRefresh)
        XCTAssertTrue(gitRefresh?.key.isEmpty == true, "git.refresh should not collide with ⌘R (File Structure)")

        let terminal = command("view.terminal")
        XCTAssertEqual(terminal?.key, "t")
        XCTAssertEqual(terminal?.modifiers, .command)

        let listToggle = command("view.list")
        XCTAssertEqual(listToggle?.key, "k")
        XCTAssertEqual(listToggle?.modifiers, .command)

        let historySelection = command("git.historySelection")
        XCTAssertEqual(historySelection?.key, "b")
        XCTAssertEqual(historySelection?.modifiers, .command)

        let commit = command("git.commit")
        XCTAssertEqual(commit?.key, "c")
        XCTAssertEqual(commit?.modifiers, [.shift, .control, .option])

        let back = command("nav.back")
        XCTAssertEqual(back?.key, "[")
        XCTAssertEqual(back?.modifiers, .command)

        let forward = command("nav.forward")
        XCTAssertEqual(forward?.key, "]")
        XCTAssertEqual(forward?.modifiers, .command)

        let findAction = command("nav.action")
        XCTAssertEqual(findAction?.key, "a")
        XCTAssertEqual(findAction?.modifiers, [.command, .shift])

        let nextSplitter = command("nav.nextSplitter")
        XCTAssertEqual(nextSplitter?.key, "l")
        XCTAssertEqual(nextSplitter?.modifiers, .command)

        let prevSplitter = command("nav.prevSplitter")
        XCTAssertEqual(prevSplitter?.key, "h")
        XCTAssertEqual(prevSplitter?.modifiers, .command)

        let goToLine = command("nav.line")
        XCTAssertNotNil(goToLine)
        XCTAssertTrue(goToLine?.key.isEmpty == true, "nav.line should not collide with ⌘L (NextSplitter)")

        let newTerminal = command("term.new")
        XCTAssertNotNil(newTerminal)
        XCTAssertTrue(newTerminal?.key.isEmpty == true, "term.new should not collide with ⌘T (Toggle Terminal)")

        let toggleVim = command("view.vimMode")
        XCTAssertEqual(toggleVim?.group, .view)
    }

    @MainActor
    func testNoDuplicateShortcutsAcrossCommandsAndStandardMenus() {
        let commands = AppStore.shared.commands
        var seen: [ShortcutKey: String] = [:]

        for cmd in commands where !cmd.key.isEmpty {
            let shortcut = ShortcutKey(
                key: cmd.key.lowercased(),
                modifiers: cmd.modifiers.intersection([.command, .option, .control, .shift]).rawValue
            )
            if let existing = seen[shortcut] {
                XCTFail("Duplicate shortcut (\(cmd.shortcut)) between '\(existing)' and '\(cmd.id)'")
            }
            seen[shortcut] = cmd.id
        }

        // Standard menu items built in AppDelegate.buildMenu()
        let standardMenuItems: [(id: String, key: String, modifiers: NSEvent.ModifierFlags)] = [
            ("app.settings", ",", .command),
            ("app.hideOthers", "h", [.command, .option]),
            ("app.quit", "q", .command),
            ("edit.undo", "z", .command),
            ("edit.redo", "z", [.command, .shift]),
            ("edit.cut", "x", .command),
            ("edit.copy", "c", .command),
            ("edit.paste", "v", .command),
            ("edit.selectAll", "a", .command),
            ("edit.expandSelection", ".", .command),
            ("edit.shrinkSelection", ";", .command),
            ("edit.find", "f", [.control, .shift, .command]),
            ("edit.findNext", "g", .command),
            ("edit.findPrevious", "g", [.command, .shift]),
            ("navigate.nextChange", "\u{F701}", [.control, .option, .shift]),
            ("navigate.prevChange", "\u{F700}", [.control, .option, .shift]),
            ("window.minimize", "m", .command),
            ("window.fullScreen", "f", [.command, .control]),
            ("window.close", "w", .command),
        ]

        for item in standardMenuItems {
            let shortcut = ShortcutKey(
                key: item.key.lowercased(),
                modifiers: item.modifiers.intersection([.command, .option, .control, .shift]).rawValue
            )
            if let existing = seen[shortcut] {
                XCTFail("Menu item '\(item.id)' collides with '\(existing)'")
            }
            seen[shortcut] = item.id
        }
    }

    @MainActor
    func testToggleVimModeCommandFlipsSetting() {
        let store = AppStore.shared
        let original = store.settings.vimMode
        defer {
            store.viewer.setVimMode(original)
        }

        guard let cmd = store.commands.first(where: { $0.id == "view.vimMode" }) else {
            return XCTFail("Missing view.vimMode command")
        }
        cmd.action()
        XCTAssertEqual(store.settings.vimMode, !original)
        XCTAssertEqual(store.viewer.vimModeEnabled, !original)
        cmd.action()
        XCTAssertEqual(store.settings.vimMode, original)
        XCTAssertEqual(store.viewer.vimModeEnabled, original)
    }

    @MainActor
    func testViewerModelSyncsVimSettingsLive() throws {
        let suiteName = "KeymapTests.ViewerVimSync.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: defaults)
        settings.vimMode = false
        settings.vimRelativeLineNumbers = true

        let viewer = ViewerModel()
        viewer.settings = settings
        XCTAssertFalse(viewer.vimModeEnabled)
        XCTAssertTrue(viewer.vimRelativeLineNumbers)

        let container = CodeScrollContainer(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        viewer.attach(container)
        XCTAssertFalse(container.canvas.vimModeEnabled)
        XCTAssertTrue(container.canvas.vimRelativeLineNumbers)

        viewer.setVimMode(true)
        XCTAssertTrue(settings.vimMode)
        XCTAssertTrue(viewer.vimModeEnabled)
        XCTAssertTrue(container.canvas.vimModeEnabled)

        viewer.setVimRelativeLineNumbers(false)
        XCTAssertFalse(settings.vimRelativeLineNumbers)
        XCTAssertFalse(viewer.vimRelativeLineNumbers)
        XCTAssertFalse(container.canvas.vimRelativeLineNumbers)
    }
}
