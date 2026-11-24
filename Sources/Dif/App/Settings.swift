import AppKit
import Observation

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    static let uiFontRange: ClosedRange<Double> = 11...17
    static let terminalFontRange: ClosedRange<Double> = 9...24
    static let stickyLinesRange: ClosedRange<Int> = 1...10
    /// The sidebar holds the project list and the file tree, so it may grow wider than a plain source list.
    static let sidebarRange: ClosedRange<Double> = 200...480
    /// The commit message box, including its button row; dragged by the line above it.
    static let commitBoxRange: ClosedRange<Double> = 96...640
    /// Default prompt template describing the commit message format for AI generation.
    nonisolated static let defaultCommitMessageFormat = """
    ## 提交格式
    提交的信息格式为：`[EMOJI] [TYPE](topic): [description in {locale}]`。
    - **Emoji**: 使用 GitMoji（例如 ✨ `feat`, 📖 `docs`, 🐛 `fix`）。
    - **Type**: 常见的类型包括 `feature`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`。
    - **Topic**: 
      - 某个功能名字。
      - 英文名，通常使用代码中的函数名字（如果只改了一个函数）。
      - 功能配置的交集名字。
      - 文件名。
    - **Description**: 说明文本使用 **中文**，描述具体的改动。
    """

    enum Appearance: String, CaseIterable {
        case system, light, dark

        var title: String {
            switch self {
            case .system: return L("System", "跟随系统")
            case .light: return L("Light", "浅色")
            case .dark: return L("Dark", "深色")
            }
        }
    }

    /// The app's own defaults domain: its bundle identifier, or the executable's name for a bare build.
    nonisolated static let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName

    /// The interface language. It is kept where macOS keeps an app's own language, `AppleLanguages` in the app's
    /// defaults (System Settings ▸ General ▸ Language & Region ▸ Applications writes the same key), so what macOS
    /// and Sparkle draw follows it too. The interface reads it once, at launch: a change shows after a restart.
    enum Language: String, CaseIterable {
        case system, english, chinese

        static let key = "AppleLanguages"

        /// Language names are written in their own language, so people find theirs whatever the interface shows.
        var title: String {
            switch self {
            case .system: return L("System", "跟随系统")
            case .english: return "English"
            case .chinese: return "简体中文"
            }
        }

        /// What the app's `AppleLanguages` holds for this choice; nothing means the system's languages apply.
        var appleLanguages: [String]? {
            switch self {
            case .system: return nil
            case .english: return ["en"]
            case .chinese: return ["zh-Hans"]
            }
        }

        /// The choice an app's own `AppleLanguages` stands for. DiffCode shows English for every language but
        /// Chinese, so that is what the others count as.
        init(appleLanguages: [String]?) {
            guard let first = appleLanguages?.first else {
                self = .system
                return
            }
            self = first.hasPrefix("zh") ? .chinese : .english
        }

        /// Whether the interface is in Chinese with this choice, given the system's own languages.
        func isChinese(system: [String]) -> Bool {
            switch self {
            case .system: return system.first?.hasPrefix("zh") ?? false
            case .english: return false
            case .chinese: return true
            }
        }

        /// The choice saved in the app's own domain. Not `defaults.object(forKey:)`, which falls back to the
        /// system's list and would make following the system look like a choice.
        static func stored(in defaults: UserDefaults = .standard, domain: String = Settings.domain) -> Language {
            Language(appleLanguages: defaults.persistentDomain(forName: domain)?[key] as? [String])
        }

        func store(in defaults: UserDefaults = .standard) {
            if let languages = appleLanguages {
                defaults.set(languages, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }

        /// The system's languages, leaving out the app's own choice.
        static var systemLanguages: [String] {
            CFPreferencesCopyAppValue(key as CFString, kCFPreferencesAnyApplication) as? [String] ?? []
        }
    }

    var appearance: Appearance
    /// The language chosen in Settings. What this launch shows is `Localization.isChinese`.
    var language: Language
    var fontSize: Double
    /// Size of interface text (lists, headers, popups). Everything in the chrome scales from this.
    var uiFontSize: Double
    var terminalFontSize: Double
    /// Font families picked for code and for terminals; nil is the default face (see `MonospaceFonts`).
    var codeFontFamily: String?
    /// GoLand-style typography settings for the code canvas.
    var codeFontMainWeight: CodeFontWeight
    var codeFontBoldWeight: CodeFontWeight
    var codeFontLigatures: Bool
    var terminalFontFamily: String?
    var unified: Bool
    var ignoreWhitespace: Bool
    /// Semantic diff toggles (used by semantic diff engine & viewer toolbar).
    var ignoreComments: Bool
    var normalizeJSON: Bool
    var detectMoves: Bool
    var detectRenames: Bool
    var collapseUnchanged: Bool
    var flatList: Bool
    var sidebarWidth: Double
    var listWidth: Double
    var terminalHeight: Double
    var commitBoxHeight: Double
    /// How tall the projects may grow above the file tree, as the user dragged it; nil is automatic.
    var projectsHeight: Double?
    /// Keep the file tree's selection on whatever file the viewer is showing.
    var followFile: Bool
    /// Enable Vim keybindings in the code viewer/editor (`~/.ideavimrc`-compatible).
    var vimMode: Bool
    /// Show relative line numbers in the code gutter when Vim mode is enabled.
    var vimRelativeLineNumbers: Bool
    /// Custom Vim cursor color as `#RRGGBB` hex, or `nil` to follow the active theme's text color.
    var vimCursorColorHex: String?
    /// Pin enclosing function/type headers at the top of the code viewer while scrolling (GoLand Sticky Lines).
    var stickyLines: Bool
    /// Maximum number of sticky header lines pinned simultaneously.
    var stickyLinesMaxCount: Int
    /// Automatically run `go fmt` (`gofmt`) after saving a Go file.
    var formatGoOnSave: Bool
    /// Show the Beyond Compare-style bottom inline line diff bar under the code viewer.
    var showLineDiffBar: Bool
    /// Automatically open the 3-way merge window whenever Git stops at merge/rebase/cherry-pick/stash conflicts.
    var autoOpenThreeWayMerge: Bool

    /// How cross-file LSP jumps open a target file that has Git changes.
    enum LSPJumpOpenMode: String, CaseIterable, Sendable {
        case file
        case diff

        var title: String {
            switch self {
            case .file: return L("Plain File", "纯文件")
            case .diff: return L("Diff", "Diff 对比")
            }
        }
    }

    /// Whether cross-file LSP jumps open changed target files as plain file content or as a diff.
    var lspJumpOpenMode: LSPJumpOpenMode

    /// How long an LSP server stays warm after switching away from its workspace before automatic shutdown.
    enum LSPIdleTimeout: Int, CaseIterable, Sendable {
        case minutes5 = 300
        case minutes15 = 900
        case minutes30 = 1800
        case hour1 = 3600
        case never = 0

        var duration: Duration? {
            rawValue > 0 ? .seconds(rawValue) : nil
        }

        var title: String {
            switch self {
            case .minutes5: return L("5 min", "5 分钟")
            case .minutes15: return L("15 min", "15 分钟")
            case .minutes30: return L("30 min", "30 分钟")
            case .hour1: return L("1 hour", "1 小时")
            case .never: return L("Never", "永不")
            }
        }
    }

    /// Idle release delay after leaving an LSP workspace (`never` keeps servers warm until quit).
    var lspIdleTimeout: LSPIdleTimeout
    /// Distinct local AI task roles that can independently select their provider and model.
    enum AITask: String, CaseIterable, Sendable {
        case commit
        case grouping
    }

    /// Selected local AI agent provider for Commit Message generation (Direct edition only).
    var aiCommitProvider: AgentProvider
    /// Preferred model ID per provider rawValue for Commit Message generation (`nil`/absent means provider default).
    var aiCommitModels: [String: String]
    /// Selected local AI agent provider for AI Hunk Grouping (Direct edition only).
    var aiGroupingProvider: AgentProvider
    /// Preferred model ID per provider rawValue for AI Hunk Grouping (`nil`/absent means provider default).
    var aiGroupingModels: [String: String]
    /// Customizable commit message format specification used for AI commit generation.
    var commitMessageFormat: String

    /// Legacy compatibility accessor pointing to the commit provider.
    var aiAgentProvider: AgentProvider {
        get { aiCommitProvider }
        set { aiCommitProvider = newValue }
    }

    /// The commit message format to send to AI, falling back to `defaultCommitMessageFormat` when empty.
    var effectiveCommitMessageFormat: String {
        commitMessageFormat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultCommitMessageFormat
            : commitMessageFormat
    }

    /// Returns the configured AI provider for `task`.
    func aiProvider(for task: AITask) -> AgentProvider {
        switch task {
        case .commit: return aiCommitProvider
        case .grouping: return aiGroupingProvider
        }
    }

    /// Persists the chosen AI provider for `task`.
    func setAIProvider(_ provider: AgentProvider, for task: AITask) {
        switch task {
        case .commit:
            guard aiCommitProvider != provider else { return }
            aiCommitProvider = provider
        case .grouping:
            guard aiGroupingProvider != provider else { return }
            aiGroupingProvider = provider
        }
        save()
    }

    /// Returns the persisted model identifier for `provider` and `task`, or `nil` to use the provider's default model.
    func aiModel(for provider: AgentProvider, task: AITask = .commit) -> String? {
        let map: [String: String]
        switch task {
        case .commit: map = aiCommitModels
        case .grouping: map = aiGroupingModels
        }
        guard let raw = map[provider.rawValue] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Persists the preferred model identifier for `provider` and `task` (`nil` or empty restores provider default).
    func setAIModel(_ model: String?, for provider: AgentProvider, task: AITask = .commit) {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty == false) ? trimmed : nil
        switch task {
        case .commit:
            if aiCommitModels[provider.rawValue] == normalized { return }
            if let normalized {
                aiCommitModels[provider.rawValue] = normalized
            } else {
                aiCommitModels.removeValue(forKey: provider.rawValue)
            }
        case .grouping:
            if aiGroupingModels[provider.rawValue] == normalized { return }
            if let normalized {
                aiGroupingModels[provider.rawValue] = normalized
            } else {
                aiGroupingModels.removeValue(forKey: provider.rawValue)
            }
        }
        save()
    }

    private static let aiCachedModelsKey = "aiCachedAgentModels"
    @ObservationIgnored private var aiCachedModels: [String: [AgentModel]] = [:]

    /// Returns the persisted model list last fetched for `provider`, or `[]` when never cached.
    func cachedAIModels(for provider: AgentProvider) -> [AgentModel] {
        aiCachedModels[provider.rawValue] ?? []
    }

    /// Persists a non-empty model list for `provider` so pickers populate immediately across launches.
    func setCachedAIModels(_ models: [AgentModel], for provider: AgentProvider) {
        guard !models.isEmpty, aiCachedModels[provider.rawValue] != models else { return }
        aiCachedModels[provider.rawValue] = models
        if let data = try? JSONEncoder().encode(aiCachedModels) {
            defaults.set(data, forKey: Self.aiCachedModelsKey)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // First launch is dark, as Android Studio's default theme is; a choice made in Settings is kept.
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .dark
        language = Language.stored(in: defaults)
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 12
        uiFontSize = min(Self.uiFontRange.upperBound, max(Self.uiFontRange.lowerBound, defaults.object(forKey: "uiFontSize") as? Double ?? 13))
        terminalFontSize = min(Self.terminalFontRange.upperBound,
                               max(Self.terminalFontRange.lowerBound, defaults.object(forKey: "terminalFontSize") as? Double ?? 12))
        codeFontFamily = defaults.string(forKey: "codeFontFamily").flatMap { $0.isEmpty ? nil : $0 }
        codeFontMainWeight = defaults.string(forKey: "codeFontMainWeight").flatMap(CodeFontWeight.init(rawValue:)) ?? .regular
        codeFontBoldWeight = defaults.string(forKey: "codeFontBoldWeight").flatMap(CodeFontWeight.init(rawValue:)) ?? .bold
        codeFontLigatures = defaults.object(forKey: "codeFontLigatures") as? Bool ?? true
        terminalFontFamily = defaults.string(forKey: "terminalFontFamily").flatMap { $0.isEmpty ? nil : $0 }
        unified = defaults.bool(forKey: "unified")
        ignoreWhitespace = defaults.bool(forKey: "ignoreWhitespace")
        ignoreComments = defaults.bool(forKey: "ignoreComments")
        normalizeJSON = defaults.bool(forKey: "normalizeJSON")
        detectMoves = defaults.object(forKey: "detectMoves") as? Bool ?? true
        detectRenames = defaults.object(forKey: "detectRenames") as? Bool ?? true
        collapseUnchanged = defaults.bool(forKey: "collapseUnchanged")
        flatList = defaults.bool(forKey: "flatList")
        let sidebar = defaults.object(forKey: "sidebarWidth") as? Double ?? 240
        sidebarWidth = min(Self.sidebarRange.upperBound, max(Self.sidebarRange.lowerBound, sidebar))
        listWidth = defaults.object(forKey: "listWidth") as? Double ?? 300
        terminalHeight = defaults.object(forKey: "terminalHeight") as? Double ?? 280
        commitBoxHeight = min(Self.commitBoxRange.upperBound,
                              max(Self.commitBoxRange.lowerBound, defaults.object(forKey: "commitBoxHeight") as? Double ?? 140))
        followFile = defaults.object(forKey: "followFile") as? Bool ?? false
        vimMode = defaults.object(forKey: "vimMode") as? Bool ?? true
        vimRelativeLineNumbers = defaults.object(forKey: "vimRelativeLineNumbers") as? Bool ?? false
        vimCursorColorHex = NSColor.normalizedHexColor(defaults.string(forKey: "vimCursorColor"))
        stickyLines = defaults.object(forKey: "stickyLines") as? Bool ?? true
        let maxSticky = defaults.object(forKey: "stickyLinesMaxCount") as? Int ?? StickyLinesEngine.defaultMaxLines
        stickyLinesMaxCount = min(Self.stickyLinesRange.upperBound, max(Self.stickyLinesRange.lowerBound, maxSticky))
        formatGoOnSave = defaults.object(forKey: "formatGoOnSave") as? Bool ?? true
        showLineDiffBar = defaults.object(forKey: "showLineDiffBar") as? Bool ?? true
        autoOpenThreeWayMerge = defaults.object(forKey: "autoOpenThreeWayMerge") as? Bool ?? true
        lspJumpOpenMode = LSPJumpOpenMode(rawValue: defaults.string(forKey: "lspJumpOpenMode") ?? "") ?? .file
        if let rawTimeout = defaults.object(forKey: "lspIdleTimeoutSeconds") as? Int,
           let parsedTimeout = LSPIdleTimeout(rawValue: rawTimeout) {
            lspIdleTimeout = parsedTimeout
        } else {
            lspIdleTimeout = .minutes15
        }
        let legacyProvider = AgentProvider(rawValue: defaults.string(forKey: "aiAgentProvider") ?? "") ?? .agy
        let legacyModels = defaults.dictionary(forKey: "aiAgentModels") as? [String: String] ?? [:]
        aiCommitProvider = AgentProvider(rawValue: defaults.string(forKey: "aiCommitProvider") ?? "") ?? legacyProvider
        aiCommitModels = defaults.dictionary(forKey: "aiCommitModels") as? [String: String] ?? legacyModels
        aiGroupingProvider = AgentProvider(rawValue: defaults.string(forKey: "aiGroupingProvider") ?? "") ?? legacyProvider
        aiGroupingModels = defaults.dictionary(forKey: "aiGroupingModels") as? [String: String] ?? legacyModels
        if let cachedData = defaults.data(forKey: Self.aiCachedModelsKey),
           let decoded = try? JSONDecoder().decode([String: [AgentModel]].self, from: cachedData) {
            aiCachedModels = decoded.filter { AgentProvider(rawValue: $0.key) != nil && !$0.value.isEmpty }
        }
        if let savedFormat = defaults.string(forKey: "commitMessageFormat"),
           !savedFormat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commitMessageFormat = savedFormat
        } else {
            commitMessageFormat = Self.defaultCommitMessageFormat
        }
        projectsHeight = (defaults.object(forKey: "projectsHeight") as? Double).map { max(0, $0) }
    }

    func save() {
        defaults.set(appearance.rawValue, forKey: "appearance")
        defaults.set(fontSize, forKey: "fontSize")
        defaults.set(uiFontSize, forKey: "uiFontSize")
        defaults.set(terminalFontSize, forKey: "terminalFontSize")
        defaults.set(codeFontFamily, forKey: "codeFontFamily")  // nil removes the key
        defaults.set(codeFontMainWeight.rawValue, forKey: "codeFontMainWeight")
        defaults.set(codeFontBoldWeight.rawValue, forKey: "codeFontBoldWeight")
        defaults.set(codeFontLigatures, forKey: "codeFontLigatures")
        defaults.set(terminalFontFamily, forKey: "terminalFontFamily")
        defaults.set(unified, forKey: "unified")
        defaults.set(ignoreWhitespace, forKey: "ignoreWhitespace")
        defaults.set(ignoreComments, forKey: "ignoreComments")
        defaults.set(normalizeJSON, forKey: "normalizeJSON")
        defaults.set(detectMoves, forKey: "detectMoves")
        defaults.set(detectRenames, forKey: "detectRenames")
        defaults.set(collapseUnchanged, forKey: "collapseUnchanged")
        defaults.set(flatList, forKey: "flatList")
        defaults.set(sidebarWidth, forKey: "sidebarWidth")
        defaults.set(listWidth, forKey: "listWidth")
        defaults.set(terminalHeight, forKey: "terminalHeight")
        defaults.set(commitBoxHeight, forKey: "commitBoxHeight")
        defaults.set(followFile, forKey: "followFile")
        defaults.set(vimMode, forKey: "vimMode")
        defaults.set(vimRelativeLineNumbers, forKey: "vimRelativeLineNumbers")
        defaults.set(NSColor.normalizedHexColor(vimCursorColorHex), forKey: "vimCursorColor")
        defaults.set(stickyLines, forKey: "stickyLines")
        defaults.set(stickyLinesMaxCount, forKey: "stickyLinesMaxCount")
        defaults.set(formatGoOnSave, forKey: "formatGoOnSave")
        defaults.set(showLineDiffBar, forKey: "showLineDiffBar")
        defaults.set(autoOpenThreeWayMerge, forKey: "autoOpenThreeWayMerge")
        defaults.set(lspJumpOpenMode.rawValue, forKey: "lspJumpOpenMode")
        defaults.set(lspIdleTimeout.rawValue, forKey: "lspIdleTimeoutSeconds")
        defaults.set(aiCommitProvider.rawValue, forKey: "aiCommitProvider")
        defaults.set(aiCommitModels, forKey: "aiCommitModels")
        defaults.set(aiGroupingProvider.rawValue, forKey: "aiGroupingProvider")
        defaults.set(aiGroupingModels, forKey: "aiGroupingModels")
        // Keep legacy key aligned with commit provider for downgrade compatibility.
        defaults.set(aiCommitProvider.rawValue, forKey: "aiAgentProvider")
        if commitMessageFormat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.removeObject(forKey: "commitMessageFormat")
        } else {
            defaults.set(commitMessageFormat, forKey: "commitMessageFormat")
        }
        defaults.set(projectsHeight, forKey: "projectsHeight")  // nil removes the key
        // Not the language: it is written when chosen, so that quitting never puts back a stale one over a
        // choice made since in System Settings.
    }

    /// Restores the AI commit message format template to its built-in default and persists it.
    func resetCommitMessageFormat() {
        commitMessageFormat = Self.defaultCommitMessageFormat
        save()
    }

    /// Saves a language picked in Settings; it shows from the next launch.
    func chooseLanguage(_ choice: Language) {
        language = choice
        choice.store(in: defaults)
    }

    /// Picks up a language set elsewhere since launch (System Settings ▸ Language & Region ▸ Applications).
    func reloadLanguage() {
        let stored = Language.stored(in: defaults)
        if stored != language { language = stored }
    }

    /// The chosen language is not the one this launch shows, so a restart is due.
    var languageNeedsRestart: Bool {
        language.isChinese(system: Language.systemLanguages) != Localization.isChinese
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
