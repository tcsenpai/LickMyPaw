import Foundation

/// STUB (task T125/T126 owner replaces this file). Contract used by Safety/Scanner: Prefs.exclusions.
enum Prefs {
    static var exclusions: [String] { UserDefaults.standard.stringArray(forKey: "exclusions") ?? [] }
}

enum PrefsSelfTest { @MainActor static func run(_ t: TestCtx) async { /* TODO */ } }
