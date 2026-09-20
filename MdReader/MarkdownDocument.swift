import SwiftUI
import UniformTypeIdentifiers

/// A read-only Markdown document. `DocumentGroup(viewing:)` uses this to open
/// files; the text is handed to the web view for rendering.
struct MarkdownDocument: FileDocument {

    var text: String

    init(text: String = "") {
        self.text = text
    }

    static var readableContentTypes: [UTType] {
        var types: [UTType] = []
        if let md = UTType("net.daringfireball.markdown") { types.append(md) }
        for ext in ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "text"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        types.append(.plainText)
        // De-duplicate while preserving order.
        var seen = Set<String>()
        return types.filter { seen.insert($0.identifier).inserted }
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = Self.decode(data)
    }

    /// Viewer app — nothing is ever written, but `FileDocument` requires this.
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }

    /// Best-effort text decoding: UTF-8 first, then common fallbacks.
    /// Also used by the live-reload watcher when re-reading from disk.
    static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}
