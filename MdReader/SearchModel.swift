import SwiftUI

/// Per-window find state. The find bar reads/writes it; the web view installs the
/// `performFind` / `clearHighlights` hooks; the File-menu commands reach it through
/// a focused scene value.
@MainActor
final class SearchModel: ObservableObject {
    @Published var isVisible = false
    @Published var query = ""
    @Published var status: String?      // "3 of 12", "Not found", or nil
    @Published var focusToken = 0       // bumped to (re)focus the field

    var performFind: ((String, Bool) -> Void)?   // (query, forward)
    var clearHighlights: (() -> Void)?

    /// Show the bar and focus its field (⌘F).
    func present() {
        isVisible = true
        focusToken &+= 1
    }

    func dismiss() {
        isVisible = false
        status = nil
        clearHighlights?()
    }

    func find(forward: Bool) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { status = nil; clearHighlights?(); return }
        performFind?(q, forward)
    }

    func updateStatus(count: Int, index: Int) {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status = nil
        } else if count <= 0 {
            status = "Not found"
        } else {
            status = "\(index + 1) of \(count)"
        }
    }
}

struct SearchModelKey: FocusedValueKey {
    typealias Value = SearchModel
}

extension FocusedValues {
    var searchModel: SearchModel? {
        get { self[SearchModelKey.self] }
        set { self[SearchModelKey.self] = newValue }
    }
}
