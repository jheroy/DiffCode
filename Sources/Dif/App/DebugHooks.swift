#if DEBUG || DIF_HOOKS
import AppKit

/// Developer-only automation, driven by environment variables. Compiled into debug builds
/// (and release builds made with `-Xswiftc -DDIF_HOOKS`); the shipping app does not contain it.
///
///     DIF_ACTIONS="split;select:src/Main.kt;key:f7"   run UI actions after launch (see `perform`)
///     DIF_SNAPSHOT=/path/out.png                      write the window to a PNG and quit
///     DIF_SNAPSHOT_SCREEN=1                           …as composited on screen rather than re-rendered
///     DIF_BENCH=1                                     print scroll timings and quit
///     DIF_SIZE=1400x860  DIF_DELAY=1.2                window size / seconds before the first action
/// Holds a one-shot notification observer so its own handler can remove it.
private final class MenuObserver: @unchecked Sendable {
    var token: NSObjectProtocol?
}

@MainActor
enum DebugHooks {
    static func run(store: AppStore, window: NSWindow) {
        let env = ProcessInfo.processInfo.environment
        let actions = (env["DIF_ACTIONS"] ?? "").split(separator: ";").map(String.init)
        let snapshot = env["DIF_SNAPSHOT"]
        let bench = env["DIF_BENCH"] != nil
        guard !actions.isEmpty || snapshot != nil || bench else { return }
        if let size = env["DIF_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            window.setContentSize(NSSize(width: size[0], height: size[1]))
            window.center()
        }

        var delay = Double(env["DIF_DELAY"] ?? "") ?? 1.2
        for action in actions {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { perform(action, store: store) }
            delay += 0.6
        }
        if bench {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { benchmark(store: store) }
            delay += 4
        }
        if let snapshot {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.6) {
                write(window: window, to: snapshot)
                store.terminals.terminateAll() // so the "still running" confirmation does not hold up an unattended run
                // Nor may a question an action left open (a quit waiting on one would never finish).
                if store.dialog != nil { store.answerDialog(confirmed: false) }
                if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
                // Changes that could not be saved would ask too; a test run's copies are thrown away anyway.
                (NSApp.delegate as? AppDelegate)?.quitConfirmed = true
                NSApp.terminate(nil)
            }
        } else if bench {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                store.terminals.terminateAll()
                NSApp.terminate(nil)
            }
        }
    }

    private static func perform(_ action: String, store: AppStore) {
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "unified": if !store.settings.unified { store.viewer.toggleUnified() }
        case "split": if store.settings.unified { store.viewer.toggleUnified() }
        case "light": store.settings.appearance = .light; store.settings.applyAppearance()
        case "dark": store.settings.appearance = .dark; store.settings.applyAppearance()
        case "log": store.setTab(.log)
        case "groups": store.setTab(.groups)
        case "changes": store.setTab(.changes)
        case "project":
            if let project = store.projects.first(where: { $0.name == argument }) { store.select(project) }
        case "next": store.viewer.stepDifference(1)
        case "nextfile": store.stepFile(1)
        case "open": if let project = store.currentProject { store.openFile(in: project, path: argument, line: nil) }
        case "select":
            if let project = store.currentProject {
                project.selectedChangeID = ChangeRow.fileID(argument)
                store.changeSelectionChanged(project)
            }
        case "multi":
            // "multi:a.kt,b.kt" selects several rows of the Changes list; an id with a colon ("g:unversioned") is used as is.
            if let project = store.currentProject {
                let ids = argument.split(separator: ",").map { $0.contains(":") ? String($0) : ChangeRow.fileID(String($0)) }
                project.selectedChangeIDs = Set(ids)
                project.selectedChangeID = ids.last
            }
        case "rollback", "askrollback":
            // The selection, or the named file. "ask…" shows the confirmation instead of going ahead.
            if let project = store.currentProject {
                let targets = argument.isEmpty ? store.selectedChanges(in: project) : project.changes.filter { $0.path == argument }
                store.rollback(targets, in: project, confirm: parts[0] == "askrollback")
            }
        case "trash", "asktrash":
            if let project = store.currentProject {
                let targets = argument.isEmpty ? store.selectedChanges(in: project) : project.changes.filter { $0.path == argument }
                store.delete(targets, in: project, confirm: parts[0] == "asktrash")
            }
        case "reverthunk":
            store.rollbackHunk(Int(argument) ?? 0)
        case "committick":
            // "committick:2": clicks the commit tick of change 2 of the file on screen.
            store.toggleCommitHunk(Int(argument) ?? 0)
        case "commitlines":
            // "commitlines:include" or "commitlines:exclude": the selected lines, as the viewer's menu does.
            store.setSelectedLines(included: argument == "include")
        case "commitstate":
            // What of the file on screen goes into the next commit, and what its ticks show.
            guard let project = store.currentProject else { break }
            let change = store.viewerChange(in: project)
            let excluded = change.flatMap { project.excludedLines[$0.path] } ?? []
            let removed = excluded.filter(\.removed).map(\.line).sorted(), added = excluded.filter { !$0.removed }.map(\.line).sorted()
            let ticks = store.viewer.container?.canvas.commitTicks
            let rows = project.changes.map { "\($0.name)=\(project.inclusion($0))" }.joined(separator: ",")
            FileHandle.standardError.write(Data("commitstate: file=\(change?.path ?? "-") pickable=\(store.pickableChange(in: project) != nil) ticks=\(ticks == nil ? "none" : (ticks!.included ? "included" : "unticked")) removed=\(removed) added=\(added) hunks=[\(store.viewer.container?.canvas.visibleTickStates ?? "")] rows=\(rows) sel=\(store.viewer.container?.canvas.selection.map { "\($0.lower.row)-\($0.upper.row)" } ?? "-") lines=\(store.viewer.container?.canvas.selectedSourceLines().map { "\($0.side == .left ? "L" : "R")\($0.line)" } ?? [])\n".utf8))
        case "viewermenu":
            // "viewermenu" prints the viewer's right-click menu; "viewermenu:<hunk>" as if over that change;
            // "viewermenu:<hunk>|<title prefix>" runs that item.
            let pieces = argument.split(separator: "|", maxSplits: 1).map(String.init)
            store.viewer.container?.canvas.noteContextHunk(pieces.first.flatMap { Int($0) })
            guard let menu = store.viewerContextMenu() else { break }
            if pieces.count == 2 {
                if let item = menu.items.first(where: { $0.title.hasPrefix(pieces[1]) }), let action = item.action {
                    NSApp.sendAction(action, to: item.target, from: item)
                } else {
                    FileHandle.standardError.write(Data("viewermenu: no item \(pieces[1])\n".utf8))
                }
            } else {
                FileHandle.standardError.write(Data("viewermenu: \(menu.items.map { $0.isSeparatorItem ? "—" : $0.title })\n".utf8))
            }
        case "undo":
            store.undoEdit()
        case "find":
            store.showFindInPath()
            store.finder.query = argument
            store.finder.search()
        case "quick":
            store.showQuickOpen(.files)
            store.quickOpen.query = argument
            store.quickOpen.update()
        case "everywhere":
            store.showQuickOpen(.all)
            store.quickOpen.query = argument
            store.quickOpen.update()
        case "actions": store.showQuickOpen(.actions)
        case "keymap": store.present(.keymap)
        case "settings": store.present(.settings)
        case "language":
            // "language:system|english|chinese", as picked in Settings.
            if let choice = Settings.Language(rawValue: argument) { store.settings.chooseLanguage(choice) }
        case "languagestate":
            let settings = store.settings
            let stored = UserDefaults.standard.persistentDomain(forName: Settings.domain)?[Settings.Language.key] as? [String]
            FileHandle.standardError.write(Data(("language: chosen=\(settings.language.rawValue) stored=\(stored ?? []) "
                + "showing=\(Localization.isChinese ? "zh" : "en") restart=\(settings.languageNeedsRestart) "
                + "system=\(Settings.Language.systemLanguages.prefix(2)) domain=\(Settings.domain)\n").utf8))
        case "restart": store.restart()
        case "infile":
            store.viewer.findQuery = argument
            store.viewer.showFind()
        case "scroll": store.viewer.container?.scroll(toY: CGFloat(Double(argument) ?? 0), animated: false)
        case "line": store.viewer.reveal(line: Int(argument) ?? 1)
        case "selectlines":
            // "selectlines:3-9" selects whole rows in the right pane.
            let bounds = argument.split(separator: "-").compactMap { Int($0) }
            if bounds.count == 2, let canvas = store.viewer.container?.canvas {
                canvas.selection = TextSelection(pane: .right, anchor: TextPosition(row: bounds[0], column: 4),
                                                 head: TextPosition(row: bounds[1], column: 12))
            }
        case "tab": store.setTab(argument == "log" ? .log : (argument == "groups" ? .groups : .changes))
        case "files": store.focusTree()
        case "sidebar": store.toggleSidebar()
        case "locate": store.locateInTree()
        case "expand": store.currentProject?.treeExpanded.insert(argument)
        case "tree":
            // "tree:app/src/Main.kt" selects a file row, as a click would.
            if let project = store.currentProject {
                for directory in FileTree.ancestors(of: argument) { project.treeExpanded.insert(directory) }
                project.treeSelectedID = TreeRow.fileID(argument)
                project.treeRevealToken += 1
                store.treeSelectionChanged(project)
            }
        case "treefilter": store.currentProject?.treeFilter = argument
        case "terminal": store.terminals.toggle()
        case "termpanel": store.terminals.isVisible.toggle()
        case "newterm": store.terminals.openInCurrentProject()
        case "type":
            // Types a line into the active terminal and presses Return.
            if let project = store.currentProject, let session = store.terminals.active(for: project) {
                session.view.send(txt: argument + "\r")
            }
        case "termstate":
            store.terminals.sessions.forEach { $0.pollForeground() }
            let lines = store.terminals.sessions.map { "\($0.processName)|\($0.title.suffix(30)) busy=\($0.isBusy) attention=\($0.needsAttention) started=\($0.isStarted) cols=\($0.view.getTerminal().cols) rows=\($0.view.getTerminal().rows)" }
            FileHandle.standardError.write(Data("terminals: visible=\(store.terminals.isVisible) focused=\(store.terminals.focusedID != nil) \(lines)\n".utf8))
        case "termline":
            // The focused terminal's cursor line, and whether an input method is composing there.
            if let session = store.terminals.sessions.first(where: { $0.id == store.terminals.focusedID }) ?? store.terminals.sessions.first {
                let terminal = session.view.getTerminal()
                let row = terminal.getCursorLocation().y
                let line = terminal.getLine(row: row)?.translateToString(trimRight: true) ?? ""
                FileHandle.standardError.write(Data("termline \(line) marked=\(session.view.hasMarkedText())\n".utf8))
            } else {
                FileHandle.standardError.write(Data("termline none (\(store.terminals.sessions.count) sessions)\n".utf8))
            }
        case "focusviewer": store.focusViewer()
        case "projectstate":
            // What the sandbox lets each project do: whether its folder is open, what git said.
            let lines = store.projects.map { p in
                "\(p.url.path) access=\(!p.needsAccess) loaded=\(p.hasLoaded) changes=\(p.changes.count) branch=\(p.branchLabel) " +
                    "worktree=\(p.worktreeOf != nil) derived=\(p.isDerived) dormant=\(p.isDormant) " +
                    "deferred=\(p.needsRefreshWhenVisible) visible=\(store.isWindowVisible) error=\(p.errorMessage ?? "-")"
            }
            FileHandle.standardError.write(Data("""
                projects: sandbox=\(Sandbox.isActive) git=\(Git.executable) gitMissing=\(store.gitMissing) home=\(Sandbox.canReadHome) \
                gitconfig=\(Sandbox.canReadGlobalGitConfig) grants=\(FolderAccess.shared.granted.keys.sorted())
                \(lines.joined(separator: "\n"))

                """.utf8))
        case "fold":
            // "fold:api": folds or unfolds the repositories inside the project of that name.
            if let project = store.projects.first(where: { $0.name == argument }) { store.toggleCollapsed(project) }
        case "rediscover":
            // The sidebar menu's Refresh on the current project.
            if let project = store.currentProject { store.refreshAndDiscover(project) }
        case "addproject": store.addProjects([URL(fileURLWithPath: argument)])
        case "dropgrants": UserDefaults.standard.removeObject(forKey: "folderBookmarks") // the next launch starts without them
        case "gitident":
            // Who git thinks is committing, as the sandbox lets it see the user's settings.
            if let project = store.currentProject {
                Task {
                    // Where git found user.name, not the name itself.
                    let scope = argument == "global" ? ["--global"] : []
                    let output = (try? await Git.run(["config"] + scope + ["--show-origin", "--get", "user.name"], in: project.url, okStatuses: [0, 1]))
                        .map { String(decoding: $0, as: UTF8.self) } ?? "?"
                    let origin = output.split(separator: "\t").first.map(String.init) ?? "none"
                    FileHandle.standardError.write(Data("gitident: \(origin.isEmpty ? "none" : origin)\n".utf8))
                }
            }
        case "uifont":
            store.settings.uiFontSize = Double(argument) ?? 13
        case "termfont":
            store.changeTerminalFontSize(by: (Double(argument) ?? 12) - store.settings.terminalFontSize)
        case "codefamily":
            // A family as picked in Settings; "default" puts back the default face.
            store.chooseCodeFont(argument == "default" ? nil : argument)
        case "termfamily":
            store.chooseTerminalFont(argument == "default" ? nil : argument)
        case "regfont":
            // Makes a font file usable by this process only: nothing is installed on the system.
            var error: Unmanaged<CFError>?
            let ok = CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: argument) as CFURL, .process, &error)
            FileHandle.standardError.write(Data("regfont: \(ok) \(error.map { "\($0.takeRetainedValue())" } ?? "")\n".utf8))
        case "fontstate":
            let terminals = store.terminals.sessions.map { "\($0.view.font.fontName)@\($0.view.font.pointSize)" }
            let installed = MonospaceFonts.installed()
            FileHandle.standardError.write(Data("""
                fontstate: code=\(store.settings.codeFontFamily ?? "default") canvas=\(store.viewer.container?.canvas.codeFont.font.fontName ?? "-") \
                terminal=\(store.settings.terminalFontFamily ?? "default") sessions=\(terminals) default=\(MonospaceFonts.defaultName) \
                installed(\(installed.count))=\(installed.joined(separator: ","))

                """.utf8))
        case "memory":
            FileHandle.standardError.write(Data(String(format: "memory: %.1f MB\n", AppStore.footprintMB()).utf8))
        case "relief":
            // Hands memory malloc holds but no longer uses back to the system, and reports what that saved.
            let before = AppStore.footprintMB()
            malloc_zone_pressure_relief(nil, 0)
            FileHandle.standardError.write(Data(String(format: "relief: %.1f → %.1f MB\n", before, AppStore.footprintMB()).utf8))
        case "commit":
            if let project = store.currentProject, let index = Int(argument), index < project.commits.count {
                // As a click on the commit's row would.
                project.selectedCommitID = project.commits[index].id
                store.pickedInLog(project, commitChanged: true)
                store.commitSelectionChanged(project)
            }
        case "goto": store.present(.goToLine)
        case "key": postKey(argument, window: store.window)
        case "shift2":
            // Two quick taps of Shift, as the hardware would report them.
            let now = ProcessInfo.processInfo.systemUptime
            for (index, down) in [true, false, true, false].enumerated() {
                if let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: down ? .shift : [],
                                                timestamp: now + Double(index) * 0.06, windowNumber: store.window?.windowNumber ?? 0,
                                                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        case "wheel":
            // Pixel-precise scroll events, delivered to the scroll view the way a trackpad's would be.
            guard let scrollView = store.viewer.container?.scrollView else { break }
            for _ in 0..<12 {
                if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                    wheel1: Int32(-(Double(argument) ?? 40)), wheel2: 0, wheel3: 0),
                   let event = NSEvent(cgEvent: cg) {
                    scrollView.scrollWheel(with: event)
                }
            }
        case "drag":
            // "drag:x1,y1,x2,y2" in points from the top-left of the diff canvas.
            let v = argument.split(separator: ",").compactMap { Double($0) }
            guard v.count == 4, let window = store.window, let canvas = store.viewer.container?.canvas else { break }
            func point(_ x: Double, _ y: Double) -> NSPoint { canvas.convert(NSPoint(x: x, y: y), to: nil) }
            let steps: [(NSEvent.EventType, NSPoint)] = [
                (.leftMouseDown, point(v[0], v[1])),
                (.leftMouseDragged, point((v[0] + v[2]) / 2, (v[1] + v[3]) / 2)),
                (.leftMouseDragged, point(v[2], v[3])),
                (.leftMouseUp, point(v[2], v[3])),
            ]
            for (type, location) in steps {
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        case "windrag":
            // "windrag:x1,y1,x2,y2" in points from the top-left of the window's content: for dividers and resize handles.
            let v = argument.split(separator: ",").compactMap { Double($0) }
            guard v.count == 4, let window = store.window, let height = window.contentView?.bounds.height else { break }
            func point(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: x, y: Double(height) - y) }
            var steps: [(NSEvent.EventType, NSPoint)] = [(.leftMouseDown, point(v[0], v[1]))]
            for step in 1...6 {
                let t = Double(step) / 6
                steps.append((.leftMouseDragged, point(v[0] + (v[2] - v[0]) * t, v[1] + (v[3] - v[1]) * t)))
            }
            steps.append((.leftMouseUp, point(v[2], v[3])))
            // Handed straight to the view under the pointer: a window that is not key swallows a posted
            // mouse-down as the click that activates it, and these runs never take focus from the user.
            let target = window.contentView?.superview?.hitTest(steps[0].1) ?? window.contentView
            FileHandle.standardError.write(Data("windrag hits \(target.map { String(describing: type(of: $0)) } ?? "nothing")\n".utf8))
            for (type, location) in steps {
                guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                switch type {
                case .leftMouseDown: target?.mouseDown(with: event)
                case .leftMouseDragged: target?.mouseDragged(with: event)
                default: target?.mouseUp(with: event)
                }
            }
        case "selection":
            // Reports state without touching the user's clipboard.
            let canvas = store.viewer.container?.canvas
            let text = canvas?.selectedText() ?? "<none>"
            FileHandle.standardError.write(Data("selection: \(text.debugDescription) scrollY=\(store.viewer.container?.scrollY ?? -1) popup=\(String(describing: store.popup)) sidebar=\(Int(store.settings.sidebarWidth)) list=\(Int(store.settings.listWidth)) term=\(Int(store.settings.terminalHeight)) tab=\(store.currentProject?.tab.rawValue ?? "-") browsed=\(store.currentProject?.browsedPath ?? "-") change=\(store.currentProject?.selectedChangeID ?? "-") focus=\((store.window?.firstResponder as? NSView)?.identifier?.rawValue ?? store.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") tree=\(store.currentProject?.treeSelectedID ?? "-") unified=\(store.settings.unified) changes=\(store.currentProject?.status.changes.count ?? -1) hunk=\(String(describing: store.viewer.focusedHunk)) file=\(store.viewer.request?.path ?? "-") hunks=\(store.viewer.hunkCount) multi=\(store.currentProject?.selectedChangeIDs.count ?? 0) undo=\(store.undoStack.count) toast=\(store.toast ?? "-") dialog=\(store.dialog?.title ?? "-") included=\(store.currentProject?.includedChanges.count ?? -1) message=\(store.currentProject?.commitMessage.debugDescription ?? "-") lastCommit=\(store.currentProject?.lastCommit?.shortHash ?? "-") termVisible=\(store.terminals.isVisible)\n".utf8))
        case "autoscroll":
            // "autoscroll:5" or "autoscroll:5:100" — scrolls for that many seconds at 12 (or the given)
            // points per 120 Hz tick, driven by the run loop like a real scroll.
            let pieces = argument.split(separator: ":").compactMap { Double($0) }
            let until = CACurrentMediaTime() + (pieces.first ?? 3)
            let step = CGFloat(pieces.count > 1 ? pieces[1] : 12)
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { timer in
                MainActor.assumeIsolated { store.viewer.container?.scrollBy(dx: 0, dy: step) }
                if CACurrentMediaTime() > until { timer.invalidate() }
            }
            RunLoop.main.add(timer, forMode: .common)
        case "hidelist": store.toggleMaximizeViewer()
        // Git graph
        case "graph": store.toggleGitGraph()
        case "graphscope":
            // "graphscope:all", or a full ref name: as a click on that row of the branch list.
            let id = argument == "all" ? "scope:all" : (argument == "head" ? "scope:head" : "ref:" + argument)
            if let row = store.gitGraph.branchRows.first(where: { $0.id == id }) { store.gitGraph.pick(row) }
        case "graphpick":
            if let index = Int(argument), store.gitGraph.rows.indices.contains(index) { store.gitGraph.selectedCommitID = store.gitGraph.rows[index].id }
        case "graphopen":
            if let id = store.gitGraph.selectedCommitID { store.showCommitInLog(id) }
        case "graphmenuitem":
            // "graphmenuitem:<title prefix>": runs that item of the selected row's right-click menu in the Git graph.
            let model = store.gitGraph
            guard let id = model.selectedCommitID, let row = model.rows.first(where: { $0.id == id }) else {
                FileHandle.standardError.write(Data("graphmenuitem: no row picked\n".utf8))
                break
            }
            let menu = model.contextMenu(for: row)
            if let item = menu.items.first(where: { $0.title.hasPrefix(argument) }), item.isEnabled, let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            } else {
                let titles = menu.items.map { $0.isSeparatorItem ? "—" : ($0.isEnabled ? $0.title : "(\($0.title))") }
                FileHandle.standardError.write(Data("graphmenuitem: no enabled item \(argument) in \(titles)\n".utf8))
            }
        case "graphstate":
            let model = store.gitGraph
            let lanes = model.rows.prefix(12).map { "\($0.commit.shortHash)@\($0.column)" }.joined(separator: " ")
            FileHandle.standardError.write(Data("graph: scope=\(model.scopeTitle) rows=\(model.rows.count) lanes=\(model.laneCount) refs=\(model.refs.count) selected=\(model.selectedCommitID?.prefix(7) ?? "-") branch=\(model.selectedBranchID ?? "-") [\(lanes)]\n".utf8))
        // Commit
        case "include", "exclude":
            if let project = store.currentProject {
                project.setIncluded(parts[0] == "include", project.changes.filter { $0.path == argument })
            }
        case "commitmsg":
            // "\n" in the argument becomes a line break.
            store.currentProject?.commitMessage = argument.replacingOccurrences(of: "\\n", with: "\n")
        case "focuscommit": store.focusCommitMessage()
        case "docommit": store.commitCurrent()
        case "amend":
            // "amend:on", "amend:off"
            store.setAmend(argument != "off")
        case "amendstate":
            if let project = store.currentProject {
                FileHandle.standardError.write(Data("amend: on=\(project.amend) pushed=\(project.amendPushedTo) message=\(project.commitMessage.debugDescription) lastCommit=\(project.lastCommit?.shortHash ?? "-") amended=\(project.lastCommit?.amended?.prefix(7) ?? "-") toast=\(store.toast ?? "-")\n".utf8))
            }
        case "undocommit": store.undoLastCommit()
        case "logstate":
            if let project = store.currentProject {
                let history = project.history.map { "\($0.label)@\($0.rev.prefix(7))" } ?? "-"
                let subjects = project.commits.prefix(8).map(\.subject)
                FileHandle.standardError.write(Data("log: tab=\(project.tab.rawValue) commits=\(project.commits.count) selected=\(project.selectedCommitID?.prefix(7) ?? "-") ref=\(project.logRef ?? "-") all=\(project.logAllBranches) files=\(project.commitFiles.count) file=\(project.selectedCommitFileID ?? "-") history=\(history) subjects=\(subjects) viewer=\(describeViewer(store))\n".utf8))
            }
        // History, Annotate, comparing
        case "annotate": store.viewer.toggleAnnotate()
        case "annostate":
            let viewer = store.viewer
            let annotations = viewer.container?.canvas.annotations
            var labels: [String] = []
            if let annotations {
                for line in annotations.lines.indices where labels.count < 8 && annotations.isRunStart(line) {
                    if let entry = annotations.entry(atLine: line) { labels.append("\(line + 1):\(entry.label)") }
                }
            }
            FileHandle.standardError.write(Data("annotate: on=\(viewer.annotating) busy=\(viewer.isBlaming) entries=\(annotations?.entries.count ?? -1) lines=\(annotations?.lines.count ?? -1) committed=\(annotations?.lines.filter { $0 >= 0 }.count ?? -1) columns=\(annotations?.columns ?? -1) ms=\(Int(viewer.blameMilliseconds)) hover=\(viewer.annotationHover.map { "\($0.entry.shortHash)@\(Int($0.anchor.x)),\(Int($0.anchor.y))" } ?? "-") labels=\(labels)\n".utf8))
        case "annoclick", "annohover":
            // "annoclick:12": a real click on line 12's label in the Annotate column ("annohover:12": the pointer moves there).
            guard let canvas = store.viewer.container?.canvas, let window = store.window,
                  let point = canvas.annotationPoint(line: (Int(argument) ?? 1) - 1) else {
                FileHandle.standardError.write(Data("annoclick: no label there\n".utf8))
                break
            }
            let location = canvas.convert(point, to: nil)
            CodeCanvasView.keepsHoverOnExit = true
            // The first move into a tracking area only enters it; a second one is what reports the position.
            let types: [NSEvent.EventType] = parts[0] == "annohover" ? [.mouseMoved, .mouseMoved] : [.leftMouseDown, .leftMouseUp]
            for (index, type) in types.enumerated() {
                let location = NSPoint(x: location.x + (index == 0 && type == .mouseMoved ? -1 : 0), y: location.y)
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                  clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .mouseMoved ? 0 : 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        case "history": if let project = store.currentProject { store.showHistory(path: argument, in: project) }
        case "historyfile": store.showHistoryForCurrentFile()
        case "historysel": store.showHistoryForSelection()
        case "endhistory": store.endHistory()
        case "selectleft":
            // "selectleft:3-5" selects whole rows in the left pane.
            let bounds = argument.split(separator: "-").compactMap { Int($0) }
            if bounds.count == 2, let canvas = store.viewer.container?.canvas {
                canvas.selection = TextSelection(pane: .left, anchor: TextPosition(row: bounds[0], column: 0),
                                                 head: TextPosition(row: bounds[1], column: 1))
            }
        case "compare":
            // "compare:refs/heads/main|main|fork" — fork: from where HEAD and it forked.
            let bits = argument.split(separator: "|").map(String.init)
            if let target = bits.first {
                store.compare(with: target, title: bits.count > 1 ? bits[1] : target, forkPoint: bits.count > 2 && bits[2] == "fork")
            }
        case "compare2":
            // "compare2:HEAD~3|HEAD": two commits compared with each other, the first on the left.
            let bits = argument.split(separator: "|").map(String.init)
            guard bits.count == 2, let project = store.currentProject else { break }
            Task { @MainActor in
                guard let older = await Git.commit(bits[0], in: project.url), let newer = await Git.commit(bits[1], in: project.url) else {
                    FileHandle.standardError.write(Data("compare2: no such commits\n".utf8))
                    return
                }
                store.compareCommits(older, newer, in: project)
            }
        case "logpick":
            // "logpick:0,3": ⌘-click rows of the Log, then print the first one's right-click menu.
            guard let project = store.currentProject else { break }
            let picked = argument.split(separator: ",").compactMap { Int($0) }.filter(project.commits.indices.contains)
            guard let first = picked.first else { break }
            project.selectedCommitID = project.commits[first].hash
            project.selectedCommitIDs = Set(picked.map { project.commits[$0].hash })
            let titles = store.logCommitMenu(project.commits[first], in: project).items.map { $0.isSeparatorItem ? "—" : ($0.isEnabled ? $0.title : "(\($0.title))") }
            FileHandle.standardError.write(Data("logmenu: \(titles)\n".utf8))
        case "logmenuitem":
            // "logmenuitem:<title prefix>": runs that item of the first picked commit's menu.
            guard let project = store.currentProject, let id = project.selectedCommitID,
                  let commit = project.commits.first(where: { $0.hash == id }) else { break }
            let menu = store.logCommitMenu(commit, in: project)
            if let item = menu.items.first(where: { $0.title.hasPrefix(argument) }), item.isEnabled, let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            } else {
                FileHandle.standardError.write(Data("logmenuitem: no enabled item \(argument)\n".utf8))
            }
        case "graphmulti":
            // "graphmulti:0,2": ⌘-click rows of the open Git graph, then print the first one's right-click menu.
            let model = store.gitGraph
            let picked = argument.split(separator: ",").compactMap { Int($0) }.filter(model.rows.indices.contains)
            guard let first = picked.first else { break }
            model.selectedCommitID = model.rows[first].id
            model.selectedCommitIDs = Set(picked.map { model.rows[$0].id })
            let titles = model.contextMenu(for: model.rows[first]).items.map { $0.isSeparatorItem ? "—" : ($0.isEnabled ? $0.title : "(\($0.title))") }
            FileHandle.standardError.write(Data("graphmenu: \(titles)\n".utf8))
        case "listdrag":
            // "listdrag:x1,y1,x2,y2" in window points from the top-left: press, drag and release, queued as real events.
            guard let window = store.window, let content = window.contentView else { break }
            let v = argument.split(separator: ",").compactMap { Double($0) }
            guard v.count == 4 else { break }
            func point(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: x, y: content.bounds.height - y) }
            let steps: [(NSEvent.EventType, NSPoint)] = [
                (.leftMouseDown, point(v[0], v[1])),
                (.leftMouseDragged, point(v[0] + 3, v[1] + 2)),
                (.leftMouseDragged, point((v[0] + v[2]) / 2, (v[1] + v[3]) / 2)),
                (.leftMouseDragged, point(v[2], v[3])),
                (.leftMouseUp, point(v[2], v[3])),
            ]
            for (type, location) in steps {
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        case "comparepick": store.showComparePicker()
        case "endcompare": store.endComparison()
        case "comparestate":
            if let project = store.currentProject {
                let comparison = project.comparison
                let files = project.compareChanges.map { "\($0.kind.letter) \($0.path)\($0.additions.map { " +\($0)" } ?? "")\($0.deletions.map { " -\($0)" } ?? "")" }
                FileHandle.standardError.write(Data("compare: target=\(comparison?.target ?? "-") title=\(comparison?.title ?? "-") base=\(comparison?.base.prefix(7) ?? "-") head=\(comparison?.head?.prefix(7) ?? "worktree") fork=\(comparison?.forkPoint ?? false) loading=\(project.isLoadingCompare) error=\(project.compareError ?? "-") files=\(files) selected=\(project.compareSelectedID ?? "-") viewer=\(describeViewer(store)) revert=\(store.viewer.canRevertHunks)\n".utf8))
            }
        case "quickstate":
            FileHandle.standardError.write(Data("quick: scope=\(store.quickOpen.scope) query=\(store.quickOpen.query.debugDescription) items=\(store.quickOpen.items.prefix(12).map(\.id)) selected=\(store.quickOpen.selected)\n".utf8))
        case "quicktype": store.quickOpen.query = argument
        case "quickpick": store.quickOpen.activate(Int(argument))
        // Dialogs
        case "dialogok": store.answerDialog(confirmed: true)
        case "dialogcancel": store.answerDialog(confirmed: false)
        case "dialogsubmit": store.answerDialog(confirmed: true, text: argument)
        case "dialogalt": store.answerDialogAlternate()
        case "dialogchoice": store.pickDialogChoice(Int(argument) ?? 0)
        case "dialogtoggle": store.toggleDialogOption()
        case "dialogstate":
            if let dialog = store.dialog {
                let problem = dialog.input.map { $0.problem(argument) ?? "ok" } ?? "-"
                FileHandle.standardError.write(Data("dialog: title=\(dialog.title.debugDescription) message=\(dialog.message.debugDescription) items=\(dialog.items.map(\.title)) confirm=\(dialog.confirmTitle) alternate=\(dialog.alternateTitle ?? "-") input=\(dialog.input != nil) problem(\(argument))=\(problem) choices=\(dialog.choices.map(\.title)) choice=\(dialog.choice) option=\(dialog.option.map { "\($0.title)=\($0.isOn)" } ?? "-") output=\((dialog.output ?? "-").prefix(300).debugDescription)\n".utf8))
            } else {
                FileHandle.standardError.write(Data("dialog: none\n".utf8))
            }
        // Branches and remotes
        case "fetch": store.fetch()
        case "pull":
            store.pull(mode: argument == "merge" ? .merge : argument == "rebase" ? .rebase : .configured)
        case "push": store.push()
        case "newbranch": store.newBranch(from: argument.isEmpty ? nil : argument, startTitle: argument.isEmpty ? nil : argument)
        case "checkout":
            // "checkout:refs/heads/feature", "checkout:refs/remotes/origin/x", "checkout:refs/tags/v1"
            guard let project = store.currentProject else { break }
            Task { @MainActor in
                guard let ref = ((try? await Git.refs(in: project.url)) ?? []).first(where: { $0.name == argument }) else {
                    FileHandle.standardError.write(Data("checkout: no ref \(argument)\n".utf8))
                    return
                }
                store.checkout(ref, in: project)
            }
        case "checkoutrev": store.checkoutRevision(argument, title: String(argument.prefix(7)))
        case "continueop": store.continueOperation()
        case "abortop": store.abortOperation()
        case "skipop": store.skipOperation()
        // Stash
        case "stash": store.stashChanges()
        case "stashes": store.showStashes()
        case "stashapply", "stashpop", "stashdrop":
            // Acts on the stash the list shows.
            guard let project = store.currentProject, let entry = project.comparison?.stash else {
                FileHandle.standardError.write(Data("stash: none shown\n".utf8))
                break
            }
            switch parts[0] {
            case "stashdrop": store.dropStash(entry, in: project)
            default: store.applyStash(entry, drop: parts[0] == "stashpop", in: project)
            }
        case "stashstate":
            guard let project = store.currentProject else { break }
            Task { @MainActor in
                let list = await Git.stashes(in: project.url)
                FileHandle.standardError.write(Data("stash: list=\(list.map { "\($0.name)=\($0.title)\($0.untracked != nil ? "+u" : "")" }) shown=\(project.comparison?.stash?.name ?? "-") files=\(project.compareChanges.map { "\($0.kind.letter) \($0.path)" }) changes=\(project.changes.map { "\($0.kind.letter) \($0.path)" }) toast=\(store.toast ?? "-")\n".utf8))
            }
        case "toastaction":
            // The toast's button ("Undo"), as if clicked.
            if let action = store.toastAction {
                store.dismissToast()
                action.handler()
            } else {
                FileHandle.standardError.write(Data("toastaction: none\n".utf8))
            }
        case "branchmenu", "branchmenuitem":
            // "branchmenu:refs/heads/x" prints a branch's right-click menu in the Git graph;
            // "branchmenuitem:refs/heads/x|<title prefix>" runs one of its items.
            let bits = argument.split(separator: "|", maxSplits: 1).map(String.init)
            guard let project = store.currentProject, let name = bits.first else { break }
            Task { @MainActor in
                let refs = (try? await Git.refs(in: project.url)) ?? []
                guard let ref = refs.first(where: { $0.name == name }) else {
                    FileHandle.standardError.write(Data("branchmenu: no ref \(name)\n".utf8))
                    return
                }
                let model = store.gitGraph
                if model.projectID != project.id { model.prepare(for: project) }
                guard let menu = model.branchMenu(for: .init(id: "ref:" + ref.name, kind: .ref(ref))) else { return }
                if bits.count == 2 {
                    if let item = menu.items.first(where: { $0.title.hasPrefix(bits[1]) }), item.isEnabled, let action = item.action {
                        NSApp.sendAction(action, to: item.target, from: item)
                    } else {
                        FileHandle.standardError.write(Data("branchmenu: no enabled item \(bits[1])\n".utf8))
                    }
                } else {
                    let titles = menu.items.map { $0.isSeparatorItem ? "—" : ($0.isEnabled ? $0.title : "(\($0.title))") }
                    FileHandle.standardError.write(Data("branchmenu: \(titles)\n".utf8))
                }
            }
        case "resolve":
            // "resolve:a.txt|ours", "|theirs", "|mark"
            let bits = argument.split(separator: "|").map(String.init)
            guard bits.count == 2, let project = store.currentProject else { break }
            switch bits[1] {
            case "ours": store.takeSide(.ours, path: bits[0], in: project)
            case "theirs": store.takeSide(.theirs, path: bits[0], in: project)
            default: store.markResolved(bits[0], in: project)
            }
        case "conflictpick":
            // "conflictpick:0|theirs": a conflict's button, as if clicked.
            let bits = argument.split(separator: "|").map(String.init)
            guard bits.count == 2, let index = Int(bits[0]) else { break }
            store.viewer.resolveConflict(index, choice: bits[1] == "ours" ? .ours : bits[1] == "both" ? .both : .theirs)
        case "conflictbase":
            guard let project = store.currentProject, let base = ConflictBase(rawValue: argument) else { break }
            project.conflictBase = base
            store.syncViewer()
        case "conflictstate":
            let viewer = store.viewer
            let blocks = ConflictBlock.find(in: viewer.document?.right.lines ?? [])
            FileHandle.standardError.write(Data("conflict: shows=\(viewer.showsConflicts) count=\(viewer.conflictCount) blocks=\(blocks.map { "\($0.start)-\($0.end)" }) left=\(viewer.document?.leftTitle ?? "-") right=\(viewer.document?.rightTitle ?? "-") viewer=\(describeViewer(store)) dirty=\(viewer.isDirty)\n".utf8))
        case "openmerge":
            store.openThreeWayMerge(in: store.currentProject, focusing: argument.isEmpty ? nil : argument)
        case "mergeapplynonconflict":
            let filter: MergeSide? = argument == "left" ? .left : argument == "right" ? .right : nil
            _ = store.mergeSession?.applyAllNonConflicting(sideFilter: filter)
        case "mergeaccept", "mergeignore":
            let bits = argument.split(separator: "|").map(String.init)
            if bits.count == 2, let idx = Int(bits[0]), let side = MergeSide(rawValue: bits[1]) {
                if parts[0] == "mergeaccept" {
                    store.mergeSession?.acceptSide(side, chunk: idx)
                } else {
                    store.mergeSession?.ignoreSide(side, chunk: idx)
                }
            }
        case "mergeresolve":
            let bits = argument.split(separator: "|").map(String.init)
            if bits.count == 2, let idx = Int(bits[0]) {
                let choice: ConflictResolutionChoice?
                switch bits[1] {
                case "left": choice = .acceptLeft
                case "right": choice = .acceptRight
                case "bothLR": choice = .acceptBothLeftFirst
                case "bothRL": choice = .acceptBothRightFirst
                case "base": choice = .keepBase
                default: choice = nil
                }
                if let choice { store.mergeSession?.resolveConflict(idx, choice: choice) }
            }
        case "mergeundo": store.mergeSession?.undo()
        case "mergeredo": store.mergeSession?.redo()
        case "mergeapply": store.mergeSession?.applyCurrentFile(force: argument != "confirm")
        case "mergeclose": store.closeMergeSession(rememberDismissal: true)
        case "mergestate":
            let session = store.mergeSession
            let doc = session?.currentDocument
            let filesList = session?.files.map { "\($0.path):\($0.isResolved ? "ok" : "open")" } ?? []
            let titlesText = doc.map { "\($0.titles.left)|\($0.titles.center)|\($0.titles.right)" } ?? "-"
            FileHandle.standardError.write(Data("merge: open=\(session != nil) file=\(session?.selectedPath ?? "-") files=\(filesList) chunks=\(doc?.chunks.count ?? -1) unresolvedConflicts=\(doc?.unresolvedConflictCount ?? -1) unresolvedNonConflicts=\(doc?.unresolvedNonConflictCount ?? -1) canUndo=\(session?.canUndo ?? false) canRedo=\(session?.canRedo ?? false) titles=\(titlesText) toast=\(store.toast ?? "-")\n".utf8))
        case "opstate":
            if let project = store.currentProject {
                let s = project.status
                let conflicted = s.changes.filter { $0.kind == .conflicted }.map(\.path)
                FileHandle.standardError.write(Data("op: branch=\(s.branch ?? "detached") head=\(s.shortHead) upstream=\(s.upstream ?? "-") ahead=\(s.ahead) behind=\(s.behind) operation=\(s.operation?.rawValue ?? "-") conflicts=\(conflicted) activity=\(project.activity ?? "-") changes=\(s.changes.map { "\($0.kind.letter) \($0.path)" }) message=\(project.commitMessage.prefix(60).debugDescription) toast=\(store.toast ?? "-")\n".utf8))
            }
        case "closeterm":
            if let project = store.currentProject, let session = store.terminals.active(for: project) { store.terminals.close(session) }
        case "aboutsnap":
            // "aboutsnap:/out.png|/path/DiffCode.app": opens the About panel, with the licenses of that built app, and
            // saves a picture of it (it is a window of its own, which the window snapshot does not show).
            let bits = argument.split(separator: "|", maxSplits: 1).map(String.init)
            guard let out = bits.first else { break }
            let bundle = bits.count > 1 ? Bundle(url: URL(fileURLWithPath: bits[1])) ?? .main : .main
            NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "DiffCode", .credits: Acknowledgements.credits(in: bundle)])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let panel = NSApp.windows.first(where: { $0.isVisible && $0 !== store.window && $0 is NSPanel }),
                      let view = panel.contentView?.superview ?? panel.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    FileHandle.standardError.write(Data("aboutsnap: no panel\n".utf8))
                    return
                }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                FileHandle.standardError.write(Data("aboutsnap: \(Int(view.bounds.width))x\(Int(view.bounds.height))\n".utf8))
            }
        case "quit": NSApp.terminate(nil)
        case "backdrop":
            // "backdrop:FFFFFF": a plain window of that colour right behind the main one, standing in for a bright
            // wallpaper or window, to see what the translucent parts of the window pick up.
            guard let window = store.window, let hex = UInt32(argument, radix: 16) else { break }
            let backdrop = NSWindow(contentRect: window.frame.insetBy(dx: -40, dy: -40), styleMask: .borderless, backing: .buffered, defer: false)
            backdrop.backgroundColor = NSColor(hex: hex)
            backdrop.isReleasedWhenClosed = false
            backdrop.order(.below, relativeTo: window.windowNumber)
        case "click", "doubleclick":
            // "click:x,y" in window points from the top-left: a real left click, queued as the mouse would queue it.
            // Only reaches a window that is key, which a launched test run is. "doubleclick:x,y" clicks twice.
            guard let window = store.window, let content = window.contentView else { break }
            let xy = argument.split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2 else { break }
            let location = NSPoint(x: xy[0], y: content.bounds.height - xy[1])
            for count in parts[0] == "doubleclick" ? [1, 2] : [1] {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
            }
        case "move":
            // "move:x,y" in window points from the top-left: the pointer moves there, for hover effects.
            guard let window = store.window, let content = window.contentView else { break }
            let xy = argument.split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2 else { break }
            let location = NSPoint(x: xy[0], y: content.bounds.height - xy[1])
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                NSApp.postEvent(event, atStart: false)
            }
        case "rightclick":
            // "rightclick:x,y" in window points from the top-left: a real right-click, queued as the mouse would
            // queue it. The menu it opens is listed on stderr and closed again.
            guard let window = store.window, let content = window.contentView else { break }
            let xy = argument.split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2 else { break }
            let location = NSPoint(x: xy[0], y: content.bounds.height - xy[1])
            let observer = MenuObserver()
            observer.token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
                // Menus begin tracking on the main thread, and the timer below fires there too.
                nonisolated(unsafe) let menu = note.object as? NSMenu
                MainActor.assumeIsolated {
                    guard let menu else { return }
                    if let token = observer.token { NotificationCenter.default.removeObserver(token) }
                    let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
                    FileHandle.standardError.write(Data("menu: \(titles)\n".utf8))
                    // The menu runs its own event loop; a delayed perform in the common modes still fires inside it.
                    menu.perform(#selector(NSMenu.cancelTrackingWithoutAnimation), with: nil, afterDelay: 0.2, inModes: [.common])
                }
            }
            if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                NSApp.postEvent(event, atStart: false)
            }
        // Editing
        case "savedelay": ViewerModel.saveDelay = Double(argument) ?? 1
        case "assumekey":
            CodeCanvasView.assumeKeyWindow = true
            store.viewer.container?.canvas.needsDisplay = true
        case "menustate":
            // "menustate:Redo": the menu item with that title (in either language), as validation leaves it.
            for top in NSApp.mainMenu?.items ?? [] {
                guard let menu = top.submenu else { continue }
                menu.update()
                for item in menu.items where item.title == argument || item.title.hasPrefix(argument) {
                    FileHandle.standardError.write(Data("menuitem: \(item.title) enabled=\(item.isEnabled) key=\(item.keyEquivalent.debugDescription) mask=\(item.keyEquivalentModifierMask.rawValue) action=\(item.action.map(NSStringFromSelector) ?? "-")\n".utf8))
                }
            }
        case "sendaction":
            // "sendaction:redo:" down the responder chain, as a menu item with no target would.
            let handled = NSApp.sendAction(NSSelectorFromString(argument), to: nil, from: nil)
            FileHandle.standardError.write(Data("sendaction \(argument): \(handled)\n".utf8))
        case "caret":
            // "caret:12:4": the caret on line 12 (1-based), column 4 (0-based, UTF-16).
            let v = argument.split(separator: ":").compactMap { Int($0) }
            if let canvas = store.viewer.container?.canvas, let line = v.first {
                canvas.placeCaret(line: line - 1, column: v.count > 1 ? v[1] : 0)
            }
        case "typetext":
            // Typed through the text input client, one character at a time; "\n" is Return, "\t" is Tab.
            // Each character is redrawn before the next, as typing would be; prints the mean and the slowest.
            guard let canvas = store.viewer.container?.canvas else { break }
            canvas.flush()
            var total = 0.0, slowest = 0.0, count = 0, slowestAt = 0
            for character in unescape(argument) {
                let started = CACurrentMediaTime()
                switch character {
                case "\n": canvas.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                case "\t": canvas.doCommand(by: #selector(NSResponder.insertTab(_:)))
                default: canvas.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
                }
                canvas.flush()
                let elapsed = (CACurrentMediaTime() - started) * 1000
                total += elapsed
                if elapsed > slowest { slowest = elapsed; slowestAt = count + 1 }
                count += 1
            }
            FileHandle.standardError.write(Data(String(format: "typed %d chars: %.2f ms each, slowest %.2f ms (#%d) (each redrawn)\n", count, total / Double(max(1, count)), slowest, slowestAt).utf8))
        case "keytext":
            // Real key events carrying these characters, through the event queue and the input system.
            for character in unescape(argument) { postCharacter(character, window: store.window) }
        case "cmd":
            // "cmd:deleteWordBackward:" sends a standard text command to the diff.
            store.viewer.container?.canvas.doCommand(by: NSSelectorFromString(argument))
        case "marked":
            // An input method's composition, e.g. "marked:ni" then "marked:你".
            let text = unescape(argument)
            store.viewer.container?.canvas.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                                                         replacementRange: NSRange(location: NSNotFound, length: 0))
        case "commitmarked":
            // The input method commits its composition as `argument`.
            store.viewer.container?.canvas.insertText(unescape(argument), replacementRange: NSRange(location: NSNotFound, length: 0))
        case "unmark": store.viewer.container?.canvas.unmarkText()
        case "fieldmarked":
            // An input method's composition in the text field that has the keyboard (its field editor).
            let text = unescape(argument)
            guard let editor = store.window?.firstResponder as? NSTextView else { FileHandle.standardError.write(Data("fieldmarked: no field editor\n".utf8)); break }
            editor.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
        case "fieldtype":
            // "fieldtype:你|hao": the input method commits the first part, and straight away starts composing the
            // second, as typing 你 then h, a, o does.
            guard let editor = store.window?.firstResponder as? NSTextView else { break }
            let pieces = unescape(argument).split(separator: "|", maxSplits: 1).map(String.init)
            editor.insertText(pieces[0], replacementRange: NSRange(location: NSNotFound, length: 0))
            if pieces.count > 1 {
                editor.setMarkedText(pieces[1], selectedRange: NSRange(location: (pieces[1] as NSString).length, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        case "fieldcommit":
            guard let editor = store.window?.firstResponder as? NSTextView else { break }
            editor.insertText(unescape(argument), replacementRange: NSRange(location: NSNotFound, length: 0))
        case "fieldstate":
            let editor = store.window?.firstResponder as? NSTextView
            FileHandle.standardError.write(Data(("fieldstate text=\(editor?.string ?? "-") marked=\(editor?.hasMarkedText() ?? false) " +
                "range=\(editor.map { NSStringFromRange($0.markedRange()) } ?? "-") field=\((editor?.delegate as? NSTextField)?.stringValue ?? "-") hits=\(store.finder.hits.count) finder=\(store.finder.query) responder=\(store.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") popup=\(String(describing: store.popup))\n").utf8))
        case "save": store.viewer.saveNow()
        case "editundo": store.viewer.container?.canvas.undoTyping()
        case "editredo": store.viewer.container?.canvas.redoTyping()
        case "privateclipboard":
            // Cut, copy and paste go to a pasteboard of the tests' own, never the user's clipboard.
            let board = NSPasteboard(name: NSPasteboard.Name("app.dif.tests"))
            board.clearContents()
            if !argument.isEmpty { board.setString(unescape(argument), forType: .string) }
            store.viewer.container?.canvas.pasteboard = board
        case "clipboard":
            let text = store.viewer.container?.canvas.pasteboard.string(forType: .string)
            FileHandle.standardError.write(Data("clipboard: \(text?.debugDescription ?? "nil") private=\(store.viewer.container?.canvas.pasteboard != NSPasteboard.general)\n".utf8))
        case "editstate":
            let viewer = store.viewer
            let canvas = viewer.container?.canvas
            let caret = canvas?.editSelection.map { "\($0.anchor.row + 1):\($0.anchor.column)-\($0.head.row + 1):\($0.head.column)" } ?? "-"
            let editor = viewer.editor
            FileHandle.standardError.write(Data("edit: editable=\(editor != nil) dirty=\(viewer.isDirty) version=\(editor?.version ?? -1) hasEdits=\(editor?.hasEdits ?? false) undo=\(editor?.canUndo ?? false) redo=\(editor?.canRedo ?? false) marked=\(editor?.marked.map { "\($0.row + 1):\($0.range)" } ?? "-") caret=\(caret) hunks=\(viewer.document?.hunks.map { "\($0.leftStart),\($0.leftCount)>\($0.rightStart),\($0.rightCount)" }.joined(separator: " ") ?? "-") lines=\(viewer.document?.right.lines.count ?? -1) readOnly=\(viewer.readOnlyReason ?? "-") note=\(viewer.document?.note ?? "-") focus=\(store.window?.firstResponder === canvas) key=\(store.window?.isKeyWindow ?? false) caretShown=\(canvas?.isCaretShown ?? false) caretRect=\(canvas.map { $0.caretRect.isNull ? "-" : "\(Int($0.caretRect.minX)),\(Int($0.caretRect.minY))" } ?? "-") file=\(viewer.request?.path ?? "-") kind=\(viewer.request?.kind.map { "\($0)" } ?? "-") toast=\(store.toast ?? "-")\n".utf8))
        case "linetext":
            let lines = store.viewer.document?.right.lines ?? []
            let index = (Int(argument) ?? 1) - 1
            FileHandle.standardError.write(Data("line \(index + 1): \(lines.indices.contains(index) ? lines[index].debugDescription : "<none>")\n".utf8))
        case "writefile":
            // "writefile:path|content": another program writes the file.
            let pieces = argument.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if let project = store.currentProject, pieces.count == 2 {
                try? Data(unescape(pieces[1]).utf8).write(to: project.url.appendingPathComponent(pieces[0]))
            }
        case "chmod":
            // "chmod:path|444": the file's permissions change, e.g. so that writing it fails.
            let pieces = argument.split(separator: "|").map(String.init)
            if let project = store.currentProject, pieces.count == 2, let mode = Int(pieces[1], radix: 8) {
                try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: project.url.appendingPathComponent(pieces[0]).path)
            }
        case "filehex":
            if let project = store.currentProject {
                let url = project.url.appendingPathComponent(argument)
                let data = (try? Data(contentsOf: url)) ?? Data()
                let mode = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int).map { String($0, radix: 8) } ?? "-"
                FileHandle.standardError.write(Data("hex \(argument): \(data.count) bytes mode=\(mode) \(data.prefix(200).map { String(format: "%02x", $0) }.joined())\n".utf8))
            }
        case "filestate":
            if let project = store.currentProject {
                let data = (try? Data(contentsOf: project.url.appendingPathComponent(argument))) ?? Data()
                FileHandle.standardError.write(Data("file \(argument): \(data.count) bytes \(String(decoding: data.prefix(400), as: UTF8.self).debugDescription)\n".utf8))
            }
        default: FileHandle.standardError.write(Data("unknown action \(action)\n".utf8))
        }
    }

    /// "\n", "\t" and "\\" written out in an action's argument.
    /// "g.txt worktree(HEAD) HEAD→Working Tree hunks=2" — what the viewer shows.
    private static func describeViewer(_ store: AppStore) -> String {
        guard let request = store.viewer.request else { return "-" }
        let source: String
        switch request.source {
        case .file: source = "file"
        case .externalFile(let display, _): source = "external(\(display))"
        case .worktree(let base): source = "worktree(\(base.prefix(7)))"
        case .commit(let hash, let parent): source = "commit(\(hash.prefix(7))<-\(parent?.prefix(7) ?? "root"))"
        case .commitSteps(let steps):
            let first = steps.first?.hash.prefix(7) ?? "-"
            let last = steps.last?.hash.prefix(7) ?? "-"
            source = "commitSteps(\(steps.count):\(first)..\(last))"
        }
        let doc = store.viewer.document
        return "\(request.path) \(source) \(doc?.leftTitle ?? "")→\(doc?.rightTitle ?? "") hunks=\(store.viewer.hunkCount)"
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\s", with: ";")
    }

    /// A key press that types `character`, as a physical key on any layout would.
    private static func postCharacter(_ character: Character, window: NSWindow?) {
        let special: [Character: UInt16] = ["\n": 36, "\t": 48, " ": 49]
        guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: special[character] ?? 0, keyDown: true) else { return }
        if special[character] == nil {
            let units = Array(String(character).utf16)
            cg.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        if let event = NSEvent(cgEvent: cg) { NSApp.postEvent(event, atStart: false) }
    }

    /// Posts a key press into the event queue, e.g. "F7", "shift+cmd+]", "alt+cmd+v".
    private static func postKey(_ spec: String, window: NSWindow?) {
        // name -> (key code, characters ignoring modifiers, shifted form)
        let keys: [String: (UInt16, String, String)] = [
            "f": (3, "f", "F"), "o": (31, "o", "O"), "a": (0, "a", "A"), "e": (14, "e", "E"), "l": (37, "l", "L"),
            "v": (9, "v", "V"), "w": (13, "w", "W"), "d": (2, "d", "D"), "c": (8, "c", "C"), "r": (15, "r", "R"),
            "g": (5, "g", "G"), "0": (29, "0", ")"), "9": (25, "9", "("), "1": (18, "1", "!"),
            "]": (30, "]", "}"), "[": (33, "[", "{"), "/": (44, "/", "?"), ".": (47, ".", ">"), ",": (43, ",", "<"),
            "f7": (98, "\u{F70A}", "\u{F70A}"), "f4": (118, "\u{F707}", "\u{F707}"), "f12": (111, "\u{F70F}", "\u{F70F}"),
            "esc": (53, "\u{1B}", "\u{1B}"), "down": (125, "\u{F701}", "\u{F701}"), "return": (36, "\r", "\r"),
            "up": (126, "\u{F700}", "\u{F700}"), "left": (123, "\u{F702}", "\u{F702}"), "right": (124, "\u{F703}", "\u{F703}"),
            "f1": (122, "\u{F704}", "\u{F704}"), "t": (17, "t", "T"), "k": (40, "k", "K"), "s": (1, "s", "S"),
            "m": (46, "m", "M"), "n": (45, "n", "N"), "i": (34, "i", "I"),
            "z": (6, "z", "Z"), "b": (11, "b", "B"), "space": (49, " ", " "), "tab": (48, "\t", "\t"),
            "home": (115, "\u{F729}", "\u{F729}"), "end": (119, "\u{F72B}", "\u{F72B}"),
            "pageup": (116, "\u{F72C}", "\u{F72C}"), "pagedown": (121, "\u{F72D}", "\u{F72D}"),
            "delete": (51, "\u{7F}", "\u{7F}"), "fwddelete": (117, "\u{F728}", "\u{F728}"),
            "h": (4, "h", "H"), "j": (38, "j", "J"), "p": (35, "p", "P"), "q": (12, "q", "Q"), "u": (32, "u", "U"),
            "x": (7, "x", "X"), "y": (16, "y", "Y"),
        ]
        var flags: NSEvent.ModifierFlags = []
        var name = ""
        for part in spec.lowercased().split(separator: "+") {
            switch part {
            case "shift": flags.insert(.shift)
            case "cmd": flags.insert(.command)
            case "alt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: name = String(part)
            }
        }
        guard let key = keys[name] else {
            FileHandle.standardError.write(Data("unknown key \(spec)\n".utf8))
            return
        }
        // Built from a CGEvent so the characters come from the real keyboard layout, exactly as
        // they would for a physical key press; hand-written characters do not match reliably.
        var cgFlags: CGEventFlags = []
        if flags.contains(.shift) { cgFlags.insert(.maskShift) }
        if flags.contains(.command) { cgFlags.insert(.maskCommand) }
        if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if flags.contains(.control) { cgFlags.insert(.maskControl) }
        if name.hasPrefix("f") && name.count > 1 || ["down", "up", "left", "right", "home", "end", "pageup", "pagedown"].contains(name) { cgFlags.insert(.maskSecondaryFn) }
        guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: key.0, keyDown: true) else { return }
        cg.flags = cgFlags
        if let event = NSEvent(cgEvent: cg) {
            FileHandle.standardError.write(Data("key \(spec): chars=\(event.characters?.debugDescription ?? "nil") unmod=\(event.charactersIgnoringModifiers?.debugDescription ?? "nil")\n".utf8))
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// Renders the window's layer tree. The canvas is made of layers, which `cacheDisplay` cannot see.
    private static func write(window: NSWindow, to path: String) {
        window.displayIfNeeded()
        CATransaction.flush()
        if ProcessInfo.processInfo.environment["DIF_SNAPSHOT_SCREEN"] != nil, let image = captureScreen(window) {
            save(image, to: path)
            return
        }
        guard let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { return }
        let scale = window.backingScaleFactor
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        if let image = ctx.makeImage() { save(image, to: path) }
    }

    private static func save(_ image: CGImage, to path: String) {
        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// The window as the window server composited it. Only works where the system lets a
    /// process read back its own window without the Screen Recording permission.
    private static func captureScreen(_ window: NSWindow) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        // optionIncludingWindow = 8; boundsIgnoreFraming | bestResolution = 9
        return capture(.null, 8, UInt32(window.windowNumber), 9)?.takeRetainedValue()
    }

    /// Measures what a scroll step costs: first as page-sized jumps across the whole document
    /// (every step rasterises a fresh viewport), then as a smooth 30 pt-per-frame scroll.
    private static func benchmark(store: AppStore) {
        guard let container = store.viewer.container, let doc = store.viewer.document else {
            print("bench: no document")
            return
        }
        let canvas = container.canvas
        let total = CGFloat(canvas.rowCount) * canvas.codeFont.lineHeight
        print(String(format: "bench: lines L=%d R=%d hunks=%d load=%.1fms view=%dx%d",
                     doc.left.lines.count, doc.right.lines.count, doc.hunks.count, doc.loadMilliseconds,
                     Int(canvas.bounds.width), Int(canvas.bounds.height)))

        func run(_ label: String, steps: Int, offset: (Int) -> CGFloat) {
            var samples: [Double] = []
            let before = canvas.tilesRasterised
            for step in 0..<steps {
                // One "frame": a pool and a commit, as a turn of the run loop would give us.
                autoreleasepool {
                    container.scroll(toY: offset(step), animated: false)
                    canvas.flush()
                    samples.append(canvas.lastUpdateMilliseconds)
                    CATransaction.flush()
                }
            }
            samples.sort()
            let mean = samples.reduce(0, +) / Double(samples.count)
            print(String(format: "bench %@: mean=%.2fms p50=%.2fms p95=%.2fms max=%.2fms tiles=%d mem=%.0fMB",
                         label, mean, samples[samples.count / 2], samples[Int(Double(samples.count) * 0.95)],
                         samples.last ?? 0, canvas.tilesRasterised - before, AppStore.footprintMB()))
        }
        run("jump", steps: 400) { total * CGFloat($0) / 400 }
        run("smooth", steps: 600) { CGFloat($0) * 30 }

        // Reading both versions, diffing, highlighting and word-diffing, from scratch each time.
        if let request = store.viewer.request {
            Task {
                var times: [String] = []
                for _ in 0..<5 {
                    let started = CACurrentMediaTime()
                    _ = await DiffLoader.load(request)
                    times.append(String(format: "%.1f", (CACurrentMediaTime() - started) * 1000))
                }
                print("bench load: \(times.joined(separator: " ")) ms")
            }
        }
    }
}
#endif
