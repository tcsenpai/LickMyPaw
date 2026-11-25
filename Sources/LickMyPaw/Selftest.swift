import Foundation

/// Named headless suites. `--selftest` runs all, `--selftest <name>` one. Each suite reports checks passed/failed and
/// how many checks actually REACHED the code under test (a green run that exercised nothing is not a pass).
final class TestCtx {
    var passed = 0, failed = 0, reached = 0
    func check(_ c: Bool, _ m: String) { print(c ? "  ok   " : "  FAIL ", m); if c { passed += 1 } else { failed += 1 } }
    func reachedCode(_ n: Int = 1) { reached += n }
}

typealias Suite = (name: String, run: @MainActor (TestCtx) async -> Void)

enum SelfTests {
    /// One line per module; each module owns its suite function in its own file.
    static let suites: [Suite] = [
        ("core", { await coreSuite($0) }),
        ("engine", { await EngineSelfTest.run($0) }),
        ("scanner", { await ScannerSelfTest.run($0) }),
        ("permissions", { await PermissionsSelfTest.run($0) }),
        ("cleanup", { await CleanupSelfTest.run($0) }),
        ("prefs", { await PrefsSelfTest.run($0) }),
        ("apps", { await AppsSelfTest.run($0) }),
        ("clutter", { await ClutterSelfTest.run($0) }),
        ("startup", { await StartupSelfTest.run($0) }),
        ("processes", { await ProcessesSelfTest.run($0) }),
    ]

    @MainActor static func main(only: String?) async -> Never {
        var bad = 0
        for s in suites where only == nil || only == s.name {
            print("== \(s.name)")
            let t = TestCtx(); await s.run(t)
            print("   \(s.name): \(t.passed) passed, \(t.failed) failed, \(t.reached) reached code under test")
            if t.failed > 0 || t.passed == 0 || t.reached == 0 { bad += 1; if t.passed > 0 && t.failed == 0 { print("   WARN: suite passed but never reached the code") } }
        }
        print(bad == 0 ? "SELFTEST PASS" : "SELFTEST FAIL (\(bad) suite(s))"); exit(bad == 0 ? 0 : 1)
    }
}

/// Engine suite (owned by the foundation): Safety + Engine.trash + undo on a fake home.
enum EngineSelfTest {
    @MainActor static func run(_ t: TestCtx) async {
        let f = Fixture(); defer { f.cleanup() }
        setenv("LICKMYPAW_HOME", f.home, 1); defer { unsetenv("LICKMYPAW_HOME") }
        let victim = f.file("home/stuff/a.bin", kb: 8)
        t.check(!Safety.check("/").ok && !Safety.check("/System/Library").ok && !Safety.check(f.home).ok, "deny-list refuses /, /System, home root"); t.reachedCode()
        t.check(!Safety.check(f.home + "/Library").ok && !Safety.check(f.home + "/Documents").ok, "protected home folders refused")
        t.check(Safety.check(victim).ok, "user-selected file under home allowed")
        t.check(!Safety.check(victim, mode: .automatic).ok, "automatic mode refuses outside allow-roots")
        let cache = f.file("home/Library/Caches/x/y.bin"); t.check(Safety.check(cache, mode: .automatic).ok, "automatic ok inside Library/Caches")
        let link = f.symlink("home/Library/Caches/evil", to: "/System"); t.check(!Safety.check(link, mode: .automatic).ok, "symlink to /System resolved and refused")
        let e = try? Engine.trash(victim, size: 8192)
        t.check(e != nil && !FileManager.default.fileExists(atPath: victim), "trash moves file away"); t.reachedCode()
        t.check(ActionLog.all().count == 1 && ActionLog.all()[0].path == victim, "action logged")
        if let e { try? Engine.undo(e) }
        t.check(FileManager.default.fileExists(atPath: victim) && ActionLog.all()[0].undone, "undo restores and marks log")
        t.check((try? Engine.trash("/System", mode: .userSelected)) == nil, "Engine.trash refuses protected path")
    }
}
