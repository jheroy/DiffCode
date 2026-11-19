import AppKit
import SwiftUI

/// The name people see: menus, window title, About, messages. The code and the `dif` command keep the old
/// short name. The bundle identifier is `com.nanshanbei.DiffCode`; builds before 2026-11-13 were
/// `app.dif.viewer`, whose settings `LegacyDefaults` copies over once.
let appName = "DiffCode"

// MARK: - Localisation

enum Localization {
    static let isChinese: Bool = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
}

/// Picks the English or Chinese string to match the system language.
func L(_ en: String, _ zh: String) -> String { Localization.isChinese ? zh : en }

// MARK: - Colours

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static func dyn(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        dynamic(light: NSColor(hex: light, alpha: lightAlpha), dark: NSColor(hex: dark, alpha: darkAlpha))
    }
}

/// Chrome colours, resolved automatically for light and dark appearance.
enum Palette {
    static let window = NSColor.dyn(0xFFFFFF, 0x1E1F22)
    static let sidebar = NSColor.dyn(0xF0F1F4, 0x232428)
    static let panel = NSColor.dyn(0xF7F8FA, 0x2B2D30)
    static let elevated = NSColor.dyn(0xFFFFFF, 0x2F3136)
    static let border = NSColor.dyn(0xE1E3E8, 0x14151A)
    static let hairline = NSColor.dyn(0xEBECF0, 0x393B40)
    static let islandFrame = NSColor.dyn(0xE8EBF0, 0x31353A)
    static let islandBorder = NSColor.dyn(0x000000, 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.08)
    static let textPrimary = NSColor.dyn(0x1F2329, 0xDFE1E5)
    static let textSecondary = NSColor.dyn(0x6C707E, 0x9DA0A8)
    static let textTertiary = NSColor.dyn(0xA2A6B3, 0x868A91)
    static let accent = NSColor.dyn(0x3574F0, 0x548AF7)
    static let hover = NSColor.dyn(0x000000, 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.06)
    static let selection = NSColor.dyn(0x3574F0, 0x548AF7, lightAlpha: 0.16, darkAlpha: 0.28)
    static let chip = NSColor.dyn(0x000000, 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.09)
    static let added = NSColor.dyn(0x1E8A34, 0x73BD79)
    static let removed = NSColor.dyn(0xC7392F, 0xE5736B)

    static func status(_ kind: FileChange.Kind?) -> NSColor {
        switch kind {
        case .modified: return NSColor.dyn(0x1F5FD0, 0x6CA6F5)
        case .added: return added
        case .deleted: return NSColor.dyn(0x7A7E87, 0x8C9199)
        case .renamed: return NSColor.dyn(0x17858A, 0x4EC9B0)
        case .untracked: return NSColor.dyn(0xB3402E, 0xE0766B)
        case .conflicted: return NSColor.dyn(0xD12F2F, 0xF26C6C)
        case nil: return textPrimary
        }
    }
}

extension Color {
    init(_ ns: NSColor) { self.init(nsColor: ns) }
    static let difWindow = Color(Palette.window)
    static let difSidebar = Color(Palette.sidebar)
    static let difPanel = Color(Palette.panel)
    static let difElevated = Color(Palette.elevated)
    static let difBorder = Color(Palette.border)
    static let difHairline = Color(Palette.hairline)
    static let difIslandFrame = Color(Palette.islandFrame)
    static let difIslandBorder = Color(Palette.islandBorder)
    static let difText = Color(Palette.textPrimary)
    static let difText2 = Color(Palette.textSecondary)
    static let difText3 = Color(Palette.textTertiary)
    static let difAccent = Color(Palette.accent)
    static let difHover = Color(Palette.hover)
    static let difSelection = Color(Palette.selection)
    static let difChip = Color(Palette.chip)
    static let difAdded = Color(Palette.added)
    static let difRemoved = Color(Palette.removed)
    static func status(_ kind: FileChange.Kind?) -> Color { Color(Palette.status(kind)) }
}

// MARK: - Code canvas theme

/// Foreground colour and font traits for one `TokenKind`.
struct TokenStyle: Equatable, Sendable {
    let color: CGColor
    let bold: Bool
    let italic: Bool

    init(_ color: CGColor, bold: Bool = false, italic: Bool = false) {
        self.color = color
        self.bold = bold
        self.italic = italic
    }
}

/// Pre-resolved CGColors and token styles for the code canvas, so drawing never touches dynamic colour lookup.
struct CanvasTheme {
    let isDark: Bool
    let background: CGColor
    let text: CGColor
    let gutterText: CGColor
    let gutterTextStrong: CGColor
    /// Default token styles indexed by `TokenKind.rawValue` (0...25).
    let syntax: [TokenStyle]
    /// GoLand-inspired palette for Go files, indexed by `TokenKind.rawValue` (0...25).
    let goSyntax: [TokenStyle]
    // Side-by-side follows the IntelliJ convention: blue = modified, green = inserted, grey = deleted.
    let modified: CGColor, modifiedWord: CGColor, modifiedMark: CGColor
    let added: CGColor, addedWord: CGColor, addedMark: CGColor
    let deleted: CGColor, deletedWord: CGColor, deletedMark: CGColor
    // Unified view uses the universal red/green.
    let removedLine: CGColor, removedWord: CGColor
    let selection: CGColor
    let searchMatch: CGColor
    let searchCurrent: CGColor
    let focusLine: CGColor
    let separator: CGColor
    let rulerThumb: CGColor
    let accent: CGColor

    private static func c(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor { NSColor(hex: hex, alpha: alpha).cgColor }

    func styles(for language: LanguageSpec?) -> [TokenStyle] {
        language?.name == "Go" ? goSyntax : syntax
    }

    func style(for kind: TokenKind, language: LanguageSpec? = nil) -> TokenStyle {
        let table = styles(for: language)
        let idx = Int(kind.rawValue)
        return idx < table.count ? table[idx] : TokenStyle(text)
    }

    private static let darkSyntaxPalette: [TokenStyle] = [
        TokenStyle(c(0xBCBEC4)),                   // 0: plain
        TokenStyle(c(0xCF8E6D)),                   // 1: keyword (JetBrains New UI Dark)
        TokenStyle(c(0x6AAB73)),                   // 2: string
        TokenStyle(c(0x7A7E85), italic: true),     // 3: comment
        TokenStyle(c(0x2AACB8)),                   // 4: number
        TokenStyle(c(0xB3AE60)),                   // 5: annotation
        TokenStyle(c(0x56A8F5)),                   // 6: function
        TokenStyle(c(0xC77DBB), italic: true),     // 7: constant
        TokenStyle(c(0xD5B778)),                   // 8: tag
        TokenStyle(c(0xBABABA)),                   // 9: attribute
        TokenStyle(c(0x6FAFBD)),                   // 10: type
        TokenStyle(c(0x6FAFBD), italic: true),     // 11: interface
        TokenStyle(c(0x56A8F5)),                   // 12: method
        TokenStyle(c(0x8888C6)),                   // 13: builtin
        TokenStyle(c(0xAFBF7E)),                   // 14: namespace
        TokenStyle(c(0xC77DBB)),                   // 15: property
        TokenStyle(c(0xBCBEC4)),                   // 16: parameter
        TokenStyle(c(0xBCBEC4)),                   // 17: variable
        TokenStyle(c(0x16BAAC)),                   // 18: typeParameter
        TokenStyle(c(0xBCBEC4)),                   // 19: operator
        TokenStyle(c(0x56A8F5)),                   // 20: exportedFunction
        TokenStyle(c(0xC77DBB), italic: true),     // 21: exportedConstant
        TokenStyle(c(0xBCBEC4)),                   // 22: exportedVariable
        TokenStyle(c(0x8888C6)),                   // 23: builtinType
        TokenStyle(c(0x6FAFBD)),                   // 24: exportedType
        TokenStyle(c(0xC77DBB)),                   // 25: exportedProperty
    ]

    private static let darkGoLandPalette: [TokenStyle] = [
        TokenStyle(c(0xBCBEC4)),                   // 0: plain
        TokenStyle(c(0xB8525E), italic: true),     // 1: keyword (coral/crimson red italic: func, go, defer, for, range, if, return, map)
        TokenStyle(c(0x6AAB73)),                   // 2: string
        TokenStyle(c(0x7A7E85), italic: true),     // 3: comment
        TokenStyle(c(0xD9A589)),                   // 4: number (warm amber/peach)
        TokenStyle(c(0xB3AE60)),                   // 5: annotation / struct tag
        TokenStyle(c(0x4E8EC6), italic: true),     // 6: function (unexported func: soft blue italic)
        TokenStyle(c(0xC8569C), italic: true),     // 7: constant (unexported const & nil/true/false/iota: orchid purple italic)
        TokenStyle(c(0xD5B778)),                   // 8: tag
        TokenStyle(c(0xBABABA)),                   // 9: attribute
        TokenStyle(c(0x9E9978), italic: true),     // 10: type (unexported type/struct: olive-tan italic)
        TokenStyle(c(0x9E8DD4)),                   // 11: interface (soft lavender)
        TokenStyle(c(0x4E8EC6), italic: true),     // 12: method (unexported method: soft blue italic)
        TokenStyle(c(0x84A9E8), italic: true),     // 13: builtin (builtin func: periwinkle/sky blue italic: make, delete, len)
        TokenStyle(c(0x919758)),                   // 14: namespace (package identifier: olive/sage green)
        TokenStyle(c(0x8F9196), italic: true),     // 15: property (unexported struct field: muted gray italic)
        TokenStyle(c(0xB3B2B6), italic: true),     // 16: parameter (function param & method receiver: warm gray italic)
        TokenStyle(c(0xBCBEC4)),                   // 17: variable (local variable: neutral light gray)
        TokenStyle(c(0x50B8A8)),                   // 18: typeParameter (generic type param)
        TokenStyle(c(0xBCBEC4)),                   // 19: operator
        TokenStyle(c(0x2E8CE6), bold: true),       // 20: exportedFunction (exported func/method decl & call: vivid blue BOLD)
        TokenStyle(c(0xDCDDD7), bold: true),       // 21: exportedConstant (exported const decl & ref: bright off-white BOLD)
        TokenStyle(c(0x7C6EE0), bold: true),       // 22: exportedVariable (exported package var: indigo/purple BOLD)
        TokenStyle(c(0xE01F92), bold: true),       // 23: builtinType (int64, bool, string, error, any: vivid magenta BOLD)
        TokenStyle(c(0xDFC7B3)),                   // 24: exportedType (exported struct/type: warm sand regular)
        TokenStyle(c(0xC6C7CC)),                   // 25: exportedProperty (exported struct field: light gray regular)
    ]

    private static let lightSyntaxPalette: [TokenStyle] = [
        TokenStyle(c(0x1F2329)),                   // 0: plain
        TokenStyle(c(0x0033B3), bold: true),       // 1: keyword (classic IntelliJ Light bold blue)
        TokenStyle(c(0x067D17)),                   // 2: string
        TokenStyle(c(0x8C8C8C), italic: true),     // 3: comment
        TokenStyle(c(0x1750EB)),                   // 4: number
        TokenStyle(c(0x9E880D)),                   // 5: annotation
        TokenStyle(c(0x00627A)),                   // 6: function
        TokenStyle(c(0x871094), italic: true),     // 7: constant
        TokenStyle(c(0x0033B3)),                   // 8: tag
        TokenStyle(c(0x174AD4)),                   // 9: attribute
        TokenStyle(c(0x007E8A)),                   // 10: type
        TokenStyle(c(0x007E8A), italic: true),     // 11: interface
        TokenStyle(c(0x00627A)),                   // 12: method
        TokenStyle(c(0x0033B3)),                   // 13: builtin
        TokenStyle(c(0x20999D)),                   // 14: namespace
        TokenStyle(c(0x871094)),                   // 15: property
        TokenStyle(c(0x080808)),                   // 16: parameter
        TokenStyle(c(0x080808)),                   // 17: variable
        TokenStyle(c(0x007E8A)),                   // 18: typeParameter
        TokenStyle(c(0x080808)),                   // 19: operator
        TokenStyle(c(0x00627A)),                   // 20: exportedFunction
        TokenStyle(c(0x871094), italic: true),     // 21: exportedConstant
        TokenStyle(c(0x080808)),                   // 22: exportedVariable
        TokenStyle(c(0x0033B3)),                   // 23: builtinType
        TokenStyle(c(0x007E8A)),                   // 24: exportedType
        TokenStyle(c(0x871094)),                   // 25: exportedProperty
    ]

    private static let lightGoLandPalette: [TokenStyle] = [
        TokenStyle(c(0x1F2329)),                   // 0: plain (GoLand Light)
        TokenStyle(c(0xA8283B), italic: true),     // 1: keyword (crimson/coral italic)
        TokenStyle(c(0x067D17)),                   // 2: string
        TokenStyle(c(0x8C8C8C), italic: true),     // 3: comment
        TokenStyle(c(0xB5541C)),                   // 4: number (warm amber)
        TokenStyle(c(0x8A7308)),                   // 5: annotation / struct tag
        TokenStyle(c(0x246A9E), italic: true),     // 6: function (unexported func: soft blue italic)
        TokenStyle(c(0x9B2378), italic: true),     // 7: constant (unexported const & nil/true/false/iota: orchid italic)
        TokenStyle(c(0x0033B3)),                   // 8: tag
        TokenStyle(c(0x174AD4)),                   // 9: attribute
        TokenStyle(c(0x6B6538), italic: true),     // 10: type (unexported type: olive-tan italic)
        TokenStyle(c(0x684DB0)),                   // 11: interface (lavender-purple)
        TokenStyle(c(0x246A9E), italic: true),     // 12: method (unexported method: soft blue italic)
        TokenStyle(c(0x2E6DA4), italic: true),     // 13: builtin (builtin func: sky-blue italic)
        TokenStyle(c(0x566B2F)),                   // 14: namespace (package identifier: olive green)
        TokenStyle(c(0x6B707B), italic: true),     // 15: property (unexported struct field: muted gray italic)
        TokenStyle(c(0x4A4D57), italic: true),     // 16: parameter (function param & receiver: warm gray italic)
        TokenStyle(c(0x1F2329)),                   // 17: variable (local variable)
        TokenStyle(c(0x0E7C73)),                   // 18: typeParameter
        TokenStyle(c(0x1F2329)),                   // 19: operator
        TokenStyle(c(0x0A5EB8), bold: true),       // 20: exportedFunction (exported func/method decl & call: vivid blue BOLD)
        TokenStyle(c(0x181A1F), bold: true),       // 21: exportedConstant (exported const decl & ref: crisp dark BOLD)
        TokenStyle(c(0x5842C3), bold: true),       // 22: exportedVariable (exported package var: indigo/purple BOLD)
        TokenStyle(c(0xB81474), bold: true),       // 23: builtinType (int64, bool, string, error, any: vivid magenta BOLD)
        TokenStyle(c(0x8A5A2B)),                   // 24: exportedType (exported struct/type: warm bronze)
        TokenStyle(c(0x2C3038)),                   // 25: exportedProperty (exported struct field: dark neutral gray)
    ]

    static let dark = CanvasTheme(
        isDark: true,
        background: c(0x1E1F22),
        text: c(0xBCBEC4),
        gutterText: c(0x4E525A),
        gutterTextStrong: c(0xA1A5AD),
        syntax: darkSyntaxPalette,
        goSyntax: darkGoLandPalette,
        modified: c(0x3574F0, 0.20), modifiedWord: c(0x3574F0, 0.40), modifiedMark: c(0x5C92F7),
        added: c(0x3FA65A, 0.20), addedWord: c(0x3FA65A, 0.42), addedMark: c(0x57B46F),
        deleted: c(0x868A93, 0.20), deletedWord: c(0x868A93, 0.40), deletedMark: c(0x8E929B),
        removedLine: c(0xE5534B, 0.17), removedWord: c(0xE5534B, 0.38),
        selection: c(0x2F65CA, 0.55),
        searchMatch: c(0xE8B339, 0.35),
        searchCurrent: c(0xF5A623, 0.85),
        focusLine: c(0xFFFFFF, 0.06),
        separator: c(0x393B40),
        rulerThumb: c(0xFFFFFF, 0.12),
        accent: c(0x548AF7)
    )

    static let light = CanvasTheme(
        isDark: false,
        background: c(0xFFFFFF),
        text: c(0x1F2329),
        gutterText: c(0xB4B8C2),
        gutterTextStrong: c(0x5A5E69),
        syntax: lightSyntaxPalette,
        goSyntax: lightGoLandPalette,
        modified: c(0x3574F0, 0.13), modifiedWord: c(0x3574F0, 0.28), modifiedMark: c(0x3574F0),
        added: c(0x2DA44E, 0.15), addedWord: c(0x2DA44E, 0.32), addedMark: c(0x2DA44E),
        deleted: c(0x6E7481, 0.14), deletedWord: c(0x6E7481, 0.28), deletedMark: c(0x868B97),
        removedLine: c(0xE5534B, 0.12), removedWord: c(0xE5534B, 0.28),
        selection: c(0x3574F0, 0.28),
        searchMatch: c(0xF5C542, 0.45),
        searchCurrent: c(0xF59E0B, 0.90),
        focusLine: c(0x000000, 0.045),
        separator: c(0xEBECF0),
        rulerThumb: c(0x000000, 0.10),
        accent: c(0x3574F0)
    )

    func line(_ kind: Hunk.Kind) -> CGColor {
        switch kind {
        case .modified: return modified
        case .added: return added
        case .deleted: return deleted
        }
    }

    func word(_ kind: Hunk.Kind) -> CGColor {
        switch kind {
        case .modified: return modifiedWord
        case .added: return addedWord
        case .deleted: return deletedWord
        }
    }

    func mark(_ kind: Hunk.Kind) -> CGColor {
        switch kind {
        case .modified: return modifiedMark
        case .added: return addedMark
        case .deleted: return deletedMark
        }
    }
}

/// Selectable font weights for code rendering (GoLand-style Main weight and Bold weight).
enum CodeFontWeight: String, CaseIterable, Identifiable, Sendable {
    case thin
    case extraLight
    case light
    case regular
    case medium
    case semiBold
    case bold
    case extraBold
    case black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thin: return "Thin"
        case .extraLight: return "ExtraLight"
        case .light: return "Light"
        case .regular: return "Regular"
        case .medium: return "Medium"
        case .semiBold: return "SemiBold"
        case .bold: return "Bold"
        case .extraBold: return "ExtraBold"
        case .black: return "Black"
        }
    }

    var cssWeight: CGFloat {
        switch self {
        case .thin: return 100
        case .extraLight: return 200
        case .light: return 300
        case .regular: return 400
        case .medium: return 500
        case .semiBold: return 600
        case .bold: return 700
        case .extraBold: return 800
        case .black: return 900
        }
    }

    var nsWeight: NSFont.Weight {
        switch self {
        case .thin: return .ultraLight
        case .extraLight: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semiBold: return .semibold
        case .bold: return .bold
        case .extraBold: return .heavy
        case .black: return .black
        }
    }

    /// CoreText `kCTFontWeightTrait` scale (`-1.0 ... 1.0`).
    var ctWeightTrait: CGFloat {
        switch self {
        case .thin: return -0.80
        case .extraLight: return -0.60
        case .light: return -0.40
        case .regular: return 0.00
        case .medium: return 0.23
        case .semiBold: return 0.30
        case .bold: return 0.40
        case .extraBold: return 0.56
        case .black: return 0.62
        }
    }

    /// AppKit `NSFontManager` weight scale (`2, 3, 4, 5, 6, 8, 9, 10, 11`).
    var appKitWeight: Int {
        switch self {
        case .thin: return 2
        case .extraLight: return 3
        case .light: return 4
        case .regular: return 5
        case .medium: return 6
        case .semiBold: return 8
        case .bold: return 9
        case .extraBold: return 10
        case .black: return 11
        }
    }
}

/// The monospace faces code and terminals are drawn in: a family picked in Settings, else JetBrains Mono when it is
/// installed, else the system's own monospace face. A picked family that is no longer installed counts as none.
enum MonospaceFonts {
    /// Four-character OpenType `'wght'` variation axis identifier.
    static let wghtAxisTag: Int = 0x77676874

    struct FamilyMember {
        let postScriptName: String
        let styleName: String
        let appKitWeight: Int
        let isItalic: Bool
        let parsedWeight: CodeFontWeight?
    }

    /// What "Default" stands for in Settings.
    static var defaultName: String {
        NSFont(name: "JetBrainsMono-Regular", size: 12) != nil ? "JetBrains Mono" : "SF Mono"
    }

    /// Resolves a Settings family choice to an installed named family, or `nil` when using the system monospaced font.
    static func resolvedFamilyName(for family: String?) -> String? {
        if let family, !family.isEmpty {
            if family.hasPrefix(".") { return nil }
            if regular(family, size: 12) != nil { return family }
        }
        if let jb = NSFont(name: "JetBrainsMono-Regular", size: 12), let name = jb.familyName, !name.hasPrefix(".") {
            return name
        }
        if regular("JetBrains Mono", size: 12) != nil { return "JetBrains Mono" }
        return nil
    }

    static func font(family: String?, size: CGFloat) -> NSFont {
        if let family, let font = regular(family, size: size) { return font }
        return NSFont(name: "JetBrainsMono-Regular", size: size)
            ?? NSFont(name: "JetBrains Mono", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The regular face of an installed family; nil when no family has that name.
    static func regular(_ family: String, size: CGFloat) -> NSFont? {
        guard let font = NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: family]), size: size),
              font.familyName == family else { return nil }
        return font
    }

    /// The installed families code can be drawn in, by name: those whose letters, digits and punctuation all have
    /// one width (the canvas puts characters in columns). Tens of milliseconds, so not on the main thread.
    static func installed() -> [String] {
        let families = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return families
            .filter { !$0.hasPrefix(".") && (regular($0, size: 12).map(isMonospaced) ?? false) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Measured rather than read from the font's flags: some faces flagged monospace have Latin letters of
    /// different widths, and patched faces (Nerd Fonts) may lose the flag although their letters keep one width.
    static func isMonospaced(_ font: NSFont) -> Bool {
        let characters = Array("iMW0.l_m ".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) else { return false }
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        let width = advances[0].width
        return width > 0 && advances.allSatisfy { abs($0.width - width) < 0.01 }
    }

    /// Parses a family's installed static members from `NSFontManager`.
    static func familyMembers(of family: String) -> [FamilyMember] {
        guard let rawMembers = NSFontManager.shared.availableMembers(ofFontFamily: family) else { return [] }
        return rawMembers.compactMap { entry in
            guard entry.count >= 4,
                  let psName = entry[0] as? String,
                  let styleName = entry[1] as? String,
                  let akWeight = entry[2] as? Int else { return nil }
            let traits = (entry[3] as? UInt) ?? (entry[3] as? Int).map { UInt(bitPattern: $0) } ?? 0
            let lowerStyle = styleName.lowercased()
            let isItalic = (traits & NSFontTraitMask.italicFontMask.rawValue) != 0
                || lowerStyle.contains("italic")
                || lowerStyle.contains("oblique")
            return FamilyMember(
                postScriptName: psName,
                styleName: styleName,
                appKitWeight: akWeight,
                isItalic: isItalic,
                parsedWeight: parseWeight(fromStyle: styleName)
            )
        }
    }

    /// Maps a font face's localized/OpenType style name (e.g. `"ExtraBold Italic"`, `"Semibold"`, `"Thin"`) to a
    /// canonical `CodeFontWeight`, or `nil` for custom optical names like `"Retina"`.
    static func parseWeight(fromStyle styleName: String) -> CodeFontWeight? {
        var token = styleName.lowercased()
        for strip in ["italic", "oblique", "slanted", "roman", "upright", "mono", "nerd", "font", " ", "-", "_"] {
            token = token.replacingOccurrences(of: strip, with: "")
        }
        switch token {
        case "", "regular", "normal", "book", "plain", "text":
            return .regular
        case "thin", "hairline":
            return .thin
        case "extralight", "ultralight", "xlight":
            return .extraLight
        case "light":
            return .light
        case "medium":
            return .medium
        case "semibold", "demibold", "demi":
            return .semiBold
        case "bold":
            return .bold
        case "extrabold", "ultrabold", "xbold", "heavy":
            return .extraBold
        case "black", "extrablack", "ultrablack":
            return .black
        default:
            return nil
        }
    }

    /// Returns the `[min, max]` range of a font's variable `'wght'` axis, if it has one.
    static func variationWeightRange(of font: CTFont) -> ClosedRange<CGFloat>? {
        guard let axes = CTFontCopyVariationAxes(font) as? [[CFString: Any]] else { return nil }
        for axis in axes {
            guard let tag = axis[kCTFontVariationAxisIdentifierKey] as? Int, tag == wghtAxisTag else { continue }
            guard let minVal = (axis[kCTFontVariationAxisMinimumValueKey] as? NSNumber)?.doubleValue,
                  let maxVal = (axis[kCTFontVariationAxisMaximumValueKey] as? NSNumber)?.doubleValue,
                  maxVal > minVal else { continue }
            return CGFloat(minVal)...CGFloat(maxVal)
        }
        return nil
    }

    /// Detects the ordered weights genuinely available for a font family.
    /// Variable fonts with a `'wght'` axis expose all weights within `[min, max]`, the system monospaced font exposes
    /// all 9 weights, and static families expose their distinct installed weights (falling back to all 9 if only 1).
    static func availableWeights(for family: String?) -> [CodeFontWeight] {
        guard let resolved = resolvedFamilyName(for: family) else {
            return CodeFontWeight.allCases
        }
        let members = familyMembers(of: resolved)
        guard !members.isEmpty else { return CodeFontWeight.allCases }

        let upright = members.filter { !$0.isItalic }
        let pool = upright.isEmpty ? members : upright

        // Variable font check on a representative face (prefer Regular).
        let representative = pool.first { $0.parsedWeight == .regular } ?? pool[0]
        let repFont = CTFontCreateWithName(representative.postScriptName as CFString, 12, nil)
        if let range = variationWeightRange(of: repFont) {
            let matched = CodeFontWeight.allCases.filter {
                $0.cssWeight >= range.lowerBound - 1 && $0.cssWeight <= range.upperBound + 1
            }
            return matched.isEmpty ? CodeFontWeight.allCases : matched
        }

        // Static multi-weight family: collect distinct matched weights in canonical order.
        var found: Set<CodeFontWeight> = []
        for member in pool {
            if let parsed = member.parsedWeight {
                found.insert(parsed)
            } else {
                let face = CTFontCreateWithName(member.postScriptName as CFString, 12, nil)
                let traits = CTFontCopyTraits(face) as? [CFString: Any]
                if let ctWeight = (traits?[kCTFontWeightTrait] as? NSNumber)?.doubleValue {
                    let nearest = CodeFontWeight.allCases.min {
                        abs(Double($0.ctWeightTrait) - ctWeight) < abs(Double($1.ctWeightTrait) - ctWeight)
                    }
                    if let nearest { found.insert(nearest) }
                }
            }
        }
        let ordered = CodeFontWeight.allCases.filter { found.contains($0) }
        return ordered.count > 1 ? ordered : CodeFontWeight.allCases
    }

    /// Maps any persisted weight to the closest available weight in `available`.
    static func nearestWeight(_ target: CodeFontWeight, in available: [CodeFontWeight]) -> CodeFontWeight {
        guard !available.isEmpty else { return target }
        if available.contains(target) { return target }
        return available.min { a, b in
            let da = abs(a.cssWeight - target.cssWeight)
            let db = abs(b.cssWeight - target.cssWeight)
            if da != db { return da < db }
            return a.cssWeight < b.cssWeight
        } ?? target
    }
}

/// Font and derived metrics for code rendering.
struct CodeFont: Equatable {
    let font: NSFont
    let regularFont: CTFont
    let boldFont: CTFont
    let italicFont: CTFont
    let boldItalicFont: CTFont
    let size: CGFloat
    let mainWeight: CodeFontWeight
    let boldWeight: CodeFontWeight
    let ligatures: Bool
    let lineHeight: CGFloat
    let baseline: CGFloat
    let charWidth: CGFloat

    /// `family`: a family picked in Settings, or nil for the default face.
    init(
        size: CGFloat,
        family: String? = nil,
        mainWeight: CodeFontWeight = .regular,
        boldWeight: CodeFontWeight = .bold,
        ligatures: Bool = true
    ) {
        self.size = size
        self.mainWeight = mainWeight
        self.boldWeight = boldWeight
        self.ligatures = ligatures

        let regular = Self.resolveFont(family: family, size: size, weight: mainWeight, italic: false, ligatures: ligatures)
        let bold = Self.resolveFont(family: family, size: size, weight: boldWeight, italic: false, ligatures: ligatures)
        let italic = Self.resolveFont(family: family, size: size, weight: mainWeight, italic: true, ligatures: ligatures)
        let boldItalic = Self.resolveFont(family: family, size: size, weight: boldWeight, italic: true, ligatures: ligatures)

        regularFont = regular
        boldFont = bold
        italicFont = italic
        boldItalicFont = boldItalic
        font = regular as NSFont
        lineHeight = (size * 1.5).rounded()
        let ascent = CTFontGetAscent(regular), descent = CTFontGetDescent(regular)
        baseline = ((lineHeight - (ascent + descent)) / 2 + ascent).rounded()
        charWidth = ("0" as NSString).size(withAttributes: [.font: regular as NSFont]).width
    }

    func ctFont(bold: Bool, italic: Bool) -> CTFont {
        switch (bold, italic) {
        case (false, false): return regularFont
        case (true, false): return boldFont
        case (false, true): return italicFont
        case (true, true): return boldItalicFont
        }
    }

    /// Resolves an exact CoreText face for the given family, size, weight, italic polarity, and ligature setting.
    static func resolveFont(
        family: String?,
        size: CGFloat,
        weight: CodeFontWeight,
        italic: Bool,
        ligatures: Bool = true
    ) -> CTFont {
        let resolved: CTFont
        if let familyName = MonospaceFonts.resolvedFamilyName(for: family) {
            resolved = resolveNamedFamily(familyName, size: size, weight: weight, italic: italic)
        } else {
            resolved = resolveSystemMonospace(size: size, weight: weight, italic: italic)
        }
        return applyLigatures(to: resolved, enabled: ligatures)
    }

    private static func resolveSystemMonospace(size: CGFloat, weight: CodeFontWeight, italic: Bool) -> CTFont {
        let base: CTFont = NSFont.monospacedSystemFont(ofSize: size, weight: weight.nsWeight)
        guard italic else { return base }
        if let nativeItalic = CTFontCreateCopyWithSymbolicTraits(base, 0, nil, .traitItalic, .traitItalic) {
            return nativeItalic
        }
        return synthesizeOblique(from: base)
    }

    private static func resolveNamedFamily(
        _ family: String,
        size: CGFloat,
        weight: CodeFontWeight,
        italic: Bool
    ) -> CTFont {
        let members = MonospaceFonts.familyMembers(of: family)
        guard !members.isEmpty else {
            let fallback: CTFont = MonospaceFonts.font(family: family, size: size)
            return italic ? synthesizeOblique(from: fallback) : fallback
        }

        let polarityMatches = members.filter { $0.isItalic == italic }
        let candidates = polarityMatches.isEmpty ? members : polarityMatches
        let needsSyntheticItalic = italic && polarityMatches.isEmpty

        let exactStatic = candidates.first { $0.parsedWeight == weight }

        // Variable font support: if a candidate exposes a `'wght'` axis and there is no exact static PostScript member,
        // instantiate the continuous weight directly via `kCTFontVariationAttribute`.
        let representative = candidates.first { $0.parsedWeight == .regular } ?? candidates[0]
        let repFont = CTFontCreateWithName(representative.postScriptName as CFString, size, nil)
        if exactStatic == nil, let range = MonospaceFonts.variationWeightRange(of: repFont) {
            let clamped = min(range.upperBound, max(range.lowerBound, weight.cssWeight))
            let variations: [NSNumber: NSNumber] = [
                NSNumber(value: MonospaceFonts.wghtAxisTag): NSNumber(value: Double(clamped)),
            ]
            let descriptor = CTFontDescriptorCreateWithAttributes([
                kCTFontVariationAttribute: variations,
            ] as CFDictionary)
            let varied = CTFontCreateCopyWithAttributes(repFont, size, nil, descriptor)
            return needsSyntheticItalic ? synthesizeOblique(from: varied) : varied
        }

        // Static multi-weight family: exact style match first, else closest weight by parsed CSS weight,
        // CoreText `kCTFontWeightTrait`, and AppKit weight.
        let chosen: MonospaceFonts.FamilyMember
        if let exactStatic {
            chosen = exactStatic
        } else {
            chosen = candidates.min { a, b in
                weightDistance(of: a, to: weight, size: size) < weightDistance(of: b, to: weight, size: size)
            } ?? candidates[0]
        }

        let face = CTFontCreateWithName(chosen.postScriptName as CFString, size, nil)
        return needsSyntheticItalic ? synthesizeOblique(from: face) : face
    }

    private static func weightDistance(
        of member: MonospaceFonts.FamilyMember,
        to target: CodeFontWeight,
        size: CGFloat
    ) -> Double {
        if let parsed = member.parsedWeight {
            return abs(Double(parsed.cssWeight - target.cssWeight))
        }
        let face = CTFontCreateWithName(member.postScriptName as CFString, size, nil)
        let traits = CTFontCopyTraits(face) as? [CFString: Any]
        let ctWeight = (traits?[kCTFontWeightTrait] as? NSNumber)?.doubleValue
        let ctDistance = ctWeight.map { abs($0 - Double(target.ctWeightTrait)) * 400.0 }
        let akDistance = abs(Double(member.appKitWeight - target.appKitWeight)) * 50.0
        // Slight penalty (+5) so canonical named weights beat optical aliases like "Retina" on ties.
        return (ctDistance ?? akDistance) + Double(abs(member.appKitWeight - target.appKitWeight)) + 5.0
    }

    /// Synthesizes a clean ~12-degree oblique slant when a face has no native italic member.
    private static func synthesizeOblique(from base: CTFont) -> CTFont {
        var matrix = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
        return CTFontCreateCopyWithAttributes(base, 0, &matrix, nil)
    }

    /// Enables or explicitly disables CoreText + OpenType programming ligatures (`liga` and `calt`).
    private static func applyLigatures(to font: CTFont, enabled: Bool) -> CTFont {
        let features: [[CFString: Any]] = [
            [
                kCTFontFeatureTypeIdentifierKey: kLigaturesType,
                kCTFontFeatureSelectorIdentifierKey: enabled ? kCommonLigaturesOnSelector : kCommonLigaturesOffSelector,
            ],
            [
                kCTFontFeatureTypeIdentifierKey: kContextualAlternatesType,
                kCTFontFeatureSelectorIdentifierKey: enabled ? kContextualAlternatesOnSelector : kContextualAlternatesOffSelector,
            ],
            [
                kCTFontOpenTypeFeatureTag: "liga",
                kCTFontOpenTypeFeatureValue: enabled ? 1 : 0,
            ],
            [
                kCTFontOpenTypeFeatureTag: "calt",
                kCTFontOpenTypeFeatureValue: enabled ? 1 : 0,
            ],
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFeatureSettingsAttribute: features,
        ] as CFDictionary)
        return CTFontCreateCopyWithAttributes(font, 0, nil, descriptor)
    }

    /// The code font Settings asks for.
    @MainActor
    static func current(_ settings: Settings = .shared) -> CodeFont {
        CodeFont(
            size: settings.fontSize,
            family: settings.codeFontFamily,
            mainWeight: settings.codeFontMainWeight,
            boldWeight: settings.codeFontBoldWeight,
            ligatures: settings.codeFontLigatures
        )
    }

    static func == (a: CodeFont, b: CodeFont) -> Bool {
        a.size == b.size
            && a.mainWeight == b.mainWeight
            && a.boldWeight == b.boldWeight
            && a.ligatures == b.ligatures
            && (CTFontCopyPostScriptName(a.regularFont) as String) == (CTFontCopyPostScriptName(b.regularFont) as String)
            && (CTFontCopyPostScriptName(a.boldFont) as String) == (CTFontCopyPostScriptName(b.boldFont) as String)
    }
}

/// Interface metrics. Sizes in the views are written for the default 13 pt interface font and
/// scaled from there, so one setting resizes every list, header and popup together.
///
/// The scale is read from the observable settings, so any view body that asks for a font or a
/// metric is re-evaluated automatically when the setting changes.
@MainActor
enum UI {
    static let baseFontSize: CGFloat = 13

    static var scale: CGFloat { CGFloat(Settings.shared.uiFontSize) / baseFontSize }

    /// A length that should grow with the interface font (row heights, icon boxes), in whole points.
    static func s(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }
}

extension Font {
    /// Interface text. `size` is the size at the default interface font size.
    @MainActor
    static func ui(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * UI.scale, weight: weight, design: design)
    }

    /// The UI's monospace face, matching the code canvas.
    @MainActor
    static func code(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let scaled = size * UI.scale
        if let family = Settings.shared.codeFontFamily, let font = MonospaceFonts.regular(family, size: scaled) {
            return .custom(font.fontName, size: scaled).weight(weight)
        }
        if NSFont(name: "JetBrainsMono-Regular", size: scaled) != nil {
            return .custom("JetBrains Mono", size: scaled).weight(weight)
        }
        return .system(size: scaled, weight: weight, design: .monospaced)
    }
}
