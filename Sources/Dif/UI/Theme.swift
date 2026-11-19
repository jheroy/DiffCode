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

/// The monospace faces code and terminals are drawn in: a family picked in Settings, else JetBrains Mono when it is
/// installed, else the system's own monospace face. A picked family that is no longer installed counts as none.
enum MonospaceFonts {
    /// What "Default" stands for in Settings.
    static var defaultName: String {
        NSFont(name: "JetBrainsMono-Regular", size: 12) != nil ? "JetBrains Mono" : "SF Mono"
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
}

/// Font and derived metrics for code rendering.
struct CodeFont: Equatable {
    let font: NSFont
    let regularFont: CTFont
    let boldFont: CTFont
    let italicFont: CTFont
    let boldItalicFont: CTFont
    let size: CGFloat
    let lineHeight: CGFloat
    let baseline: CGFloat
    let charWidth: CGFloat

    /// `family`: a family picked in Settings, or nil for the default face.
    init(size: CGFloat, family: String? = nil) {
        self.size = size
        font = MonospaceFonts.font(family: family, size: size)
        let base: CTFont = font
        regularFont = base
        let boldBase = Self.makeBold(from: base, nsFont: font, size: size)
        boldFont = boldBase
        italicFont = Self.makeItalic(from: base, nsFont: font)
        boldItalicFont = Self.makeBoldItalic(from: base, boldBase: boldBase, nsFont: font)
        lineHeight = (size * 1.5).rounded()
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        baseline = ((lineHeight - (ascent + descent)) / 2 + ascent).rounded()
        charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    func ctFont(bold: Bool, italic: Bool) -> CTFont {
        switch (bold, italic) {
        case (false, false): return regularFont
        case (true, false): return boldFont
        case (false, true): return italicFont
        case (true, true): return boldItalicFont
        }
    }

    private static func makeBold(from base: CTFont, nsFont: NSFont, size: CGFloat) -> CTFont {
        if let f = CTFontCreateCopyWithSymbolicTraits(base, 0, nil, .traitBold, .traitBold) {
            return f
        }
        let converted = NSFontManager.shared.convert(nsFont, toHaveTrait: .boldFontMask)
        if converted.fontDescriptor.symbolicTraits.contains(.bold) {
            return converted
        }
        if nsFont.fontName.hasPrefix(".") {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        }
        return base
    }

    private static func makeItalic(from base: CTFont, nsFont: NSFont) -> CTFont {
        if let f = CTFontCreateCopyWithSymbolicTraits(base, 0, nil, .traitItalic, .traitItalic) {
            return f
        }
        let converted = NSFontManager.shared.convert(nsFont, toHaveTrait: .italicFontMask)
        if converted.fontDescriptor.symbolicTraits.contains(.italic) {
            return converted
        }
        // Synthesize a clean ~12-degree oblique slant when the face has no native italic.
        var matrix = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
        return CTFontCreateCopyWithAttributes(base, 0, &matrix, nil)
    }

    private static func makeBoldItalic(from base: CTFont, boldBase: CTFont, nsFont: NSFont) -> CTFont {
        let both: CTFontSymbolicTraits = [.traitBold, .traitItalic]
        if let f = CTFontCreateCopyWithSymbolicTraits(base, 0, nil, both, both) {
            return f
        }
        if let f = CTFontCreateCopyWithSymbolicTraits(boldBase, 0, nil, .traitItalic, .traitItalic) {
            return f
        }
        let converted = NSFontManager.shared.convert(boldBase as NSFont, toHaveTrait: .italicFontMask)
        if converted.fontDescriptor.symbolicTraits.contains(.italic) {
            return converted
        }
        var matrix = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
        return CTFontCreateCopyWithAttributes(boldBase, 0, &matrix, nil)
    }

    /// The code font Settings asks for.
    @MainActor
    static func current(_ settings: Settings = .shared) -> CodeFont {
        CodeFont(size: settings.fontSize, family: settings.codeFontFamily)
    }

    static func == (a: CodeFont, b: CodeFont) -> Bool { a.size == b.size && a.font.fontName == b.font.fontName }
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
