import SwiftUI
import WebKit
import AppKit

/// Hosts a `WKWebView` that loads the bundled `index.html` renderer and feeds it
/// the document's Markdown. Also owns printing and PDF export for the document.
struct MarkdownWebView: NSViewRepresentable {

    let markdown: String
    let baseDirectory: URL?
    let documentName: String
    let fileURL: URL?
    let commander: WebCommander
    let model: ReaderModel
    let search: SearchModel
    let layout: LayoutModel

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(coordinator, forURLScheme: "mdimg")
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // Receive the heading outline and the active-heading updates from JS.
        // A weak proxy avoids the retain cycle userContentController -> handler.
        let proxy = WeakScriptMessageHandler(coordinator)
        config.userContentController.add(proxy, name: "toc")
        config.userContentController.add(proxy, name: "activeHeading")
        config.userContentController.add(proxy, name: "copy")
        config.userContentController.add(proxy, name: "layout")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground") // let the page paint its own bg
        coordinator.webView = webView

        // Expose printing and zoom to the menus for this window.
        commander.printAction = { [weak coordinator] in coordinator?.printDocument() }
        commander.zoomIn = { [weak coordinator] in coordinator?.zoomIn() }
        commander.zoomOut = { [weak coordinator] in coordinator?.zoomOut() }
        commander.zoomReset = { [weak coordinator] in coordinator?.zoomReset() }
        commander.isReady = true

        // Let the sidebar drive scrolling.
        model.scrollTo = { [weak coordinator] id in coordinator?.scrollToHeading(id) }

        // Let the find bar drive searching.
        search.performFind = { [weak coordinator] query, forward in
            coordinator?.find(query, forward: forward)
        }
        search.clearHighlights = { [weak coordinator] in coordinator?.clearFind() }

        // Let the Format menu drive the page width.
        layout.onApply = { [weak coordinator] format in coordinator?.applyFormat(format) }

        // Live reload: re-render when the file changes on disk.
        coordinator.startWatching()

        if let indexURL = Self.indexURL() {
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        // Load the document's text once; after that the file watcher (and only it)
        // pushes updates, so an unrelated SwiftUI re-render can't revert a live reload.
        if !context.coordinator.didInitialLoad {
            context.coordinator.didInitialLoad = true
            context.coordinator.setContent(markdown: markdown, baseDirectory: baseDirectory)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopWatching()
        let ucc = webView.configuration.userContentController
        ucc.removeScriptMessageHandler(forName: "toc")
        ucc.removeScriptMessageHandler(forName: "activeHeading")
        ucc.removeScriptMessageHandler(forName: "copy")
        ucc.removeScriptMessageHandler(forName: "layout")
    }

    /// Locate the bundled renderer whether resources are flattened or kept in Web/.
    static func indexURL() -> URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web")
            ?? Bundle.main.url(forResource: "index", withExtension: "html")
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKURLSchemeHandler, WKScriptMessageHandler {
        var parent: MarkdownWebView
        weak var webView: WKWebView?

        private var didFinishLoad = false
        var didInitialLoad = false
        private var pending: (md: String, base: String)?
        private var lastSent: (md: String, base: String)?
        private let printDelegate = PrintDelegate()
        private var watcher: FileWatcher?
        private var zoom: Double = {
            let z = UserDefaults.standard.double(forKey: "readerZoom")
            return z > 0 ? z : 1.0
        }()

        init(_ parent: MarkdownWebView) { self.parent = parent }

        // MARK: Feeding content

        func setContent(markdown: String, baseDirectory: URL?) {
            let base = baseDirectory?.path ?? ""
            if let last = lastSent, last.md == markdown, last.base == base { return }
            lastSent = (markdown, base)
            if didFinishLoad {
                inject(markdown, base)
            } else {
                pending = (markdown, base)
            }
        }

        private func inject(_ md: String, _ base: String) {
            let mdB64 = Data(md.utf8).base64EncodedString()
            let baseB64 = Data(base.utf8).base64EncodedString()
            // base64 payloads are safe inside single quotes — no escaping needed.
            // Trailing `void 0` keeps evaluateJavaScript from trying to serialize a result.
            webView?.evaluateJavaScript("window.__setContent && window.__setContent('\(mdB64)','\(baseB64)'); void 0;")
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didFinishLoad = true
            if let p = pending {
                inject(p.md, p.base)
                pending = nil
            }
            applyZoom() // restore the persisted text-zoom level
            applyFormat(parent.layout.format) // set the initial page width
        }

        /// Open real hyperlinks in the user's browser instead of navigating away
        /// from the rendered document.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               ["http", "https", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // MARK: WKScriptMessageHandler — outline & active heading from JS

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            switch message.name {
            case "toc":
                let rows = (message.body as? [[String: Any]]) ?? []
                parent.model.headings = rows.compactMap { row in
                    guard let id = row["id"] as? String,
                          let text = row["text"] as? String else { return nil }
                    let level = (row["level"] as? NSNumber)?.intValue ?? (row["level"] as? Int) ?? 1
                    return TOCItem(id: id, level: min(max(level, 1), 6), text: text)
                }
            case "activeHeading":
                if let id = message.body as? String { parent.model.activeID = id }
            case "copy":
                if let text = message.body as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            case "layout":
                if let body = message.body as? [String: Any] {
                    let maxBlock = (body["maxBlockWidth"] as? NSNumber)?.doubleValue ?? 0
                    autoOrient(maxBlockWidth: CGFloat(maxBlock))
                }
            default:
                break
            }
        }

        /// Auto-switch to Landscape when content is wider than Portrait can print
        /// (and back to Portrait when it isn't), unless the user has chosen a format.
        private func autoOrient(maxBlockWidth: CGFloat) {
            guard parent.layout.autoOrientation else { return }
            let current = parent.layout.format
            let portraitWidth = current.portrait().printableWidthPx
            let target = maxBlockWidth > portraitWidth ? current.landscape() : current.portrait()
            if target != current { parent.layout.applyAuto(target) }
        }

        /// Push a format's printable width (and a readable prose measure) to the page.
        func applyFormat(_ format: PageFormat) {
            let content = format.printableWidthPx
            // Let portrait pages fill (A4 ≈ 746, Letter ≈ 768); only cap the very wide
            // landscape widths so prose lines don't get uncomfortably long.
            let prose = min(content, 780)
            webView?.evaluateJavaScript(
                "window.__applyFormat && window.__applyFormat(\(Int(content)), \(Int(prose))); void 0;")
        }

        /// Scroll the web view so the given heading sits at the top.
        func scrollToHeading(_ id: String) {
            let idB64 = Data(id.utf8).base64EncodedString()
            webView?.evaluateJavaScript(
                "window.__scrollToHeading && window.__scrollToHeading(atob('\(idB64)')); void 0;")
        }

        // MARK: Find in page

        /// Find the next/previous occurrence, scroll to it, and highlight it.
        func find(_ query: String, forward: Bool) {
            guard let webView else { return }
            let qB64 = Data(query.utf8).base64EncodedString()
            let js = "JSON.stringify(window.__find ? window.__find(atob('\(qB64)'), \(forward ? "true" : "false")) : {count:0,index:-1})"
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self, let json = result as? String,
                      let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }
                let count = (obj["count"] as? NSNumber)?.intValue ?? 0
                let index = (obj["index"] as? NSNumber)?.intValue ?? -1
                self.parent.search.updateStatus(count: count, index: index)
            }
        }

        func clearFind() {
            webView?.evaluateJavaScript("window.__clearFind && window.__clearFind(); void 0;")
        }

        // MARK: Live reload

        func startWatching() {
            guard let url = parent.fileURL else { return }
            watcher = FileWatcher(url: url) { [weak self] in
                DispatchQueue.main.async { self?.reloadFromDisk() }
            }
        }

        func stopWatching() {
            watcher?.stop()
            watcher = nil
        }

        /// Re-read the file and re-render, keeping the scroll position. `setContent`
        /// ignores no-op events (identical content).
        private func reloadFromDisk() {
            guard let url = parent.fileURL,
                  let data = try? Data(contentsOf: url) else { return }
            setContent(markdown: MarkdownDocument.decode(data),
                       baseDirectory: url.deletingLastPathComponent())
        }

        // MARK: Text zoom

        private func applyZoom() {
            webView?.evaluateJavaScript("window.__setZoom && window.__setZoom(\(zoom)); void 0;")
        }

        private func setZoom(_ value: Double) {
            zoom = (min(max(value, 0.5), 3.0) * 100).rounded() / 100
            UserDefaults.standard.set(zoom, forKey: "readerZoom")
            applyZoom()
        }

        func zoomIn() { setZoom(zoom + 0.1) }
        func zoomOut() { setZoom(zoom - 0.1) }
        func zoomReset() { setZoom(1.0) }

        // MARK: WKURLSchemeHandler — serve local images from disk

        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            guard let url = task.request.url else {
                task.didFailWithError(URLError(.badURL)); return
            }
            let prefix = "mdimg://local/"
            let absString = url.absoluteString
            guard absString.hasPrefix(prefix),
                  let path = String(absString.dropFirst(prefix.count)).removingPercentEncoding else {
                task.didFailWithError(URLError(.badURL)); return
            }
            let fileURL = URL(fileURLWithPath: path)
            do {
                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                let response = URLResponse(url: url,
                                           mimeType: Self.mimeType(forExtension: fileURL.pathExtension),
                                           expectedContentLength: data.count,
                                           textEncodingName: nil)
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
            } catch {
                task.didFailWithError(error)
            }
        }

        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { /* synchronous serve */ }

        private static func mimeType(forExtension ext: String) -> String {
            switch ext.lowercased() {
            case "png": return "image/png"
            case "jpg", "jpeg": return "image/jpeg"
            case "gif": return "image/gif"
            case "svg": return "image/svg+xml"
            case "webp": return "image/webp"
            case "bmp": return "image/bmp"
            case "tif", "tiff": return "image/tiff"
            case "heic": return "image/heic"
            case "avif": return "image/avif"
            case "ico": return "image/x-icon"
            case "pdf": return "application/pdf"
            default: return "application/octet-stream"
            }
        }

        // MARK: Printing

        /// Re-render in a light theme (better on paper) before printing, then run `body`.
        private func prepareForPrint(_ body: @escaping () -> Void) {
            guard let webView else { body(); return }
            webView.callAsyncJavaScript("await window.__prepareForPrint(); return true;",
                                        arguments: [:], in: nil, in: .page) { _ in
                body()
            }
        }

        private func endPrint() {
            webView?.evaluateJavaScript("window.__endPrint && window.__endPrint();")
        }

        private func makePrintInfo() -> NSPrintInfo {
            let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
            // Match the on-screen page format so print/PDF is WYSIWYG. Set the
            // unoriented paper size first, then orientation, and let AppKit derive
            // the imageable area — setting an already-oriented paperSize alongside
            // .landscape confuses WKWebView's print view.
            let format = parent.layout.format
            info.paperSize = format.paper.portraitSizePt
            info.orientation = format.isLandscape ? .landscape : .portrait
            info.leftMargin = PageFormat.horizontalMarginPt
            info.rightMargin = PageFormat.horizontalMarginPt
            info.topMargin = PageFormat.verticalMarginPt
            info.bottomMargin = PageFormat.verticalMarginPt
            info.horizontalPagination = .fit  // safety net if a block exceeds even landscape
            info.verticalPagination = .automatic
            info.isHorizontallyCentered = false
            info.isVerticallyCentered = false
            return info
        }

        /// Show the standard print dialog. It includes the system **PDF ▸ Save as PDF**
        /// option, so this single command covers both printing and exporting to PDF.
        func printDocument() {
            guard webView?.window != nil else { return }
            prepareForPrint { [weak self] in
                guard let self else { return }
                // Present on the NEXT runloop tick — not from inside the WebKit JS
                // completion handler — and use a plain (non-actor) modal delegate.
                // Presenting the print sheet reentrantly from that completion, or via an
                // actor-isolated delegate, is what crashed the previous version.
                DispatchQueue.main.async { [weak self] in
                    guard let self, let webView = self.webView, let window = webView.window else { return }
                    let op = webView.printOperation(with: self.makePrintInfo())
                    op.showsPrintPanel = true
                    op.showsProgressPanel = true
                    // WKWebView's print view (WKPrintingView) can start with a zero
                    // frame, tripping "frame was not initialized properly before
                    // knowsPageRange". Seed a valid frame; WebKit re-lays out the real
                    // (multi-page) content afterwards.
                    let seed = webView.bounds.isEmpty
                        ? NSRect(x: 0, y: 0, width: 800, height: 600) : webView.bounds
                    op.view?.frame = seed
                    self.printDelegate.onDidRun = { [weak self] in self?.endPrint() }
                    op.runModal(for: window,
                                delegate: self.printDelegate,
                                didRun: #selector(PrintDelegate.printOperationDidRun(_:success:contextInfo:)),
                                contextInfo: nil)
                }
            }
        }
    }
}

/// Plain (non-actor-isolated) modal delegate for `NSPrintOperation.runModal`.
/// AppKit calls the `didRun` selector via the Objective-C runtime; keeping this
/// off the `@MainActor` coordinator avoids the isolation crash the old code hit.
final class PrintDelegate: NSObject {
    var onDidRun: (() -> Void)?

    @objc func printOperationDidRun(_ printOperation: NSPrintOperation,
                                    success: Bool,
                                    contextInfo: UnsafeMutableRawPointer?) {
        onDidRun?()
    }
}

/// Forwards script messages to a weakly-held handler so the web view's
/// userContentController doesn't retain (and leak) the coordinator.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        delegate?.userContentController(controller, didReceive: message)
    }
}
