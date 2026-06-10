import AppKit
import SwiftUI

struct Frame: Identifiable, Equatable {
    let path: String
    let image: NSImage
    var id: String { path }
}

struct SendView: View {
    let sessions: [Session]
    @State private var frames: [Frame]
    @State private var shownIndex = 0
    @State private var selected: String
    @State private var message: String = ""
    @State private var arrows: [Arrow] = []
    @State private var draft: Arrow?
    @FocusState private var messageFocused: Bool
    let onSend: (_ sessionId: String, _ message: String, _ arrows: [Arrow], _ paths: [String]) -> Void
    let onCancel: () -> Void

    private var isSequence: Bool { frames.count > 1 }
    private var shown: Frame { frames[min(shownIndex, frames.count - 1)] }

    init(frames: [Frame], sessions: [Session],
         onSend: @escaping (String, String, [Arrow], [String]) -> Void,
         onCancel: @escaping () -> Void) {
        _frames = State(initialValue: frames)
        self.sessions = sessions
        self.onSend = onSend
        self.onCancel = onCancel
        // Preselect: focused iTerm2 session > last one sent to > most recently active
        let lastUsed = UserDefaults.standard.string(forKey: "lastSessionId")
        let initial = sessions.first(where: { $0.isActive == true })?.sessionId
            ?? sessions.first(where: { $0.sessionId == lastUsed })?.sessionId
            ?? sessions.first?.sessionId ?? ""
        _selected = State(initialValue: initial)
    }

    // Bound the preview by the screen, not a fixed box, so skinny-wide or
    // skinny-tall captures keep their long axis near full size.
    private var previewMax: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: screen.width * 0.85, height: screen.height * (isSequence ? 0.5 : 0.6))
    }

    private var previewSize: CGSize {
        let s = shown.image.size
        guard s.width > 0, s.height > 0 else { return previewMax }
        let k = min(previewMax.width / s.width, previewMax.height / s.height, 1)
        return CGSize(width: s.width * k, height: s.height * k)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Image(nsImage: shown.image)
                    .resizable()
                    .frame(width: previewSize.width, height: previewSize.height)
                if !isSequence {
                    Canvas { ctx, size in
                        for arrow in arrows + (draft.map { [$0] } ?? []) {
                            ctx.fill(arrow.path(in: size), with: .color(Color(cgColor: Arrow.red)))
                        }
                    }
                    .frame(width: previewSize.width, height: previewSize.height)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { g in
                                draft = Arrow(
                                    start: normalized(g.startLocation),
                                    end: normalized(g.location)
                                )
                            }
                            .onEnded { _ in
                                if let d = draft { arrows.append(d) }
                                draft = nil
                            }
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            .frame(maxWidth: .infinity, alignment: .center)

            if isSequence {
                filmstrip
            } else {
                HStack(spacing: 12) {
                    Text("Drag on the image to draw arrows")
                        .font(.system(size: 16)).foregroundStyle(.tertiary)
                    Spacer()
                    if !arrows.isEmpty {
                        Button("Undo") { _ = arrows.popLast() }
                            .keyboardShortcut("z", modifiers: .command)
                        Button("Clear") { arrows.removeAll() }
                    }
                }
                            }

            if sessions.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Session").font(.system(size: 16)).foregroundStyle(.secondary)
                    Picker("", selection: $selected) {
                        ForEach(sessions) { s in
                            Text("\(s.displayName)  (\(s.isActive == true ? "focused" : s.ageLabel))")
                                .font(.system(size: 19))
                                .tag(s.sessionId)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            } else if let only = sessions.first {
                Text("→ \(only.displayName)")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }

            TextField("What should Claude look at?", text: $message)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 19))
                .focused($messageFocused)
                .onSubmit { send() }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Copy to Clipboard", action: copyToClipboard)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(frames.isEmpty)
                Button("Send", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || frames.isEmpty)
            }
        }
        .padding(14)
        .controlSize(.large)
        .frame(width: max(560, previewSize.width + 28))
        .onAppear { messageFocused = true }
    }

    /// Copy the shown frame (arrows baked in) straight to the clipboard —
    /// no file written, no injection — and close.
    private func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if !isSequence, !arrows.isEmpty,
           let cg = try? Annotator.composite(image: shown.image, arrows: arrows) {
            pb.writeObjects([NSImage(cgImage: cg, size: .zero)])
        } else {
            pb.writeObjects([shown.image])
        }
        onCancel()
    }

    private var filmstrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(frames.count) frames — click to view, ✕ to drop")
                .font(.system(size: 16)).foregroundStyle(.tertiary)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(frames.enumerated()), id: \.element.id) { i, frame in
                        ZStack(alignment: .topTrailing) {
                            Image(nsImage: frame.image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 96, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(i == shownIndex ? Color.accentColor : .clear, lineWidth: 2)
                                )
                                .onTapGesture { shownIndex = i }
                            Button {
                                frames.remove(at: i)
                                if shownIndex >= frames.count { shownIndex = max(frames.count - 1, 0) }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .padding(2)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func send() {
        onSend(selected, message, isSequence ? [] : arrows, frames.map(\.path))
    }

    private func normalized(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(p.x / previewSize.width, 0), 1),
            y: min(max(p.y / previewSize.height, 0), 1)
        )
    }
}

/// Floating panel hosting SendView.
final class SendPanelController {
    private var panel: NSPanel?

    func show(frames: [Frame], sessions: [Session],
              onSend: @escaping (String, String, [Arrow], [String]) -> Void) {
        close()
        let view = SendView(
            frames: frames, sessions: sessions,
            onSend: { [weak self] sid, msg, arrows, paths in
                UserDefaults.standard.set(sid, forKey: "lastSessionId")
                onSend(sid, msg, arrows, paths)
                self?.close()
            },
            onCancel: { [weak self] in self?.close() }
        )
        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = "ShellShot"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = false
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
