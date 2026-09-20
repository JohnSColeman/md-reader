import SwiftUI

/// A single document window: a heading-outline sidebar plus the rendered
/// Markdown, and the per-window commander the File menu talks to.
struct DocumentView: View {
    let document: MarkdownDocument
    let fileURL: URL?

    @StateObject private var commander = WebCommander()
    @StateObject private var model = ReaderModel()
    @StateObject private var search = SearchModel()
    @StateObject private var layout = LayoutModel()

    var body: some View {
        NavigationSplitView {
            TableOfContentsView(model: model)
                .navigationSplitViewColumnWidth(min: 170, ideal: 205, max: 340)
        } detail: {
            ZStack(alignment: .topTrailing) {
                MarkdownWebView(
                    markdown: document.text,
                    baseDirectory: fileURL?.deletingLastPathComponent(),
                    documentName: fileURL?.lastPathComponent ?? "Document",
                    fileURL: fileURL,
                    commander: commander,
                    model: model,
                    search: search,
                    layout: layout
                )
                .ignoresSafeArea()

                if search.isVisible {
                    FindBar(search: search)
                        .padding(12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.9), value: search.isVisible)
            .focusedSceneValue(\.webCommander, commander)
            .focusedSceneValue(\.searchModel, search)
            // Object (not value): the Format menu observes LayoutModel's @Published
            // state so its checkmarks track the current format. See FormatCommands.
            .focusedSceneObject(layout)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

/// The left-margin table of contents. Rows are indented by heading level, the
/// current section is highlighted, and clicking a row scrolls the document.
struct TableOfContentsView: View {
    @ObservedObject var model: ReaderModel

    var body: some View {
        if model.headings.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text("No headings")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Contents")
        } else {
            ScrollViewReader { proxy in
                List {
                    Section("Contents") {
                        ForEach(model.headings) { item in
                            TOCRow(item: item, isActive: item.id == model.activeID) {
                                model.scrollTo?(item.id)
                            }
                            .id(item.id)
                            .listRowBackground(
                                item.id == model.activeID
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.clear
                            )
                        }
                    }
                }
                .listStyle(.sidebar)
                .navigationTitle("Contents")
                .onChange(of: model.activeID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct TOCRow: View {
    let item: TOCItem
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(item.text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.leading, CGFloat(item.level - 1) * 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.text)
    }

    private var font: Font {
        switch item.level {
        case 1: return .system(.body, weight: isActive ? .bold : .semibold)
        case 2: return .system(.callout, weight: isActive ? .semibold : .regular)
        default: return .system(.footnote, weight: isActive ? .semibold : .regular)
        }
    }

    private var color: Color {
        if isActive { return .accentColor }
        return item.level == 1 ? .primary : .secondary
    }
}

/// Floating find field shown in the top-right of the reading pane (⌘F).
struct FindBar: View {
    @ObservedObject var search: SearchModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField("Find", text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 160)
                .focused($fieldFocused)
                .onSubmit { search.find(forward: true) }
                .onChange(of: search.query) { _, _ in search.status = nil }

            if let status = search.status {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(status == "Not found" ? Color.red : .secondary)
                    .fixedSize()
            }

            Divider().frame(height: 15)

            Button { search.find(forward: false) } label: {
                Image(systemName: "chevron.up")
            }
            .help("Find Previous (⇧⌘G)")

            Button { search.find(forward: true) } label: {
                Image(systemName: "chevron.down")
            }
            .help("Find Next (Return, ⌘G)")

            Button { search.dismiss() } label: {
                Image(systemName: "xmark")
            }
            .help("Close (Esc)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .onExitCommand { search.dismiss() }
        .onChange(of: search.focusToken) { _, _ in fieldFocused = true }
        .onAppear { fieldFocused = true }
    }
}
