import Foundation

/// Pure, testable onboarding step machine. Persisted as the version of the onboarding the user last finished.
struct OnboardingState: Equatable {
    enum Step: Int, CaseIterable { case welcome, permissions, done }
    static let currentVersion = 1
    static let key = "onboardingVersion"

    var step: Step = .welcome

    static func needsOnboarding(stored: Int, current: Int = currentVersion) -> Bool { stored < current }
    static func needsOnboarding(_ d: UserDefaults = .standard) -> Bool { needsOnboarding(stored: d.integer(forKey: key)) }

    mutating func next() { step = Step(rawValue: step.rawValue + 1) ?? .done }
    mutating func skip() { step = .done }
    var isDone: Bool { step == .done }

    static func markCompleted(_ d: UserDefaults = .standard) { d.set(currentVersion, forKey: key) }
}
