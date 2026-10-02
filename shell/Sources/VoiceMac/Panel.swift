import AppKit
import SwiftUI

/// A floating panel at the top of the screen that never steals focus from the app you're talking about.
final class Panel {
    private let window: NSPanel

    init(model: Model) {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                         styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .resizable],
                         backing: .buffered, defer: true)
        window.title = "Voice Mac"
        window.level = .floating
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: PanelView(model: model))
    }

    func show() {
        if !window.isVisible, let screen = NSScreen.main {
            let f = screen.visibleFrame
            window.setFrameTopLeftPoint(NSPoint(x: f.midX - window.frame.width / 2, y: f.maxY - 12))
        }
        window.orderFrontRegardless()
    }
}

struct PanelView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: model.listening ? "mic.fill" : "mic")
                    .foregroundStyle(model.listening ? Color.red : Color.secondary)
                Text(model.listening ? "Listening… release ⌥Space to send" : (model.ready ? "Hold ⌥Space and speak" : "Starting the engine…"))
                    .font(.headline)
            }
            if !model.heard.isEmpty { Text("“\(model.heard)”").font(.title3) }
            if !model.routing.isEmpty { Text(model.routing).font(.caption).foregroundStyle(.secondary) }
            if !model.did.isEmpty { Text(model.did) }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            if !model.steps.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.steps.enumerated()), id: \.offset) { i, s in
                            Text("\(i + 1). \(s)").font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(maxHeight: 140)
            }
            if let pending = model.pending {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Approve “\(pending)”?").bold()
                    HStack {
                        Button("Approve") { model.approve(true) }.keyboardShortcut(.defaultAction)
                        Button("Decline") { model.approve(false) }
                    }
                }.padding(8).background(Color.orange.opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if !model.answer.isEmpty {
                Text(model.answer.prefix(6).joined(separator: "\n")).padding(8)
                    .background(Color.green.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if model.taskStatus == "running" || model.taskStatus == "waiting" {
                Button("Stop task") { model.stopTask() }
            }
        }
        .padding(14)
        .frame(minWidth: 420, alignment: .topLeading)
    }
}
