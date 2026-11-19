import AppKit
import XCTest
@testable import DifKit

/// The monospace faces that can be picked in Settings for code and for terminals.
final class FontTests: XCTestCase {
    private let missing = "No Such Font 4F2A"

    func testPicksTheRegularFaceOfAFamily() {
        XCTAssertEqual(MonospaceFonts.font(family: "Menlo", size: 12).fontName, "Menlo-Regular")
        XCTAssertEqual(MonospaceFonts.font(family: "Menlo", size: 15).pointSize, 15)
    }

    /// A family picked once and uninstalled since draws in the default face, not in whatever the system substitutes.
    func testAMissingFamilyFallsBackToTheDefaultFace() {
        XCTAssertNil(MonospaceFonts.regular(missing, size: 12))
        XCTAssertEqual(MonospaceFonts.font(family: missing, size: 12).fontName, MonospaceFonts.font(family: nil, size: 12).fontName)
    }

    func testListsOnlyFacesWhoseCharactersShareOneWidth() {
        let installed = MonospaceFonts.installed()
        XCTAssertTrue(installed.contains("Menlo"))
        XCTAssertTrue(installed.contains("Courier New"))
        XCTAssertFalse(installed.contains("Helvetica"))
        XCTAssertFalse(installed.contains { $0.hasPrefix(".") }, "hidden system faces are not offered")
        XCTAssertEqual(installed, installed.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertTrue(MonospaceFonts.isMonospaced(NSFont(name: "Menlo-Regular", size: 12)!))
        XCTAssertFalse(MonospaceFonts.isMonospaced(NSFont(name: "Helvetica", size: 12)!))
    }

    /// The canvas lays text out again only when its font changes, so a new face must count as a change.
    func testCodeFontsDifferByFaceAndSize() {
        XCTAssertEqual(CodeFont(size: 12, family: "Menlo"), CodeFont(size: 12, family: "Menlo"))
        XCTAssertNotEqual(CodeFont(size: 12, family: "Menlo"), CodeFont(size: 12, family: "Courier New"))
        XCTAssertNotEqual(CodeFont(size: 12, family: "Menlo"), CodeFont(size: 13, family: "Menlo"))
        XCTAssertEqual(CodeFont(size: 12, family: missing), CodeFont(size: 12))
    }

    func testBoldAndItalicVariantsExistAndPreserveMetrics() {
        let menlo = CodeFont(size: 13, family: "Menlo")
        XCTAssertTrue(CTFontGetSymbolicTraits(menlo.boldFont).contains(.traitBold))
        XCTAssertTrue(CTFontGetSymbolicTraits(menlo.italicFont).contains(.traitItalic))
        let biTraits = CTFontGetSymbolicTraits(menlo.boldItalicFont)
        XCTAssertTrue(biTraits.contains(.traitBold) && biTraits.contains(.traitItalic))
        XCTAssertEqual(CTFontGetSize(menlo.boldFont), 13)
        XCTAssertEqual(CTFontGetSize(menlo.italicFont), 13)
        XCTAssertEqual(CTFontGetSize(menlo.boldItalicFont), 13)
        XCTAssertEqual(menlo.ctFont(bold: false, italic: false), menlo.regularFont)
        XCTAssertEqual(menlo.ctFont(bold: true, italic: false), menlo.boldFont)
        XCTAssertEqual(menlo.ctFont(bold: false, italic: true), menlo.italicFont)
        XCTAssertEqual(menlo.ctFont(bold: true, italic: true), menlo.boldItalicFont)

        // Faces that lack native italic (e.g. Monaco) still produce valid CTFonts and keep line metrics identical.
        let monaco = CodeFont(size: 14, family: "Monaco")
        XCTAssertEqual(monaco.lineHeight, (14.0 * 1.5).rounded())
        XCTAssertGreaterThan(monaco.charWidth, 0)
        XCTAssertEqual(CTFontGetSize(monaco.boldFont), 14)
        XCTAssertEqual(CTFontGetSize(monaco.italicFont), 14)
        XCTAssertEqual(CTFontGetSize(monaco.boldItalicFont), 14)

        let defaultFont = CodeFont(size: 12)
        XCTAssertEqual(CTFontGetSize(defaultFont.boldFont), 12)
        XCTAssertEqual(CTFontGetSize(defaultFont.italicFont), 12)
        XCTAssertEqual(CTFontGetSize(defaultFont.boldItalicFont), 12)
    }

    func testCodeFontWeightPropertiesAndStyleParsing() {
        let weights = CodeFontWeight.allCases
        XCTAssertEqual(weights.count, 9)
        XCTAssertEqual(weights.map(\.title), [
            "Thin", "ExtraLight", "Light", "Regular", "Medium", "SemiBold", "Bold", "ExtraBold", "Black",
        ])
        XCTAssertEqual(weights.map(\.cssWeight), [100, 200, 300, 400, 500, 600, 700, 800, 900])
        XCTAssertEqual(weights.map(\.appKitWeight), [2, 3, 4, 5, 6, 8, 9, 10, 11])
        for i in 1..<weights.count {
            XCTAssertGreaterThan(weights[i].ctWeightTrait, weights[i - 1].ctWeightTrait)
        }

        XCTAssertEqual(MonospaceFonts.parseWeight(fromStyle: "Thin"), .thin)
        XCTAssertEqual(MonospaceFonts.parseWeight(fromStyle: "Thin Italic"), .thin)
        XCTAssertEqual(MonospaceFonts.parseWeight(fromStyle: "ExtraLight"), .extraLight)
        XCTAssertEqual(MonospaceFonts.parseWeight(fromStyle: "UltraLight Oblique"), .extraLight)
        XCTAssertEqual(MonospaceFonts.parseWeight(fromStyle: "Light"), .light)
        XCTAssertEqual(MonospaceFonts.parseWeight(fromStyle: "Regular"), .regular)
        XCTAssertEqual(MonospaceFonts.parseWeight(fromStyle: "Italic"), .regular)
        XCTAssertEqual(MonospaceFonts.parseWeight(fromStyle: "Book"), .regular)
        XCTAssertEqual(MonospaceFonts.parseWeight(fromStyle: "Medium"), .medium)
        XCTAssertEqual(MonospaceFonts.parseWeight(fromStyle: "SemiBold"), .semiBold)
        XCTAssertEqual(MonospaceFonts.parseWeight(fromStyle: "Semibold Italic"), .semiBold)
        XCTAssertEqual(MonospaceFonts.parseWeight(fromStyle: "DemiBold"), .semiBold)
        XCTAssertEqual(MonospaceFonts.parseWeight(fromStyle: "Bold"), .bold)
        XCTAssertEqual(MonospaceFonts.parseWeight(fromStyle: "ExtraBold Italic"), .extraBold)
        XCTAssertEqual(MonospaceFonts.parseWeight(fromStyle: "Heavy"), .extraBold)
        XCTAssertEqual(MonospaceFonts.parseWeight(fromStyle: "Black"), .black)
        XCTAssertNil(MonospaceFonts.parseWeight(fromStyle: "Retina"))
    }

    @MainActor
    func testSettingsTypographyPersistence() {
        let suiteName = "FontTests.Typography.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = Settings(defaults: defaults)
        XCTAssertEqual(fresh.codeFontMainWeight, .regular)
        XCTAssertEqual(fresh.codeFontBoldWeight, .bold)
        XCTAssertTrue(fresh.codeFontLigatures)

        fresh.codeFontMainWeight = .thin
        fresh.codeFontBoldWeight = .extraBold
        fresh.codeFontLigatures = false
        fresh.save()

        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(reloaded.codeFontMainWeight, .thin)
        XCTAssertEqual(reloaded.codeFontBoldWeight, .extraBold)
        XCTAssertFalse(reloaded.codeFontLigatures)

        let codeFont = CodeFont.current(reloaded)
        XCTAssertEqual(codeFont.mainWeight, .thin)
        XCTAssertEqual(codeFont.boldWeight, .extraBold)
        XCTAssertFalse(codeFont.ligatures)
    }

    func testCodeFontEqualityDetectsTypographyChanges() {
        let base = CodeFont(size: 13, family: "Menlo", mainWeight: .regular, boldWeight: .bold, ligatures: true)
        XCTAssertEqual(base, CodeFont(size: 13, family: "Menlo", mainWeight: .regular, boldWeight: .bold, ligatures: true))
        XCTAssertNotEqual(base, CodeFont(size: 13, family: "Menlo", mainWeight: .thin, boldWeight: .bold, ligatures: true))
        XCTAssertNotEqual(base, CodeFont(size: 13, family: "Menlo", mainWeight: .regular, boldWeight: .extraBold, ligatures: true))
        XCTAssertNotEqual(base, CodeFont(size: 13, family: "Menlo", mainWeight: .regular, boldWeight: .bold, ligatures: false))
    }

    func testSystemMonospaceResolvesDistinctWeightsAndItalics() {
        let font = CodeFont(size: 13, family: ".SFNSMono", mainWeight: .thin, boldWeight: .extraBold, ligatures: true)
        let regPS = CTFontCopyPostScriptName(font.regularFont) as String
        let boldPS = CTFontCopyPostScriptName(font.boldFont) as String
        let italPS = CTFontCopyPostScriptName(font.italicFont) as String
        let biPS = CTFontCopyPostScriptName(font.boldItalicFont) as String

        XCTAssertNotEqual(regPS, boldPS)
        XCTAssertNotEqual(italPS, biPS)

        let regWeight = ctWeightTrait(of: font.regularFont)
        let boldWeight = ctWeightTrait(of: font.boldFont)
        XCTAssertGreaterThan(boldWeight, regWeight)

        let lightBold = CodeFont(size: 13, family: ".SFNSMono", mainWeight: .light, boldWeight: .bold)
        XCTAssertGreaterThan(ctWeightTrait(of: lightBold.boldFont), ctWeightTrait(of: lightBold.regularFont))
        XCTAssertGreaterThan(ctWeightTrait(of: font.boldFont), ctWeightTrait(of: lightBold.boldFont))
    }

    func testInstalledMultiWeightFamiliesResolveExactWeights() {
        let installed = MonospaceFonts.installed()
        if installed.contains("Maple Mono") {
            let maple = CodeFont(size: 13, family: "Maple Mono", mainWeight: .thin, boldWeight: .extraBold, ligatures: true)
            XCTAssertEqual(CTFontCopyPostScriptName(maple.regularFont) as String, "MapleMono-Thin")
            XCTAssertEqual(CTFontCopyPostScriptName(maple.boldFont) as String, "MapleMono-ExtraBold")
            XCTAssertEqual(CTFontCopyPostScriptName(maple.italicFont) as String, "MapleMono-ThinItalic")
            XCTAssertEqual(CTFontCopyPostScriptName(maple.boldItalicFont) as String, "MapleMono-ExtraBoldItalic")
            XCTAssertGreaterThan(ctWeightTrait(of: maple.boldFont), ctWeightTrait(of: maple.regularFont))

            let weights = MonospaceFonts.availableWeights(for: "Maple Mono")
            XCTAssertTrue(weights.contains(.thin))
            XCTAssertTrue(weights.contains(.regular))
            XCTAssertTrue(weights.contains(.bold))
            XCTAssertTrue(weights.contains(.extraBold))
        }

        // Check every installed multi-weight family resolves its lightest and heaviest weights distinctly.
        for family in installed {
            let weights = MonospaceFonts.availableWeights(for: family)
            guard let lightest = weights.first, let heaviest = weights.last, lightest != heaviest else { continue }
            // Skip single-weight families that fell back to allCases.
            let members = MonospaceFonts.familyMembers(of: family).filter { !$0.isItalic }
            guard members.count > 1 else { continue }

            let font = CodeFont(size: 13, family: family, mainWeight: lightest, boldWeight: heaviest)
            let regPS = CTFontCopyPostScriptName(font.regularFont) as String
            let boldPS = CTFontCopyPostScriptName(font.boldFont) as String
            if regPS != boldPS {
                XCTAssertGreaterThanOrEqual(
                    ctWeightTrait(of: font.boldFont),
                    ctWeightTrait(of: font.regularFont),
                    "Heaviest weight should not be lighter than lightest weight for \(family)"
                )
            }
        }
    }

    func testAvailableWeightsAndNearestWeightMapping() {
        XCTAssertEqual(MonospaceFonts.availableWeights(for: "Menlo"), [.regular, .bold])
        XCTAssertEqual(MonospaceFonts.availableWeights(for: ".SFNSMono"), CodeFontWeight.allCases)
        XCTAssertEqual(MonospaceFonts.availableWeights(for: "Monaco"), CodeFontWeight.allCases)

        XCTAssertEqual(MonospaceFonts.nearestWeight(.thin, in: [.regular, .bold]), .regular)
        XCTAssertEqual(MonospaceFonts.nearestWeight(.extraBold, in: [.regular, .bold]), .bold)
        XCTAssertEqual(MonospaceFonts.nearestWeight(.semiBold, in: [.light, .regular, .bold]), .bold)
    }

    func testLigaturesCTLineShapingAndCaretOffsets() {
        let sample = "if lid <= 0 && ok != nil && x == 1"
        let familiesToTest: [String?] = [nil, "Menlo"] + (MonospaceFonts.installed().contains("Maple Mono") ? ["Maple Mono"] : [])

        for family in familiesToTest {
            for ligatures in [true, false] {
                let codeFont = CodeFont(size: 13, family: family, mainWeight: .regular, boldWeight: .bold, ligatures: ligatures)
                let attr = NSAttributedString(string: sample, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): codeFont.regularFont,
                    .ligature: ligatures ? 1 : 0,
                ])
                let line = CTLineCreateWithAttributedString(attr)
                let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                XCTAssertGreaterThan(width, 0)

                let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
                XCTAssertFalse(runs.isEmpty)

                // Verify cursor offsets are monotonically non-decreasing across every UTF-16 index including `<=`, `!=`, `==`.
                var previousOffset: CGFloat = -1
                for idx in 0...attr.length {
                    let offset = CTLineGetOffsetForStringIndex(line, idx, nil)
                    XCTAssertGreaterThanOrEqual(offset, previousOffset)
                    previousOffset = offset
                }

                // Verify hit-testing round-trips inside a ligature operator (`<=` starts at index 7).
                let opOffset = CTLineGetOffsetForStringIndex(line, 7, nil)
                let hitIndex = CTLineGetStringIndexForPosition(line, CGPoint(x: opOffset + 0.5, y: 0))
                XCTAssertTrue((7...8).contains(hitIndex))
            }
        }

        // On ligature-capable coding fonts installed on this Mac (Maple Mono / FiraCode), verify glyph IDs actually toggle.
        let ligatureFamily = ["Maple Mono", "FiraCode Nerd Font"].first { MonospaceFonts.installed().contains($0) }
        if let ligatureFamily {
            let opSample = "<= != =="
            let onFont = CodeFont(size: 13, family: ligatureFamily, mainWeight: .regular, boldWeight: .bold, ligatures: true)
            let offFont = CodeFont(size: 13, family: ligatureFamily, mainWeight: .regular, boldWeight: .bold, ligatures: false)
            XCTAssertNotEqual(
                glyphIDs(for: opSample, font: onFont.regularFont, ligatureAttr: 1),
                glyphIDs(for: opSample, font: offFont.regularFont, ligatureAttr: 0),
                "Ligatures toggle should change CoreText shaped glyph IDs for \(ligatureFamily)"
            )
        }
    }

    private func ctWeightTrait(of font: CTFont) -> Double {
        let traits = CTFontCopyTraits(font) as? [CFString: Any]
        return (traits?[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
    }

    private func glyphIDs(for text: String, font: CTFont, ligatureAttr: Int) -> [CGGlyph] {
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            .ligature: ligatureAttr,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        var glyphs: [CGGlyph] = []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            var buffer = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRangeMake(0, count), &buffer)
            glyphs.append(contentsOf: buffer)
        }
        return glyphs
    }
}
