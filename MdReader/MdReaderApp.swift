import SwiftUI

@main
struct MdReaderApp: App {
    var body: some Scene {
        DocumentGroup(viewing: MarkdownDocument.self) { configuration in
            DocumentView(document: configuration.document, fileURL: configuration.fileURL)
        }
        // Initial window: doubled width (2 × 600) with the same ~half-A4 height;
        // the sidebar takes ~205pt, leaving a wide reading pane.
        .defaultSize(width: 1200, height: 740)
        .commands {
            // Replace the default (disabled) Print item with one wired to the focused
            // window's web view. The system print dialog includes "Save as PDF", so this
            // single item covers both printing and PDF export.
            CommandGroup(replacing: .printItem) {
                PrintMenuItem()
            }
            // Find commands (Edit menu): ⌘F opens the find bar, ⌘G / ⇧⌘G step.
            CommandGroup(after: .textEditing) {
                FindCommands()
            }
            // Zoom commands (View menu): ⌘= / ⌘- / ⌘0.
            CommandGroup(after: .sidebar) {
                ZoomCommands()
            }
            // Page format (paper + orientation), driving both the view and print.
            CommandMenu("Format") {
                FormatCommands()
            }
        }
    }
}

private struct PrintMenuItem: View {
    @FocusedValue(\.webCommander) private var commander

    var body: some View {
        Button("Print…") { commander?.printAction?() }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(commander?.printAction == nil)
    }
}

private struct FindCommands: View {
    @FocusedValue(\.searchModel) private var search

    var body: some View {
        Section {
            Button("Find…") { search?.present() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next") { search?.find(forward: true) }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { search?.find(forward: false) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
        .disabled(search == nil)
    }
}

private struct ZoomCommands: View {
    @FocusedValue(\.webCommander) private var commander

    var body: some View {
        Section {
            Button("Zoom In") { commander?.zoomIn?() }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { commander?.zoomOut?() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { commander?.zoomReset?() }
                .keyboardShortcut("0", modifiers: .command)
        }
        .disabled(commander == nil)
    }
}

private struct FormatCommands: View {
    // @FocusedObject (not @FocusedValue): LayoutModel is an ObservableObject, and
    // the menu must reflect its @Published state (the checkmarks). @FocusedValue
    // republishes only when the reference itself changes, so it would leave the
    // checkmarks frozen while the format actually changed underneath.
    @FocusedObject private var layout: LayoutModel?

    var body: some View {
        // Buttons, not Toggles/Picker: binding-based controls (Picker/Toggle) don't
        // reliably apply their selection inside a CommandMenu, but Button *actions*
        // do (as in the Print/Find/Zoom menus). @FocusedObject keeps the checkmarks
        // in sync with the model.
        Button {
            layout?.toggleAuto()
        } label: {
            if layout?.autoOrientation == true {
                Label("Automatic Orientation", systemImage: "checkmark")
            } else {
                Text("Automatic Orientation")
            }
        }
        .disabled(layout == nil)

        Divider()

        ForEach(PageFormat.allCases) { format in
            Button {
                layout?.selectManually(format)
            } label: {
                if layout?.format == format {
                    Label(format.displayName, systemImage: "checkmark")
                } else {
                    Text(format.displayName)
                }
            }
            .disabled(layout == nil)
        }
    }
}
