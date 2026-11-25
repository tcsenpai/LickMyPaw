import Foundation
import AppKit
import SwiftUI

struct StartupItem: Identifiable, Equatable {
    enum Kind { case userAgent, systemAgent, systemDaemon }
    var id: String { path }
    let path: String
    let kind: Kind
    let label: String
    let program: String
    let runAtLoad: Bool
    let keepAlive: Bool
    let plistDisabled: Bool
    let appName: String?
    let appPath: String?
    let vendor: String
    let broken: Bool
    var loaded = false
    var disabled = false
    var name: String { appName ?? label }
    var editable: Bool { kind == .userAgent && !label.hasPrefix("com.apple.") }
}

/// Own control surface over launchd (user domain only). Real impl shells out to /bin/launchctl; tests inject a fake.
protocol LaunchAgentControl: Sendable {
    func isLoaded(label: String) -> Bool
    func isDisabled(label: String) -> Bool
    func disable(label: String) -> Result<Void, EngineError>
    func enable(label: String) -> Result<Void, EngineError>
}

struct StartupRoots {
    var userAgents: String, systemAgents: String, systemDaemons: String
    static func real() -> StartupRoots { .init(userAgents: Env.home + "/Library/LaunchAgents", systemAgents: "/Library/LaunchAgents", systemDaemons: "/Library/LaunchDaemons") }
}

enum StartupScanner {
    static func parse(_ path: String, kind: StartupItem.Kind) -> StartupItem {
        let d = NSDictionary(contentsOfFile: path)
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let label = (d?["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? stem
        let args = d?["ProgramArguments"] as? [String]
        let program = (d?["Program"] as? String) ?? args?.first ?? ""
        let ka: Bool = (d?["KeepAlive"] as? Bool) ?? ((d?["KeepAlive"] as? [String: Any])?.isEmpty == false)
        let app = (program + "/").range(of: ".app/").map { String((program + "/")[..<$0.lowerBound]) + ".app" }
        let appName = app.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
        // Unparseable plist or a missing absolute program path = Broken.
        let broken = d == nil || program.isEmpty || (program.hasPrefix("/") && !FileManager.default.fileExists(atPath: program))
        return StartupItem(path: path, kind: kind, label: label, program: program, runAtLoad: d?["RunAtLoad"] as? Bool ?? false, keepAlive: ka,
                           plistDisabled: d?["Disabled"] as? Bool ?? false, appName: appName, appPath: app, vendor: vendor(label), broken: broken)
    }

    /// Vendor guess from the reverse-DNS prefix: com.google.keystone -> Google.
    static func vendor(_ label: String) -> String {
        let p = label.split(separator: ".").map(String.init)
        let tlds: Set<String> = ["com", "org", "net", "io", "de", "it", "fr", "co", "app", "dev", "me"]
        guard let f = p.first else { return "" }
        let v = (tlds.contains(f.lowercased()) && p.count > 1) ? p[1] : f
        return v.prefix(1).uppercased() + v.dropFirst()
    }

    static func scan(_ roots: StartupRoots, control: LaunchAgentControl) -> [StartupItem] {
        var out: [StartupItem] = []
        for (dir, kind) in [(roots.userAgents, StartupItem.Kind.userAgent), (roots.systemAgents, .systemAgent), (roots.systemDaemons, .systemDaemon)] {
            for e in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() where e.hasSuffix(".plist") {
                var it = parse(dir + "/" + e, kind: kind)
                if kind == .userAgent { it.loaded = control.isLoaded(label: it.label); it.disabled = control.isDisabled(label: it.label) || it.plistDisabled }
                out.append(it)
            }
        }
        return out
    }
}

struct SystemLaunchAgentControl: LaunchAgentControl {
    private func run(_ args: [String]) -> (Int32, String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit(); return (p.terminationStatus, out)
    }
    private func guardUser(_ label: String) -> EngineError? {
        if geteuid() == 0 { return EngineError(message: "Refused: running as root") }
        if label.isEmpty || label.hasPrefix("com.apple.") || label.contains("/") { return EngineError(message: "Refused: protected label \(label)") }
        return nil
    }
    func isLoaded(label: String) -> Bool { run(["print", "gui/\(getuid())/\(label)"]).0 == 0 }
    func isDisabled(label: String) -> Bool {
        let (c, out) = run(["print-disabled", "gui/\(getuid())"])
        guard c == 0 else { return false }
        return out.split(separator: "\n").contains { $0.contains("\"\(label)\"") && ($0.contains("=> disabled") || $0.contains("=> true")) }
    }
    func disable(label: String) -> Result<Void, EngineError> {
        if let e = guardUser(label) { return .failure(e) }
        let (c, o) = run(["disable", "gui/\(getuid())/\(label)"])
        guard c == 0 else { return .failure(EngineError(message: "launchctl disable failed (\(c)): \(o)")) }
        if isLoaded(label: label) { _ = run(["bootout", "gui/\(getuid())/\(label)"]) }   // best effort: it is disabled either way
        return .success(())
    }
    func enable(label: String) -> Result<Void, EngineError> {
        if let e = guardUser(label) { return .failure(e) }
        let (c, o) = run(["enable", "gui/\(getuid())/\(label)"])
        return c == 0 ? .success(()) : .failure(EngineError(message: "launchctl enable failed (\(c)): \(o)"))
    }
}

@MainActor final class StartupModel: ObservableObject {
    static let shared = StartupModel()
    @Published var items: [StartupItem] = []
    @Published var scanning = false
    @Published var savedAt: Date?
    @Published var stale = false
    @Published var message: String?
    var control: LaunchAgentControl
    var roots: StartupRoots?
    private var token: NSObjectProtocol?

    init(control: LaunchAgentControl = SystemLaunchAgentControl(), roots: StartupRoots? = nil) {
        self.control = control; self.roots = roots
        // queue: nil + hop to the main actor. `queue: .main` DEADLOCKS when Engine.trash posts from the main thread (e.g. trashing a broken plist from the UI).
        token = NotificationCenter.default.addObserver(forName: Engine.didChange, object: nil, queue: nil) { [weak self] n in
            let op = n.userInfo?["op"] as? String ?? "", paths = n.userInfo?["paths"] as? [String] ?? []
            Task { @MainActor in self?.handleEngineChange(op: op, paths: paths) }
        }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }

    func scanIfNeeded() { if savedAt == nil && !scanning { scan() } }
    func scan() {
        scanning = true; message = nil
        let r = roots ?? .real(), c = control
        Task {
            let res = await Task.detached { StartupScanner.scan(r, control: c) }.value
            withAnimation(spring) { items = res; savedAt = Date(); stale = false; scanning = false }
        }
    }

    func handleEngineChange(op: String, paths: [String]) {
        let before = items.count
        if op == "trash" { items.removeAll { i in paths.contains { Safety.under(i.path, $0) } } }
        if before > 0 { stale = true }
    }

    /// Reversible: disable (and unload) or enable. User agents only, never com.apple.*.
    func toggle(_ item: StartupItem) {
        guard item.editable, let i = items.firstIndex(where: { $0.id == item.id }) else { message = TT("Only your own agents can be changed", "Startup"); return }
        let r = item.disabled ? control.enable(label: item.label) : control.disable(label: item.label)
        switch r {
        case .failure(let e): message = e.message
        case .success:
            withAnimation(spring) {
                items[i].disabled = control.isDisabled(label: item.label)
                items[i].loaded = control.isLoaded(label: item.label)
            }
            message = nil
        }
    }

    /// Broken user agents only: plist goes to Trash through Engine (logged, undoable).
    func trash(_ item: StartupItem) {
        guard item.kind == .userAgent, item.broken, !item.label.hasPrefix("com.apple.") else { message = TT("Only broken user agents can be moved to Trash", "Startup"); return }
        let size = ((try? FileManager.default.attributesOfItem(atPath: item.path)[.size]) as? NSNumber)?.int64Value ?? 0
        do { try Engine.trash(item.path, size: size, mode: .userSelected); message = nil }
        catch { message = error.localizedDescription }
        // Engine.didChange also arrives via the notification; dropping is idempotent
        withAnimation(spring) { handleEngineChange(op: "trash", paths: FileManager.default.fileExists(atPath: item.path) ? [] : [item.path]) }
    }
}
