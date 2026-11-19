import AppKit
import Observation

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    static let uiFontRange: ClosedRange<Double> = 11...17
    static let terminalFontRange: ClosedRange<Double> = 9...24
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
    /// Show the Beyond Compare-style bottom inline line diff bar under the code viewer.
    var showLineDiffBar: Bool
    /// Customizable commit message format specification used for AI commit generation.
    var commitMessageFormat: String

    /// The commit message format to send to AI, falling back to `defaultCommitMessageFormat` when empty.
    var effectiveCommitMessageFormat: String {
        commitMessageFormat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultCommitMessageFormat
            : commitMessageFormat
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
        showLineDiffBar = defaults.object(forKey: "showLineDiffBar") as? Bool ?? true
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
        defaults.set(flatList, forKey: "flatList")
        defaults.set(sidebarWidth, forKey: "sidebarWidth")
        defaults.set(listWidth, forKey: "listWidth")
        defaults.set(terminalHeight, forKey: "terminalHeight")
        defaults.set(commitBoxHeight, forKey: "commitBoxHeight")
        defaults.set(followFile, forKey: "followFile")
        defaults.set(vimMode, forKey: "vimMode")
        defaults.set(vimRelativeLineNumbers, forKey: "vimRelativeLineNumbers")
        defaults.set(showLineDiffBar, forKey: "showLineDiffBar")
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
