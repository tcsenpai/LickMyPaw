import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Assistant core (plan 28): availability gating + backend protocol. On-device model only, no network.
// The app still supports macOS 13: FoundationModels is compiled in only when the SDK has it and used only on macOS 26+.

private func A(_ k: String) -> String { TT(k, "Assistant") }

/// Why the assistant can or cannot run on this Mac. Every non-available case explains itself and, when the user can fix it, says how.
enum AssistantAvailability: Equatable {
    case available
    case notBuilt            // this build was compiled with an SDK that has no FoundationModels
    case osTooOld            // macOS older than 26
    case deviceNotEligible   // e.g. Intel Mac
    case intelligenceOff     // Apple Intelligence is turned off in System Settings
    case modelNotReady       // the model is still downloading or being prepared
    case unknown             // a reason added by a future macOS

    /// Pure gate, testable without the framework: build first, then OS, then what the model reports.
    static func resolve(compiled: Bool, osSupported: Bool, model: AssistantAvailability) -> AssistantAvailability {
        !compiled ? .notBuilt : !osSupported ? .osTooOld : model
    }

    var title: String {
        switch self {
        case .available: return A("The assistant is ready")
        case .notBuilt: return A("This version of LickMyPaw was built without the assistant")
        case .osTooOld: return A("The assistant needs macOS 26 or later")
        case .deviceNotEligible: return A("This Mac does not support Apple Intelligence")
        case .intelligenceOff: return A("Apple Intelligence is turned off")
        case .modelNotReady: return A("Apple Intelligence is still getting ready")
        case .unknown: return A("The assistant is not available right now")
        }
    }

    /// What the user can do about it. nil when there is nothing to do; the rest of the app works the same either way.
    var help: String? {
        switch self {
        case .available, .deviceNotEligible: return nil
        case .notBuilt: return A("Update LickMyPaw to a version that includes it.")
        case .osTooOld: return A("Update macOS to use it. Everything else in LickMyPaw works as usual.")
        case .intelligenceOff: return A("Turn it on in System Settings, Apple Intelligence & Siri. The model runs on this Mac.")
        case .modelNotReady: return A("macOS is downloading the model. Keep the Mac on power and connected, then try again later.")
        case .unknown: return A("Try again later.")
        }
    }

    /// shortcut: Settings pane id read from the system extension list (com.apple.Siri-Settings.extension), not opened in a test; verify by hand.
    var settingsURL: URL? {
        self == .intelligenceOff || self == .modelNotReady ? URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") : nil
    }
}

/// The only way the app talks to a language model. Real = FoundationModels, fake = scripted, so tools and safety rules test headless.
protocol AssistantBackend: AnyObject {
    var availability: AssistantAvailability { get }
    /// The model the next answer comes from (nil when unavailable).
    var engine: AssistantEngine? { get }
    /// Loads the model ahead of the first question (cold start is seconds). No-op when unavailable.
    func prewarm()
    func respond(to prompt: String) async throws -> String
    /// Same, reporting the text generated so far while it streams.
    func respond(to prompt: String, onPartial: @escaping @MainActor (String) -> Void) async throws -> String
    /// Drops the conversation (the on-device context is small: ~4k tokens).
    func reset()
}

extension AssistantBackend {
    func respond(to prompt: String, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        let r = try await respond(to: prompt); await onPartial(r); return r
    }
}

/// The conversation outgrew the model's context; the backend has already started a fresh one.
struct AssistantContextFull: Error {}

struct AssistantUnavailable: Error, Equatable { let reason: AssistantAvailability }

/// Which model answers. macOS 26: on-device only (~4k tokens). macOS 27 adds Apple's Private Cloud Compute model (32k tokens),
/// used only when the user allows it; any cloud failure (quota, network) falls back to on-device for that answer.
enum AssistantEngine: Equatable {
    case onDevice, cloud
    static func pick(local: AssistantAvailability, cloudAvailable: Bool, allowCloud: Bool) -> AssistantEngine? {
        if allowCloud && cloudAvailable && local == .available { return .cloud }
        return local == .available ? .onDevice : nil
    }
}

/// Stands in when the assistant cannot run: says why, never pretends to answer.
final class UnavailableBackend: AssistantBackend {
    let availability: AssistantAvailability
    init(_ reason: AssistantAvailability) { availability = reason }
    var engine: AssistantEngine? { nil }
    func prewarm() {}
    func respond(to prompt: String) async throws -> String { throw AssistantUnavailable(reason: availability) }
    func reset() {}
}

/// Scripted backend for tests: answers in order and records what it was asked.
final class ScriptedBackend: AssistantBackend {
    var availability: AssistantAvailability = .available
    var engine: AssistantEngine? { availability == .available ? .onDevice : nil }
    var replies: [String]
    private(set) var prompts: [String] = []
    private(set) var prewarmed = 0, resets = 0
    var onRespond: () -> Void = {}   // lets a test act like a tool call happening during the answer
    init(_ replies: [String]) { self.replies = replies }
    func prewarm() { prewarmed += 1 }
    func respond(to prompt: String) async throws -> String {
        guard availability == .available else { throw AssistantUnavailable(reason: availability) }
        prompts.append(prompt); onRespond()
        return replies.isEmpty ? "" : replies.removeFirst()
    }
    func reset() { prompts = []; resets += 1 }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
final class FoundationModelsBackend: AssistantBackend {
    private let instructions: String
    private let tools: [any Tool]
    private let allowCloud: Bool
    private var session: LanguageModelSession?
    private var sessionEngine: AssistantEngine?
    private var cloudFailed = false   // after a quota or network error, stay on-device until reset()
    init(instructions: String, tools: [any Tool] = [], allowCloud: Bool = false) { self.instructions = instructions; self.tools = tools; self.allowCloud = allowCloud }

    var availability: AssistantAvailability { Self.map(SystemLanguageModel.default.availability) }
    var engine: AssistantEngine? { AssistantEngine.pick(local: availability, cloudAvailable: !cloudFailed && Self.cloudAvailable, allowCloud: allowCloud) }

    static func map(_ a: SystemLanguageModel.Availability) -> AssistantAvailability {
        switch a {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .intelligenceOff
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable: return .unknown
        }
    }

    /// Private Cloud Compute needs the macOS 27 SDK (Swift 6.4 toolchain) to compile and macOS 27 to run; otherwise it simply is not there.
    static var cloudAvailable: Bool {
        #if compiler(>=6.4)
        if #available(macOS 27, *) { return PrivateCloudComputeLanguageModel().isAvailable }
        #endif
        return false
    }

    private func current() -> LanguageModelSession {
        let e = engine ?? .onDevice
        if let s = session, sessionEngine == e { return s }
        var s = LanguageModelSession(tools: tools, instructions: instructions)
        #if compiler(>=6.4)
        if e == .cloud, #available(macOS 27, *) { s = LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, instructions: instructions) }
        #endif
        session = s; sessionEngine = e; return s
    }
    func prewarm() { if availability == .available { current().prewarm() } }
    func respond(to prompt: String) async throws -> String { try await respond(to: prompt) { _ in } }
    func respond(to prompt: String, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        guard availability == .available else { throw AssistantUnavailable(reason: availability) }
        do { return try await stream(prompt, onPartial) }
        catch {
            if case LanguageModelSession.GenerationError.exceededContextWindowSize = error { reset(); throw AssistantContextFull() }
            guard sessionEngine == .cloud else { throw error }
            // shortcut: the on-device retry starts a fresh conversation (the 32k cloud transcript does not fit in ~4k); carry a summary if that hurts
            cloudFailed = true
            return try await stream(prompt, onPartial)
        }
    }
    private func stream(_ prompt: String, _ onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        var last = ""
        for try await snap in current().streamResponse(to: prompt) { last = snap.content; await onPartial(last) }
        return last
    }
    func reset() { session = nil; sessionEngine = nil; cloudFailed = false }
}
#endif

enum Assistant {
    static var compiled: Bool {
        #if canImport(FoundationModels)
        return true
        #else
        return false
        #endif
    }

    /// Private Cloud Compute is offered (as an opt-in) only when this build and this Mac both have it.
    static var cloudOffered: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return FoundationModelsBackend.cloudAvailable }
        #endif
        return false
    }

    /// A model error as an English key in the Assistant table (shown in the chat, never a raw error dump).
    static func friendly(_ e: Error) -> String {
        if e is AssistantContextFull { return "The conversation got too long, so a new one was started. Ask again." }
        if let u = e as? AssistantUnavailable { return u.reason.title }
        #if canImport(FoundationModels)
        if #available(macOS 26, *), let g = e as? LanguageModelSession.GenerationError {
            switch g {
            case .guardrailViolation: return "Apple's safety filter stopped this answer. Try asking in a different way."
            case .unsupportedLanguageOrLocale: return "Apple Intelligence does not support this language yet. Try English."
            case .exceededContextWindowSize: return "The conversation got too long, so a new one was started. Ask again."
            default: break
            }
        }
        #endif
        return "Something went wrong while answering. Try again."
    }

    /// The backend for this Mac: the real model when everything lines up, otherwise one that explains why not.
    static func makeBackend(instructions: String, data: AssistantData? = nil, onToolUse: @escaping @Sendable (String) -> Void = { _ in }, allowCloud: Bool = false) -> AssistantBackend {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let b = FoundationModelsBackend(instructions: instructions, tools: data.map { AssistantToolbox.make($0, onUse: onToolUse) } ?? [], allowCloud: allowCloud)
            return b.availability == .available ? b : UnavailableBackend(b.availability)
        }
        return UnavailableBackend(.osTooOld)
        #else
        return UnavailableBackend(.notBuilt)
        #endif
    }
}

/// Assistant suite: gating, explanations, fake backend. The real model is only touched with LICKMYPAW_LIVE_AI=1 (CI has none).
enum AssistantSelfTest {
    @MainActor static func run(_ t: TestCtx) async {
        typealias AV = AssistantAvailability
        t.check(AV.resolve(compiled: false, osSupported: true, model: .available) == .notBuilt, "gate: no framework in the build wins over everything"); t.reachedCode()
        t.check(AV.resolve(compiled: true, osSupported: false, model: .available) == .osTooOld, "gate: old macOS never reaches the model")
        t.check(AV.resolve(compiled: true, osSupported: true, model: .intelligenceOff) == .intelligenceOff && AV.resolve(compiled: true, osSupported: true, model: .available) == .available, "gate: otherwise the model decides")

        let all: [AV] = [.available, .notBuilt, .osTooOld, .deviceNotEligible, .intelligenceOff, .modelNotReady, .unknown]
        t.check(Set(all.map(\.title)).count == all.count && all.allSatisfy { !$0.title.isEmpty }, "every state has its own title")
        t.check(all.filter { $0 != .available && $0 != .deviceNotEligible }.allSatisfy { !($0.help ?? "").isEmpty }, "every state the user can act on says how")
        t.check(all.filter { $0.settingsURL != nil } == [.intelligenceOff, .modelNotReady], "Settings link only where Settings can fix it")

        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            typealias M = FoundationModelsBackend
            t.check(M.map(.available) == .available && M.map(.unavailable(.deviceNotEligible)) == .deviceNotEligible
                    && M.map(.unavailable(.appleIntelligenceNotEnabled)) == .intelligenceOff && M.map(.unavailable(.modelNotReady)) == .modelNotReady,
                    "system reasons map to our states"); t.reachedCode()
        }
        #endif
        typealias E = AssistantEngine
        t.check(E.pick(local: .available, cloudAvailable: false, allowCloud: true) == .onDevice, "engine: macOS 26 (no cloud model) stays on-device")
        t.check(E.pick(local: .available, cloudAvailable: true, allowCloud: false) == .onDevice, "engine: cloud never used unless the user allows it")
        t.check(E.pick(local: .available, cloudAvailable: true, allowCloud: true) == .cloud, "engine: macOS 27 with cloud allowed uses the bigger model")
        t.check(E.pick(local: .intelligenceOff, cloudAvailable: true, allowCloud: true) == nil, "engine: Apple Intelligence off means no model at all, cloud included")

        let real = Assistant.makeBackend(instructions: "test")
        print("  info this Mac: compiled=\(Assistant.compiled) availability=\(real.availability) engine=\(String(describing: real.engine))")
        t.check(real.engine != .cloud, "factory: cloud is off by default")
        t.check(real.availability == .available || real is UnavailableBackend, "factory: an unavailable Mac gets the explaining backend, never a broken one")

        let off = UnavailableBackend(.intelligenceOff); off.prewarm()
        do { _ = try await off.respond(to: "hi"); t.check(false, "unavailable backend refuses to answer") }
        catch { t.check(error as? AssistantUnavailable == AssistantUnavailable(reason: .intelligenceOff), "unavailable backend refuses to answer, with the reason") }

        let fake = ScriptedBackend(["one", "two"]); fake.prewarm()
        let a1 = try? await fake.respond(to: "q1"), a2 = try? await fake.respond(to: "q2")
        t.check(a1 == "one" && a2 == "two" && fake.prompts == ["q1", "q2"] && fake.prewarmed == 1, "scripted backend answers in order and records prompts")
        fake.reset(); fake.availability = .modelNotReady
        t.check((try? await fake.respond(to: "q3")) == nil && fake.prompts.isEmpty && fake.resets == 1, "reset drops the conversation; not ready refuses")

        if ProcessInfo.processInfo.environment["LICKMYPAW_LIVE_AI"] == "1", real.availability == .available {
            let r = try? await real.respond(to: "Reply with the single word: ready")
            t.check(!(r ?? "").isEmpty, "live: the on-device model answers (\(r ?? "nil"))"); t.reachedCode()
            let cloud = Assistant.makeBackend(instructions: "test", allowCloud: true)
            if cloud.engine == .cloud && ProcessInfo.processInfo.environment["LICKMYPAW_LIVE_CLOUD"] == "1" {   // a real request to Apple's servers: separate opt-in
                let rc = try? await cloud.respond(to: "Reply with the single word: ready")
                t.check(!(rc ?? "").isEmpty, "live: the cloud model answers (\(rc ?? "nil"))")
            } else { print("  info live cloud check skipped (engine=\(String(describing: cloud.engine)); needs Private Cloud Compute and LICKMYPAW_LIVE_CLOUD=1)") }
        } else { print("  info live model check skipped (set LICKMYPAW_LIVE_AI=1 on a Mac with Apple Intelligence)") }
    }
}
