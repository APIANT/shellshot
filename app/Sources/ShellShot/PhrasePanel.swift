import AppKit
import SwiftUI

/// Search field that hands arrow keys, Return and Escape to the list instead of
/// swallowing them. SwiftUI's TextField eats them, so this is AppKit.
struct PaletteField: NSViewRepresentable {
    @Binding var text: String
    var onMove: (Int) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = "Search phrases"
        f.font = .systemFont(ofSize: 19)
        f.bezelStyle = .roundedBezel
        f.focusRingType = .none
        f.delegate = context.coordinator
        DispatchQueue.main.async { f.window?.makeFirstResponder(f) }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteField
        init(_ parent: PaletteField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let f = note.object as? NSTextField else { return }
            parent.text = f.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveUp(_:)):       parent.onMove(-1); return true
            case #selector(NSResponder.moveDown(_:)):     parent.onMove(1);  return true
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            default: return false
            }
        }
    }
}

struct PhraseView: View {
    let all: [Phrase]
    /// Where the text is headed, or nil when there's nothing to send to.
    let target: String?
    let onSend: (Phrase) -> Void
    let onEdit: () -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var index = 0

    private var shown: [Phrase] { Phrases.matches(query, in: all) }
    private var enabled: Bool { target != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            PaletteField(
                text: $query,
                onMove: { d in
                    guard !shown.isEmpty else { return }
                    index = min(max(index + d, 0), shown.count - 1)
                },
                onSubmit: submit,
                onCancel: onCancel
            )
            .frame(height: 28)
            .padding(10)

            if shown.isEmpty {
                Text(all.isEmpty ? "No phrases yet — add some with Edit Phrases."
                                 : "Nothing matches “\(query)”.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            } else {
                list
            }
        }
        .frame(width: 560)
        .onChange(of: query) { _ in index = 0 }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let target {
                Image(systemName: "arrow.right.circle")
                Text(target).lineLimit(1)
            } else {
                Image(systemName: "exclamationmark.triangle")
                Text("No Claude Code session in iTerm2 — nothing to send to.")
            }
            Spacer()
            Button("Edit Phrases…", action: onEdit)
                .buttonStyle(.link)
        }
        .font(.system(size: 14))
        .foregroundStyle(enabled ? .secondary : Color.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, p in
                        row(p, selected: i == index)
                            .id(i)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                index = i
                                submit()
                            }
                    }
                }
            }
            .frame(maxHeight: 320)
            .onChange(of: index) { i in proxy.scrollTo(i) }
        }
    }

    private func row(_ p: Phrase, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(p.name)
                    .font(.system(size: 17, weight: .medium))
                Spacer()
                if p.typeOnly {
                    Text("types only")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(p.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.20) : .clear)
        .opacity(enabled ? 1 : 0.45)
    }

    private func submit() {
        guard enabled, shown.indices.contains(index) else { return }
        onSend(shown[index])
    }
}

/// Floating palette hosting PhraseView.
final class PhrasePanelController {
    private var panel: NSPanel?

    var isOpen: Bool { panel != nil }

    func show(phrases: [Phrase], target: String?,
              onSend: @escaping (Phrase) -> Void) {
        close()
        let view = PhraseView(
            all: phrases,
            target: target,
            onSend: { [weak self] p in
                self?.close()
                onSend(p)
            },
            onEdit: { [weak self] in
                self?.close()
                Phrases.openInEditor()
            },
            onCancel: { [weak self] in self?.close() }
        )
        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.title = "ShellShot Phrases"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.center()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}
