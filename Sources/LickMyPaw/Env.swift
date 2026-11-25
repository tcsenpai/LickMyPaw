import Foundation

/// Path injection so tests never touch the real home. LICKMYPAW_HOME=/tmp/fake redirects home, support dir and Trash.
enum Env {
    static var fake: Bool { ProcessInfo.processInfo.environment["LICKMYPAW_HOME"] != nil }
    static var home: String { ProcessInfo.processInfo.environment["LICKMYPAW_HOME"] ?? NSHomeDirectory() }
    static var supportDir: String { home + "/Library/Application Support/LickMyPaw" }
    static var trashDir: String { home + "/.Trash" }
}
