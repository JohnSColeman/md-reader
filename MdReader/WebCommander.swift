import SwiftUI

/// Bridges the app's File-menu commands to the WKWebView of whichever document
/// window is currently focused. Each document view publishes its own commander
/// as a focused scene value; the menu buttons read it back.
@MainActor
final class WebCommander: ObservableObject {
    /// Set by the web view once it exists; nil while no document is focused.
    var printAction: (() -> Void)?
    var zoomIn: (() -> Void)?
    var zoomOut: (() -> Void)?
    var zoomReset: (() -> Void)?
    var isReady: Bool = false
}

struct WebCommanderKey: FocusedValueKey {
    typealias Value = WebCommander
}

extension FocusedValues {
    var webCommander: WebCommander? {
        get { self[WebCommanderKey.self] }
        set { self[WebCommanderKey.self] = newValue }
    }
}
