import Foundation

/// The TypeScript engine as a child process, spoken to in newline-delimited JSON over stdio.
final class Engine {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private var buffer = Data()
    private var nextId = 1
    private var waiting: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    /// Pushed lines without an id: {"event": "task" | "ready", ...}.
    var onEvent: (([String: Any]) -> Void)?

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Apps opened from Finder get a minimal PATH, so nvm's node isn't on it. Use the node recorded at
    /// build time, else ask the login shell (which loads nvm), else common install locations.
    static func nodePath() -> String? {
        let fm = FileManager.default
        if let p = ProcessInfo.processInfo.environment["VOICE_MAC_NODE"], fm.isExecutableFile(atPath: p) { return p }
        if let p = Bundle.main.object(forInfoDictionaryKey: "VoiceMacNode") as? String, fm.isExecutableFile(atPath: p) { return p }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lic", "command -v node"]
        let out = Pipe()
        shell.standardOutput = out
        shell.standardError = FileHandle.nullDevice
        if (try? shell.run()) != nil {
            shell.waitUntilExit()
            let p = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first { fm.isExecutableFile(atPath: $0) }
    }

    /// Called on the main queue when the engine process exits.
    var onExit: ((Int32) -> Void)?

    init(directory: URL) throws {
        // ponytail: dev mode runs the repo's engine with the user's node; a bundled Node SEA binary comes later.
        guard let node = Engine.nodePath() else { throw Failure(message: "Node.js wasn't found. Install it, or set VOICE_MAC_NODE.") }
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["--env-file=.env", "engine/rpc.ts"]
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        // whisper-server and ollama come from Homebrew; node's own folder too, for tools it spawns.
        env["PATH"] = URL(fileURLWithPath: node).deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["VOICE_MAC_AXD"] = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/axd").path
        process.environment = env
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            DispatchQueue.main.async { self?.receive(chunk) }
        }
        process.terminationHandler = { [weak self] p in DispatchQueue.main.async { self?.onExit?(p.terminationStatus) } }
        try process.run()
    }

    func stop() { process.terminate() }

    func call(_ method: String, _ params: [String: Any] = [:], done: @escaping (Result<[String: Any], Error>) -> Void) {
        let id = nextId
        nextId += 1
        waiting[id] = done
        guard var line = try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]) else {
            return done(.failure(Failure(message: "Couldn't encode the request.")))
        }
        line.append(0x0A)
        stdin.fileHandleForWriting.write(line)
    }

    private func receive(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if let id = obj["id"] as? Int, let done = waiting.removeValue(forKey: id) {
                if let err = obj["error"] as? [String: Any] {
                    done(.failure(Failure(message: err["message"] as? String ?? "Engine error.")))
                } else {
                    done(.success(obj["result"] as? [String: Any] ?? [:]))
                }
            } else if obj["event"] != nil {
                onEvent?(obj)
            }
        }
    }
}
