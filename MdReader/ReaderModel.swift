import SwiftUI

/// One entry in the table-of-contents outline.
struct TOCItem: Identifiable, Hashable {
    let id: String      // matches the heading's DOM id
    let level: Int      // 1…3
    let text: String
}

/// Per-document state shared between the web view and the sidebar: the heading
/// outline, which heading is currently at the top (for highlighting), and a hook
/// the sidebar calls to scroll the web view to a heading.
@MainActor
final class ReaderModel: ObservableObject {
    @Published var headings: [TOCItem] = []
    @Published var activeID: String?

    /// Installed by the web view; asks it to scroll a heading to the top.
    var scrollTo: ((String) -> Void)?
}
