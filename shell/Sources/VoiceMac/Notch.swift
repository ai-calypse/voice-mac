import AppKit
import Combine
import SwiftUI

/// A black pill wrapped around the MacBook notch (a small pill at the top center on other screens).
/// Always visible, so you can see Voice Mac is running and when it is listening; it drops down into a
/// card for what was heard, the live steps, approvals and the answer.
/// macOS normally pushes windows below the menu bar; this one belongs on top of it, around the notch.
final class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { true } // so the Yes/No buttons take clicks
}

final class Notch {
    private let window: NotchPanel
    private let hosting: NSHostingView<NotchView>
    private let screen: NSScreen
    private let notch: CGSize
    private var bag: Set<AnyCancellable> = []

    init(model: Model) {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            notch = CGSize(width: 120, height: 26)
        }
        self.screen = screen
        window = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hosting = NSHostingView(rootView: NotchView(model: model, notch: notch))
        window.contentView = hosting
        // The window is exactly as big as what's drawn, so it never blocks clicks on the menu bar beside it.
        model.objectWillChange
            .debounce(for: .milliseconds(16), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.place() }
            .store(in: &bag)
        place()
    }

    private func place() {
        let fit = hosting.fittingSize
        let size = CGSize(width: fit.width, height: min(fit.height, 460))
        let f = screen.frame
        window.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height), display: true)
        window.orderFrontRegardless()
    }
}

struct NotchView: View {
    @ObservedObject var model: Model
    let notch: CGSize

    private var tint: Color {
        if model.listening { return .red }
        if model.error != nil { return .orange }
        switch model.phase {
        case .working: return .yellow
        case .done: return .green
        case .idle: return model.ready ? Color.white.opacity(0.55) : Color.white.opacity(0.25)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The strip that wraps the notch: status on the left ear, mic level or activity on the right ear.
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 8, height: 8)
                        .shadow(color: tint.opacity(model.listening ? 0.9 : 0), radius: 4)
                }
                .frame(width: 60, alignment: .center)
                Spacer(minLength: notch.width)
                Group {
                    if model.listening { LevelBars(level: model.level) }
                    else if model.phase == .working { ProgressView().controlSize(.mini).tint(.white) }
                    else { Image(systemName: "waveform").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6)) }
                }
                .frame(width: 60, alignment: .center)
            }
            .frame(height: notch.height)
            .contentShape(Rectangle())
            .onTapGesture { model.expanded.toggle() }

            if model.expanded { Details(model: model).padding(.horizontal, 18).padding(.vertical, 12) }
        }
        .frame(width: model.expanded ? max(notch.width + 200, 440) : notch.width + 120, alignment: .top)
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: model.expanded ? 22 : 12, bottomTrailingRadius: model.expanded ? 22 : 12))
        .foregroundStyle(.white)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.expanded)
    }
}

struct LevelBars: View {
    let level: Double
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let shape = [0.55, 0.85, 1.0, 0.85, 0.55][i]
                Capsule().fill(Color.red).frame(width: 3, height: max(3, 16 * min(1, level * 4) * shape))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

struct Details: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.listening ? "Listening… let go of ⌥Space to send" : model.ready ? (model.status.isEmpty ? "Hold ⌥Space and speak" : model.status) : "Starting…")
                .font(.system(size: 13, weight: .semibold))
            if !model.heard.isEmpty { Text("“\(model.heard)”").font(.system(size: 15)).lineLimit(3) }
            if !model.routing.isEmpty { Text(model.routing).font(.caption).foregroundStyle(.white.opacity(0.55)) }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.orange) }
            if !model.steps.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.steps.enumerated()), id: \.offset) { i, s in
                            Text("\(i + 1). \(s)").font(.callout).foregroundStyle(.white.opacity(0.85)).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 110)
            }
            if let pending = model.pending {
                HStack {
                    Text("Do “\(pending)”?").font(.callout.bold()).lineLimit(2)
                    Spacer()
                    Button("Yes") { model.approve(true) }.keyboardShortcut(.defaultAction)
                    Button("No") { model.approve(false) }
                }
            }
            if !model.answer.isEmpty {
                Text(model.answer.prefix(4).joined(separator: "\n")).font(.callout).lineLimit(5)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.18)).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Toggle("Use my Brave", isOn: $model.useMyBrave).toggleStyle(.switch).controlSize(.mini).font(.caption)
                Spacer()
                if model.phase == .working { Button("Stop") { model.stopTask() }.controlSize(.small) }
                Button { model.expanded = false } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain)
            }
        }
    }
}
