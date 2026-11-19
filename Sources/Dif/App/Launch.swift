import AppKit

/// How this copy of the app was distributed. It decides how the app is updated and what the sandbox lets it do.
public enum Edition: Sendable {
    /// Downloaded from the web: updates itself, runs outside the sandbox, has the built-in terminal.
    case direct
    /// From the Mac App Store: sandboxed, updated by the App Store, reaches folders only once they are granted.
    case appStore
}

/// Checks for updates, in the edition that updates itself. DifKit knows nothing of how (Sparkle, in `Dif`).
@MainActor public protocol AppUpdater: AnyObject {
    /// Starts the scheduled checks, once the app has finished launching.
    func start()
    func checkForUpdates()
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
}

/// The entry point the two editions call from their `main.swift`.
@MainActor public enum DiffCodeApp {
    public static func run(edition: Edition, updater: (any AppUpdater)? = nil) -> Never {
        AppEnvironment.edition = edition
        AppEnvironment.updater = updater
        // Before anything reads a setting.
        LegacyDefaults.migrateIfNeeded()
        let application = NSApplication.shared
        let delegate = AppDelegate()
        // The application holds its delegate weakly.
        AppEnvironment.delegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        exit(0)
    }
}

/// What the edition's launcher passed in.
enum AppEnvironment {
    /// Set first thing at launch, before anything reads it, and never again.
    nonisolated(unsafe) static var edition: Edition = .direct
    @MainActor static var updater: (any AppUpdater)?
    @MainActor fileprivate static var delegate: AppDelegate?

    static var isAppStore: Bool { edition == .appStore }

    /// The built-in terminal runs the user's shell with their privileges, which the App Store edition's sandbox
    /// would cripple (no tools, no files outside the granted folders); it is left out there.
    static var hasTerminal: Bool { !isAppStore }

    /// Language servers (gopls, rust-analyzer, sourcekit-lsp…) invoke user toolchains and read module caches
    /// outside the App Store sandbox; LSP is enabled in the direct download and disabled in the App Store edition.
    static var hasLSP: Bool { !isAppStore }

    /// What DiffCode's own process starts with (Info.plist `LSEnvironment`) but the programs it runs must not:
    /// `MallocSpaceEfficient` trades a little allocation speed for a much smaller, less fragmented heap, which suits
    /// a viewer that idles most of the day, not a compiler or a coding agent started from its terminal.
    static let ownProcessOnlyKeys: Set<String> = ["MallocSpaceEfficient"]

    /// The app's environment as handed to child processes: git, the terminal's shell.
    static var childEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.filter { !ownProcessOnlyKeys.contains($0.key) }
    }
}

/// Settings and the project list from before the bundle identifier changed: local builds up to 2026-11-13 were
/// `app.dif.viewer`. Copied once into this app's own domain; the old domain is left as it was. Only the direct
/// download can read another app's settings, so the sandboxed App Store edition starts fresh.
enum LegacyDefaults {
    static let legacyDomain = "app.dif.viewer"
    static let migratedKey = "migratedFromLegacyDomain"

    static func migrateIfNeeded(into defaults: UserDefaults = .standard,
                                domain: String? = Bundle.main.bundleIdentifier,
                                from legacy: String = legacyDomain) {
        // A bare `swift run` binary has no bundle identifier and keeps its own `Dif` domain.
        guard !Sandbox.isActive, let domain, domain != legacy, !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)
        guard let old = defaults.persistentDomain(forName: legacy), !old.isEmpty else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
