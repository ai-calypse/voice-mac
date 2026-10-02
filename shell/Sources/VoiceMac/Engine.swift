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

    init(directory: URL) throws {
        // ponytail: dev mode runs the repo's engine with the system node; a bundled Node SEA binary comes later.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--env-file=.env", "engine/rpc.ts"]
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            DispatchQueue.main.async { self?.receive(chunk) }
        }
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
