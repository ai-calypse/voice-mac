// axd: a long-running accessibility helper for the Voice Mac engine. Newline-delimited JSON on stdio:
// {"id", "cmd", ...} → {"id", "result"} | {"id", "error"}. Reads and acts through AXUIElement in this
// process, so a press costs milliseconds instead of a driver round trip.
// Reading approach adapted from Computah's AXReader/AXActor (github.com/musubipapi/computah, MIT).
import AppKit
import ApplicationServices
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

struct Failure: Error { let message: String }

// The elements of the latest snapshot, addressed by index. A new snapshot replaces them, so a stale
// index from an older read can't act on the wrong control: requests carry the snapshot number.
var handles: [AXUIElement] = []
var snapshotId = 0

func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func element(_ v: CFTypeRef?) -> AXUIElement? {
    guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}
func text(_ v: Any?) -> String {
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    if let u = v as? URL { return u.absoluteString }
    return ""
}
func attrs(_ e: AXUIElement, _ names: [String]) -> [String: Any] {
    var values: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(e, names as CFArray, [], &values) == .success,
          let list = values as? [Any], list.count == names.count else { return [:] }
    return Dictionary(uniqueKeysWithValues: zip(names, list).map { ($0, $1) })
}
func frame(_ a: [String: Any]) -> CGRect? {
    guard let p = a["AXPosition"], let s = a["AXSize"],
          CFGetTypeID(p as CFTypeRef) == AXValueGetTypeID(), CFGetTypeID(s as CFTypeRef) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: point, size: size)
}

func app(_ pid: pid_t) -> AXUIElement {
    let root = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(root, 0.2)
    // Chromium/Electron apps only expose their tree when asked (Computah's trick).
    AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, true as CFTypeRef)
    AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)
    return root
}

/// Breadth-first read of the focused window (visible parts only), plus the app's menu titles.
func snapshot(pid: pid_t, maxNodes: Int) throws -> [String: Any] {
    let root = app(pid)
    let window = element(attr(root, "AXFocusedWindow")) ?? element(attr(root, "AXMainWindow")) ?? (attr(root, "AXWindows") as? [AXUIElement])?.first
    handles = []
    snapshotId += 1
    var nodes: [[String: Any]] = []
    var queue: [(AXUIElement, Int?, Int, CGRect?)] = window.map { [($0, nil, 0, nil)] } ?? []
    var next = 0
    let deadline = Date().addingTimeInterval(1.5)
    while next < queue.count, nodes.count < maxNodes, Date() < deadline {
        let (e, parent, depth, clip) = queue[next]
        next += 1
        AXUIElementSetMessagingTimeout(e, 0.2)
        let a = attrs(e, ["AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXHelp", "AXValue", "AXEnabled", "AXHidden", "AXPosition", "AXSize", "AXFocused", "AXIdentifier", "AXPlaceholderValue"])
        if a["AXHidden"] as? Bool == true { continue }
        let role = text(a["AXRole"])
        let bounds = frame(a)
        if let clip, let bounds, !clip.intersects(bounds) { continue } // scrolled out of view
        var names: CFArray?
        AXUIElementCopyActionNames(e, &names)
        let label = [text(a["AXTitle"]), text(a["AXDescription"]), text(a["AXPlaceholderValue"]), text(a["AXHelp"])].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let secure = text(a["AXSubrole"]) == "AXSecureTextField"
        let index = nodes.count
        var node: [String: Any] = ["i": index, "role": role, "label": String(label.prefix(180)), "enabled": a["AXEnabled"] as? Bool ?? true, "depth": depth]
        let value = secure ? "" : text(a["AXValue"])
        if !value.isEmpty { node["value"] = String(value.prefix(2000)) }
        if let parent { node["parent"] = parent }
        if let acts = names as? [String], !acts.isEmpty { node["actions"] = acts }
        if a["AXFocused"] as? Bool == true { node["focused"] = true }
        if let bounds { node["frame"] = [bounds.minX, bounds.minY, bounds.width, bounds.height] }
        nodes.append(node)
        handles.append(e)
        let scrolls = ["AXScrollArea", "AXTable", "AXOutline", "AXList", "AXWebArea"].contains(role)
        let childClip = scrolls ? (bounds.map { b in clip.map { $0.intersection(b) } ?? b } ?? clip) : clip
        if depth < 35, let children = attr(e, "AXChildren") as? [AXUIElement] {
            for c in children { queue.append((c, index, depth + 1, childClip)) }
        }
    }
    let running = NSRunningApplication(processIdentifier: pid)
    return ["snapshot": snapshotId, "pid": pid, "app": running?.localizedName ?? "", "window": window.map { text(attr($0, "AXTitle")) } ?? "",
            "has_window": window != nil, "nodes": nodes, "truncated": next < queue.count]
}

/// Menu paths (bar item › … › item) read without opening any menu; the Apple menu is left out.
func menus(pid: pid_t, limit: Int) -> [[String]] {
    guard let bar = element(attr(app(pid), "AXMenuBar")) else { return [] }
    var out: [[String]] = []
    func walk(_ e: AXUIElement, _ path: [String], _ depth: Int) {
        guard out.count < limit, depth < 4, let kids = attr(e, "AXChildren") as? [AXUIElement] else { return }
        for k in kids {
            let a = attrs(k, ["AXRole", "AXTitle", "AXEnabled"])
            let role = text(a["AXRole"]), title = text(a["AXTitle"]).trimmingCharacters(in: .whitespaces)
            if role == "AXMenu" { walk(k, path, depth + 1); continue }
            guard !title.isEmpty else { continue }
            if role == "AXMenuBarItem" { if title != "Apple" { walk(k, [title], depth + 1) }; continue }
            if role == "AXMenuItem" {
                let p = path + [title]
                if let sub = attr(k, "AXChildren") as? [AXUIElement], !sub.isEmpty { walk(k, p, depth + 1) }
                else if a["AXEnabled"] as? Bool ?? true { out.append(p) }
            }
        }
    }
    walk(bar, [], 0)
    return out
}

func target(_ req: [String: Any]) throws -> AXUIElement {
    guard let snap = req["snapshot"] as? Int, snap == snapshotId else { throw Failure(message: "stale: read the window again") }
    guard let i = req["i"] as? Int, handles.indices.contains(i) else { throw Failure(message: "no such element") }
    return handles[i]
}

func click(_ e: AXUIElement) throws {
    if AXUIElementPerformAction(e, kAXPressAction as CFString) == .success { return }
    // No AXPress: a real click at the element's center, after checking nothing covers it.
    guard let f = frame(attrs(e, ["AXPosition", "AXSize"])) else { throw Failure(message: "element has no press action or frame") }
    let p = CGPoint(x: f.midX, y: f.midY)
    let src = CGEventSource(stateID: .hidSystemState)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(20_000)
    }
}

let KEYS: [String: CGKeyCode] = ["return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46]

func key(_ name: String, mods: [String], pid: pid_t?) throws {
    guard let code = KEYS[name.lowercased()] else { throw Failure(message: "unknown key \(name)") }
    var flags: CGEventFlags = []
    for m in mods { switch m { case "cmd": flags.insert(.maskCommand); case "shift": flags.insert(.maskShift); case "option": flags.insert(.maskAlternate); case "ctrl": flags.insert(.maskControl); default: break } }
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let ev = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
        ev?.flags = flags
        if let pid { ev?.postToPid(pid) } else { ev?.post(tap: .cghidEventTap) }
        usleep(10_000)
    }
}

func typeText(_ s: String, pid: pid_t) {
    let src = CGEventSource(stateID: .hidSystemState)
    let units = Array(s.utf16)
    for start in stride(from: 0, to: units.count, by: 20) {
        let chunk = Array(units[start..<min(start + 20, units.count)])
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
            ev?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            ev?.postToPid(pid)
        }
        usleep(5_000)
    }
}

func setText(_ e: AXUIElement, _ value: String, pid: pid_t) throws {
    AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, true as CFTypeRef)
    if AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, value as CFTypeRef) == .success,
       text(attr(e, kAXValueAttribute as String)) == value { return }
    // Some editors refuse AXValue: select all, then type.
    try? click(e)
    try key("a", mods: ["cmd"], pid: pid)
    typeText(value, pid: pid)
}

func menu(pid: pid_t, path: [String]) throws {
    guard var current = element(attr(app(pid), "AXMenuBar")) else { throw Failure(message: "no menu bar") }
    for (n, title) in path.enumerated() {
        var container = current
        // A menu bar item or menu item holds its items inside one AXMenu child.
        if n > 0, let kids = attr(current, "AXChildren") as? [AXUIElement], let m = kids.first(where: { text(attr($0, "AXRole")) == "AXMenu" }) { container = m }
        guard let kids = attr(container, "AXChildren") as? [AXUIElement],
              let hit = kids.first(where: { text(attr($0, "AXTitle")).trimmingCharacters(in: .whitespaces) == title }) else {
            throw Failure(message: "menu item not found: \(path.prefix(n + 1).joined(separator: " › "))")
        }
        current = hit
    }
    guard AXUIElementPerformAction(current, kAXPressAction as CFString) == .success else { throw Failure(message: "menu item didn't respond") }
}

func scroll(pid: pid_t, down: Bool) {
    var center = CGPoint(x: 600, y: 400)
    if let w = element(attr(app(pid), "AXFocusedWindow")), let f = frame(attrs(w, ["AXPosition", "AXSize"])) { center = CGPoint(x: f.midX, y: f.midY) }
    let ev = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: down ? -8 : 8, wheel2: 0, wheel3: 0)
    ev?.location = center
    ev?.post(tap: .cghidEventTap)
}

/// Launch or activate an app by name and wait (up to 5 s) until its window answers accessibility.
func open(_ name: String) throws -> [String: Any] {
    let ws = NSWorkspace.shared
    var running = ws.runningApplications.first { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }
    if running == nil {
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        guard let url = dirs.map({ URL(fileURLWithPath: "\($0)/\(name).app") }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw Failure(message: "no app named \(name)")
        }
        let done = DispatchSemaphore(value: 0)
        ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, _ in running = app; done.signal() }
        _ = done.wait(timeout: .now() + 10)
    }
    guard let app = running else { throw Failure(message: "couldn't open \(name)") }
    app.activate()
    for _ in 0..<50 {
        if element(attr(AXUIElementCreateApplication(app.processIdentifier), "AXFocusedWindow")) != nil { break }
        usleep(100_000)
    }
    return ["pid": app.processIdentifier, "name": app.localizedName ?? name]
}

func handle(_ req: [String: Any]) throws -> Any {
    let pid = (req["pid"] as? Int).map { pid_t($0) }
    switch req["cmd"] as? String {
    case "trusted":
        if req["prompt"] as? Bool == true { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
        return ["trusted": AXIsProcessTrusted()]
    case "frontmost":
        let f = NSWorkspace.shared.frontmostApplication
        return ["pid": f?.processIdentifier ?? 0, "name": f?.localizedName ?? ""]
    case "open": return try open(req["name"] as? String ?? "")
    case "snapshot": return try snapshot(pid: pid ?? 0, maxNodes: req["max"] as? Int ?? 1500)
    case "menus": return ["paths": menus(pid: pid ?? 0, limit: req["limit"] as? Int ?? 400)]
    case "press": try click(target(req)); return ["ok": true]
    case "set": try setText(target(req), req["value"] as? String ?? "", pid: pid ?? 0); return ["ok": true]
    case "key": try key(req["key"] as? String ?? "", mods: req["mods"] as? [String] ?? [], pid: pid); return ["ok": true]
    case "menu": try menu(pid: pid ?? 0, path: req["path"] as? [String] ?? []); return ["ok": true]
    case "scroll": scroll(pid: pid ?? 0, down: req["down"] as? Bool ?? true); return ["ok": true]
    default: throw Failure(message: "unknown cmd")
    }
}

while let line = readLine() {
    guard let data = line.data(using: .utf8), let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
    var reply: [String: Any] = ["id": req["id"] ?? NSNull()]
    if !AXIsProcessTrusted(), req["cmd"] as? String != "trusted", req["cmd"] as? String != "frontmost" {
        reply["error"] = "not trusted: allow Voice Mac in System Settings → Privacy & Security → Accessibility"
    } else {
        do { reply["result"] = try handle(req) } catch let f as Failure { reply["error"] = f.message } catch { reply["error"] = "\(error)" }
    }
    if let out = try? JSONSerialization.data(withJSONObject: reply), let s = String(data: out, encoding: .utf8) { print(s) }
}
