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
}
