import AppKit
import ApplicationServices
import SwiftUI

@main
struct VoiceMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        MenuBarExtra("Voice Mac", systemImage: "waveform") {
            MenuContent(model: delegate.model)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: Model
    var body: some View {
        Text(model.ready ? "Hold ⌥Space and speak" : "Starting the engine…")
        Toggle("Use my Brave (sign-ins, new tab)", isOn: $model.useMyBrave)
        Button("Show details") { model.showPanel() }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    private var hotkey: Hotkey?
    func applicationDidFinishLaunching(_: Notification) {
        model.boot()
        model.showPanel()
        // Mac control runs through axd under this app's Accessibility grant; ask once, macOS remembers it.
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        hotkey = Hotkey(onPress: { [model] in model.startListening() }, onRelease: { [model] in model.stopListening() })
    }
    func applicationWillTerminate(_: Notification) { model.engine?.stop() }
    /// Opening the app again (Finder, Spotlight, Dock) shows the details under the notch.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        model.showPanel()
        return false
    }
}

/// Everything the panel shows: what was heard, how Jev routed it, and the running task's steps.
final class Model: ObservableObject {
    enum Phase { case idle, working, done }
    @Published var ready = false
    @Published var expanded = false
    @Published var level = 0.0
    @Published var phase = Phase.idle
    @Published var status = ""
    @Published var listening = false
    @Published var heard = ""
    @Published var routing = ""
    @Published var did = ""
    @Published var steps: [String] = []
    @Published var taskStatus = ""
    @Published var answer: [String] = []
    @Published var pending: String?
    @Published var error: String?
    @Published var useMyBrave = UserDefaults.standard.bool(forKey: "useMyBrave") {
        didSet { UserDefaults.standard.set(useMyBrave, forKey: "useMyBrave") }
    }
    var engine: Engine?
    private var taskId: String?
    private let recorder = Recorder()
    private lazy var notch = Notch(model: self)
    private var collapse: DispatchWorkItem?

    /// The repo holding engine/rpc.ts: set at build time in Info.plist, overridable for development.
    private var engineDir: URL {
        if let dir = ProcessInfo.processInfo.environment["VOICE_MAC_DIR"] { return URL(fileURLWithPath: dir) }
        if let dir = Bundle.main.object(forInfoDictionaryKey: "VoiceMacDir") as? String { return URL(fileURLWithPath: dir) }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    func boot() {
        do {
            let engine = try Engine(directory: engineDir)
            engine.onEvent = { [weak self] in self?.handle(event: $0) }
            self.engine = engine
        } catch {
            self.error = "Couldn't start the engine: \(error.localizedDescription)"
            showPanel()
        }
    }

    func showPanel() {
        _ = notch
        expanded = true
        collapseLater(after: phase == .working ? nil : 8)
    }

    /// Fold the card back into the notch once nothing needs attention.
    private func collapseLater(after seconds: Double?) {
        collapse?.cancel()
        guard let seconds else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.listening, self.pending == nil, self.phase != .working else { return }
            self.expanded = false
        }
        collapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func startListening() {
        guard ready, !listening else { return }
        do {
            recorder.onLevel = { [weak self] l in DispatchQueue.main.async { self?.level = l } }
            try recorder.start()
            listening = true
            error = nil
            heard = ""
            routing = ""
            did = ""
            expanded = true
            collapse?.cancel()
        } catch {
            self.error = "Microphone unavailable. Allow it in System Settings → Privacy & Security → Microphone."
            showPanel()
        }
    }

    func stopListening() {
        guard listening else { return }
        listening = false
        level = 0
        guard let wav = recorder.stop() else { status = "Too short. Hold ⌥Space while you speak."; collapseLater(after: 3); return }
        status = "Transcribing…"
        phase = .working
        engine?.call("utterance", ["audio": wav.base64EncodedString(), "mine": useMyBrave]) { [weak self] result in
            self?.handle(utterance: result)
        }
    }

    func approve(_ ok: Bool) {
        guard let taskId else { return }
        engine?.call("task.approve", ["id": taskId, "ok": ok]) { _ in }
        pending = nil
    }

    func stopTask() {
        guard let taskId else { return }
        engine?.call("task.stop", ["id": taskId]) { _ in }
    }

    private func handle(utterance result: Result<[String: Any], Error>) {
        switch result {
        case .failure(let e):
            did = ""
            status = ""
            error = e.localizedDescription
            phase = .idle
            collapseLater(after: 8)
        case .success(let r):
            heard = r["said"] as? String ?? ""
            did = r["did"] as? String ?? ""
            status = did
            if let intent = r["intent"] as? String, let conf = r["confidence"] as? Double, let addr = r["addressed"] as? Double {
                let ms = r["ms_whisper"] as? Int ?? 0
                routing = "\(intent) \(Int(conf * 100))% · to me \(Int(addr * 100))% · heard in \(ms) ms by \((r["by"] as? String) == "local" ? "whisper.cpp" : "Groq")"
            } else { routing = "" }
            if let task = r["task"] as? [String: Any], let id = task["id"] as? String {
                taskId = id
                steps = []
                answer = []
                taskStatus = "running"
                phase = .working
                collapse?.cancel()
            } else {
                phase = .done
                collapseLater(after: 4)
            }
        }
    }

    private func handle(event: [String: Any]) {
        switch event["event"] as? String {
        case "ready":
            ready = true
            runTestUtterance()
        case "task" where event["id"] as? String == taskId:
            taskStatus = event["status"] as? String ?? ""
            for s in event["steps"] as? [[String: Any]] ?? [] { steps.append(Model.describe(step: s)) }
            pending = (event["pending"] as? [String: Any])?["label"] as? String
            answer = (event["answer"] as? [String: Any])?["lines"] as? [String] ?? answer
            if let e = event["error"] as? String { error = e }
            if pending != nil { expanded = true; status = "Needs your OK" }
            switch taskStatus {
            case "done": phase = .done; status = "Done"; collapseLater(after: 12)
            case "stuck", "stopped", "error": phase = .done; status = taskStatus == "error" ? "Something went wrong" : "Stopped"; collapseLater(after: 15)
            default: phase = .working; status = "Working…"
            }
        default:
            break
        }
    }

    /// `--utterance file.wav`: send a recording through the same path as the hotkey, print the outcome,
    /// and quit when the task ends. Lets scripts test the app without a microphone.
    private func runTestUtterance() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--utterance"), i + 1 < args.count,
              let wav = FileManager.default.contents(atPath: args[i + 1]) else { return }
        engine?.call("utterance", ["audio": wav.base64EncodedString(), "mine": useMyBrave]) { [weak self] result in
            guard let self else { return }
            self.handle(utterance: result)
            print("heard: \(self.heard)\nrouting: \(self.routing)\ndid: \(self.did)")
            if self.taskId == nil { exit(0) }
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                guard ["done", "stuck", "stopped", "error"].contains(self.taskStatus) else { return }
                print(self.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
                print("status: \(self.taskStatus)\nanswer: \(self.answer.prefix(4).joined(separator: " | "))")
                exit(0)
            }
        }
    }

    static func describe(step s: [String: Any]) -> String {
        let target = (s["target"] as? [String: Any])?["label"] as? String
        let text = s["text"] as? String
        var line: String
        switch s["op"] as? String ?? "" {
        case "CLICK": line = "Clicked “\(target ?? "")”"
        case "TYPE_TEXT": line = "Typed “\(text ?? "")” into “\(target ?? "")”"
        case "SELECT": line = "Chose “\(target ?? "")”"
        case "OPEN_URL": line = "Opened \(text ?? "an address")"
        case "QUICK": line = target ?? "Ran a command"
        case "MENU": line = "Chose menu \(target ?? "")"
        case "PRESS_RETURN": line = "Pressed Return"
        case "PRESS_ENTER": line = "Pressed Enter"
        case "SCROLL_DOWN": line = "Scrolled down"
        case "SCROLL_UP": line = "Scrolled up"
        case "WAIT": line = "Waited for the page"
        case "done": line = "Done"
        case "stuck": line = "Stopped"
        case let op: line = op
        }
        if let note = s["note"] as? String { line += " — \(note)" }
        return line
    }
}
