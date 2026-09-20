import AppKit
import SwiftUI

/// Paper stock, in portrait points (1pt = 1/72").
enum PaperKind: String {
    case a4, letter
    var portraitSizePt: NSSize {
        switch self {
        case .a4:     return NSSize(width: 595.28, height: 841.89) // 210×297mm
        case .letter: return NSSize(width: 612, height: 792)       // 8.5×11"
        }
    }
    var displayName: String { self == .a4 ? "A4" : "US Letter" }
}

/// A page format = paper + orientation. Drives both the on-screen content width
/// and the print/PDF page, so the two stay WYSIWYG.
enum PageFormat: String, CaseIterable, Identifiable {
    case a4Portrait, a4Landscape, letterPortrait, letterLandscape

    var id: String { rawValue }

    // Keep the side gap small — just the printer's unprintable edge (~0.25") — so the
    // content nearly fills the sheet width. A slightly larger top/bottom gap reads
    // better on paper without affecting the reading width.
    static let horizontalMarginPt: CGFloat = 18   // ~0.25" — unprintable edge only
    static let verticalMarginPt: CGFloat = 36     // ~0.5"
    static let ptToPx: CGFloat = 96.0 / 72.0      // CSS px per point

    var paper: PaperKind {
        (self == .a4Portrait || self == .a4Landscape) ? .a4 : .letter
    }
    var isLandscape: Bool {
        self == .a4Landscape || self == .letterLandscape
    }
    var displayName: String {
        switch self {
        case .a4Portrait:      return "A4 Portrait"
        case .a4Landscape:     return "A4 Landscape"
        case .letterPortrait:  return "US Letter Portrait"
        case .letterLandscape: return "US Letter Landscape"
        }
    }

    /// Oriented paper size in points (for `NSPrintInfo`).
    var paperSizePt: NSSize {
        let p = paper.portraitSizePt
        return isLandscape ? NSSize(width: p.height, height: p.width) : p
    }

    /// Printable content width in CSS px (paper width − both side gaps).
    var printableWidthPx: CGFloat {
        (paperSizePt.width - 2 * Self.horizontalMarginPt) * Self.ptToPx
    }

    func portrait() -> PageFormat { paper == .a4 ? .a4Portrait : .letterPortrait }
    func landscape() -> PageFormat { paper == .a4 ? .a4Landscape : .letterLandscape }

    /// Region default: the system's default paper size (A4 vs Letter), Portrait.
    static func regionDefault() -> PageFormat {
        let size = NSPrintInfo.shared.paperSize
        let looksLetter = abs(size.width - 612) < 6 && abs(size.height - 792) < 6
        return looksLetter ? .letterPortrait : .a4Portrait
    }
}

/// Per-window page-format state. The Format menu reads/writes it; the web view
/// installs `onApply` (to push the width to the page and remember it for print).
@MainActor
final class LayoutModel: ObservableObject {
    @Published var format: PageFormat = PageFormat.regionDefault()
    @Published var autoOrientation: Bool = true

    /// Set by the web view; applies a format's width to the page.
    var onApply: ((PageFormat) -> Void)?

    /// User picked a format explicitly — stop auto-orienting.
    func selectManually(_ f: PageFormat) {
        autoOrientation = false
        format = f
        onApply?(f)
    }

    func toggleAuto() {
        autoOrientation.toggle()
        onApply?(format) // re-assert; a later layout report may flip orientation
    }

    /// Called by the web view after measuring content, when auto-orientation is on.
    func applyAuto(_ f: PageFormat) {
        guard autoOrientation else { return }
        format = f
        onApply?(f)
    }
}
// The Format menu reaches this model via @FocusedObject / .focusedSceneObject
// (keyed by type), so no FocusedValueKey is needed here.
