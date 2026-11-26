import Foundation

/// Extra Cleanup categories: Mail downloads, iOS device backups, Simulator devices, Xcode DeviceSupport and Archives.
/// Declarative like the rest of CleanupTargets; deletion stays in CleanupModel.clean (Safety automatic + Engine.trash).
enum CleanupExtra {
    static let userCat = "User junk", devCat = "Developer junk"

    static let targets: [CleanupTarget] = [
        .init(id: "mail", name: "Mail downloads", category: userCat, icon: "envelope", roots: ["/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"], risk: .medium,
              skipWhenRunning: ["com.apple.mail"]),
        .init(id: "backups", name: "iOS device backups", category: userCat, icon: "iphone.and.arrow.forward", roots: [], risk: .high, custom: backups),
        .init(id: "simdevices", name: "Simulator devices", category: devCat, icon: "iphone", roots: [], risk: .medium,
              skipWhenRunning: ["com.apple.iphonesimulator"], custom: simDevices),
        .init(id: "devsupport", name: "Xcode iOS DeviceSupport", category: devCat, icon: "hammer", roots: ["/Library/Developer/Xcode/iOS DeviceSupport"], risk: .low),
        .init(id: "archives", name: "Xcode Archives", category: devCat, icon: "archivebox", roots: [], risk: .high, custom: archives),
    ]

    private static func subdirs(_ p: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: p)) ?? []).sorted().filter { !$0.hasPrefix(".") }
    }
    private static func plist(_ p: String) -> [String: Any] { NSDictionary(contentsOfFile: p) as? [String: Any] ?? [:] }
    static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: d)
    }

    /// One entry per backup folder (named by UDID), labelled with the device name and last backup date from its Info.plist.
    @Sendable static func backups(_ home: String) -> [(path: String, name: String)] {
        let root = home + "/Library/Application Support/MobileSync/Backup"
        return subdirs(root).map { k in
            let i = plist(root + "/" + k + "/Info.plist")
            let dev = (i["Device Name"] as? String) ?? (i["Display Name"] as? String)
            let d = (i["Last Backup Date"] as? Date).map(day)
            return (root + "/" + k, [dev ?? k, d].compactMap { $0 }.joined(separator: ", "))
        }
    }

    /// CoreSimulator/Devices/<UUID> with device.plist; booted devices (state 3) are never offered. No simctl.
    @Sendable static func simDevices(_ home: String) -> [(path: String, name: String)] {
        let root = home + "/Library/Developer/CoreSimulator/Devices"
        var isDir: ObjCBool = false
        return subdirs(root).compactMap { k in
            guard FileManager.default.fileExists(atPath: root + "/" + k, isDirectory: &isDir), isDir.boolValue else { return nil }   // device_set.plist etc.
            let i = plist(root + "/" + k + "/device.plist")
            if (i["state"] as? Int) == 3 { return nil }
            return (root + "/" + k, [i["name"] as? String ?? k, (i["runtime"] as? String).map(runtimeName).map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
        }
    }
    /// com.apple.CoreSimulator.SimRuntime.iOS-17-0 -> "iOS 17.0"
    static func runtimeName(_ r: String) -> String {
        let parts = (r.components(separatedBy: ".").last ?? r).components(separatedBy: "-")
        return parts.count > 1 ? parts[0] + " " + parts.dropFirst().joined(separator: ".") : r
    }

    /// Archives/<date>/<Name>.xcarchive, one entry per archive.
    @Sendable static func archives(_ home: String) -> [(path: String, name: String)] {
        let root = home + "/Library/Developer/Xcode/Archives"
        return subdirs(root).flatMap { d in
            subdirs(root + "/" + d).filter { $0.hasSuffix(".xcarchive") }.map { a in
                let i = plist(root + "/" + d + "/" + a + "/Info.plist")
                let n = (i["Name"] as? String) ?? String(a.dropLast(".xcarchive".count))
                return (root + "/" + d + "/" + a, [n, (i["CreationDate"] as? Date).map(day)].compactMap { $0 }.joined(separator: ", "))
            }
        }
    }
}

enum CleanupExtraSelfTest {
    @MainActor static func run(_ t: TestCtx) async {
        let f = Fixture(); defer { f.cleanup() }
        setenv("LICKMYPAW_HOME", f.home, 1); defer { unsetenv("LICKMYPAW_HOME") }
        let savedRun = CleanupTargets.runningIDs, savedEx = UserDefaults.standard.stringArray(forKey: "exclusions")
        defer { CleanupTargets.runningIDs = savedRun; UserDefaults.standard.set(savedEx, forKey: "exclusions") }
        UserDefaults.standard.removeObject(forKey: "exclusions")
        func plist(_ rel: String, _ d: [String: Any]) {
            let p = f.root + "/" + rel
            try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0).write(to: URL(fileURLWithPath: p))
        }
        let L = "home/Library/"
        let day = Date(timeIntervalSince1970: 1_767_225_600)   // 2026-01-01 UTC
        f.file(L + "Containers/com.apple.mail/Data/Library/Mail Downloads/ABC/invoice.pdf", kb: 40)
        f.file(L + "Containers/com.apple.mail/Data/Library/Mail Downloads/XYZ/photo.jpg", kb: 20)
        f.file(L + "Application Support/MobileSync/Backup/00008030-AAAA/Manifest.db", kb: 500)
        plist(L + "Application Support/MobileSync/Backup/00008030-AAAA/Info.plist", ["Device Name": "Mario's iPhone", "Last Backup Date": day])
        f.file(L + "Application Support/MobileSync/Backup/NOPLIST/Manifest.db", kb: 100)
        f.file(L + "Developer/CoreSimulator/Devices/UUID-1/data/x.bin", kb: 300)
        plist(L + "Developer/CoreSimulator/Devices/UUID-1/device.plist", ["name": "iPhone 15", "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-17-0", "state": 1])
        f.file(L + "Developer/CoreSimulator/Devices/UUID-2/data/y.bin", kb: 300)
        plist(L + "Developer/CoreSimulator/Devices/UUID-2/device.plist", ["name": "iPad Pro", "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-17-0", "state": 3])
        plist(L + "Developer/CoreSimulator/Devices/device_set.plist", ["x": 1])
        f.file(L + "Developer/Xcode/iOS DeviceSupport/17.2 (21C62) arm64e/Symbols/s.bin", kb: 200)
        f.file(L + "Developer/Xcode/Archives/2026-01-01/MyApp 1-1-26.xcarchive/Products/a.bin", kb: 150)
        plist(L + "Developer/Xcode/Archives/2026-01-01/MyApp 1-1-26.xcarchive/Info.plist", ["Name": "MyApp", "CreationDate": day])
        f.file(L + "Developer/Xcode/Archives/2026-01-01/stray.txt", kb: 4)
        let outside = f.file("home/Documents/keep.txt")

        CleanupTargets.runningIDs = { [] }
        func items(_ id: String, running: Set<String> = []) -> [CleanItem] { CleanupTargets.items(CleanupTargets.all.first { $0.id == id }!, running: running) }
        t.check(["mail", "backups", "simdevices", "devsupport", "archives"].allSatisfy { id in CleanupTargets.all.contains { $0.id == id } }, "all five targets registered")

        let mail = items("mail"); t.reachedCode()
        t.check(Set(mail.map(\.name)) == ["ABC", "XYZ"] && mail.allSatisfy { $0.risk == .medium }, "mail downloads: one entry per attachment folder, medium risk")
        t.check(items("mail", running: ["com.apple.mail"]).isEmpty, "mail running -> nothing offered")

        let bk = items("backups"); t.reachedCode()
        t.check(Set(bk.map(\.name)) == ["Mario's iPhone, 2026-01-01", "NOPLIST"] && bk.allSatisfy { $0.risk == .high }, "backups: device name + date from Info.plist, folder name fallback, high risk (\(bk.map(\.name)))")
        t.check(bk.first { $0.name == "NOPLIST" }?.size == 100 << 10, "backup size counted")

        let sd = items("simdevices"); t.reachedCode()
        t.check(sd.map(\.name) == ["iPhone 15 (iOS 17.0)"], "simulators: named from device.plist, booted device and device_set.plist skipped (\(sd.map(\.name)))")
        t.check(items("simdevices", running: ["com.apple.iphonesimulator"]).isEmpty, "Simulator running -> nothing offered")
        t.check(CleanupExtra.runtimeName("com.apple.CoreSimulator.SimRuntime.watchOS-10-2") == "watchOS 10.2" && CleanupExtra.runtimeName("weird") == "weird", "runtime name parsing")

        t.check(items("devsupport").map(\.name) == ["17.2 (21C62) arm64e"] && items("devsupport")[0].risk == .low, "DeviceSupport: one entry per OS build, low risk")
        let ar = items("archives")
        t.check(ar.map(\.name) == ["MyApp, 2026-01-01"] && ar[0].risk == .high, "archives: one entry per .xcarchive (stray file ignored), high risk")

        // default selection: only low risk is pre-checked, so backups, archives, sims and mail start unchecked
        let m = CleanupModel(scanFn: { CleanupModel.defaultScan() })
        m.scan(); await m.scanTask?.value
        let sel = Set(m.selectedItems.map(\.targetID))
        t.check(sel.contains("devsupport") && !sel.contains("backups") && !sel.contains("archives") && !sel.contains("simdevices") && !sel.contains("mail"), "default selection leaves risky categories unchecked (\(sel.sorted()))")

        // exclusions honoured
        UserDefaults.standard.set([f.home + "/Library/Application Support/MobileSync/Backup/NOPLIST"], forKey: "exclusions")
        t.check(items("backups").count == 1, "Prefs.exclusions honoured by custom enumeration")
        UserDefaults.standard.removeObject(forKey: "exclusions")

        // deletion goes through Safety (automatic) + Engine.trash, logged and undoable
        let (ok, bad) = CleanupModel.clean(bk + sd + ar + mail + items("devsupport")); t.reachedCode()
        let fm = FileManager.default
        t.check(ok.count == bk.count + sd.count + ar.count + mail.count + 1 && bad.isEmpty, "all new categories trash cleanly (\(bad))")
        t.check(bk.allSatisfy { !fm.fileExists(atPath: $0.path) } && fm.fileExists(atPath: f.home + "/Library/Developer/CoreSimulator/Devices/UUID-2") && fm.fileExists(atPath: outside), "gone from disk; booted simulator and outside file untouched")
        t.check(ActionLog.all().count == ok.count && ok.allSatisfy { $0.trashedTo.map { fm.fileExists(atPath: $0) } == true }, "logged, items sit in the fake Trash")
        try? Engine.undo(ok.first { $0.path.contains("00008030") }!)
        t.check(fm.fileExists(atPath: f.home + "/Library/Application Support/MobileSync/Backup/00008030-AAAA/Manifest.db"), "undo restores a backup")

        // Safety: allow-list is exact, nothing else under those parents is reachable
        let (_, bad2) = CleanupModel.clean([CleanItem(path: f.home + "/Library/Application Support/Other", name: "x", size: 1, targetID: "backups", risk: .high),
                                            CleanItem(path: f.home + "/Library/Developer/Xcode/UserData", name: "x", size: 1, targetID: "archives", risk: .high)])
        t.check(bad2.count == 2, "automatic mode refuses siblings of the new allow-roots")
    }
}
