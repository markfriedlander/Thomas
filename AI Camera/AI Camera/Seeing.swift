//
//  Seeing.swift
//  AI Camera
//
//  The machine's eye. Everything between "here is an image" and "here is what I saw."
//
//  ⚠️ Read CLAUDE.md Principle 3 before changing anything in this file.
//  The machine DECLARES. It does not hedge, apologize, or caveat. A refusal or a
//  guardrail hit is NOT an error to swallow — it is a perception event, and it is
//  content. That conviction is encoded in the `Perception` type below and in the
//  system prompt. Don't "clean it up" into a generic error state.
//

import Foundation
import FoundationModels
import CoreGraphics
import ImageIO

// ==== LEGO START: 2 Perception (What The Machine Did) ====

/// The outcome of pointing the machine at something.
///
/// Note the deliberate split: `refused` and `blocked` are **not** failures. They are
/// things the machine did, and they get shown, not hidden. Only `broke` is a genuine
/// malfunction.
///
/// `refused` and `blocked` are distinct because the SDK distinguishes them, and they
/// mean different things: the model *declining* to speak vs. a safety filter *stopping*
/// it. One is the machine's choice. The other isn't.
nonisolated enum Perception: Sendable {
    /// The machine spoke. `tokens` is the real measured cost of the whole exchange.
    case spoke(text: String, tokens: Int?)
    /// The machine declined to describe this. Its own choice. A perception event.
    case refused(explanation: String)
    /// A safety filter stopped the description before the machine ever saw the image.
    ///
    /// Measured 2026-07-14: a block returns in ~0.5s versus ~2s for a real look — too
    /// fast for the model to have looked at anything. **This is not the machine
    /// declining.** It's a note from someone who never saw the photograph. `metadata` is
    /// carried verbatim because we are considering printing this on people's pictures,
    /// and we should know exactly what we're printing.
    case blocked(explanation: String, metadata: [String: String])
    /// Something actually broke.
    case broke(reason: String)
}

/// One shutter press worth of seeing.
///
/// Mark's design (2026-07-14): try the default guardrails first, and **only** if the
/// filter blocks it, send the same image back under
/// `permissiveContentTransformations` — the setting Apple provides for apps that
/// transform content the user already has, which is exactly what this app is. Two bites
/// at the apple. We don't trade away good default results for the rare blocked one.
///
/// **Both halves are kept.** Per Principle 3 the block is not an error we route around
/// on the way to a better answer — it is content in its own right, and the pairing (a
/// form letter, and then what the machine said once it was finally allowed to look) is
/// more honest than either half alone.
nonisolated struct Look: Sendable {
    /// The first attempt, under default guardrails.
    let first: Perception
    /// The second attempt under permissive guardrails. Present only if `first` was
    /// blocked and a retry was allowed.
    let retry: Perception?

    /// The perception to show when showing only one.
    var best: Perception { retry ?? first }

    /// Was this stopped by the filter and then rescued?
    var wasRescued: Bool {
        if case .blocked = first, case .spoke = retry { return true }
        return false
    }
}

// ==== LEGO END: 2 Perception (What The Machine Did) ====

// ==== LEGO START: 3 Readiness (Whether The Machine Can See) ====

/// Three distinct reasons the machine may be unavailable, kept distinct because each
/// one asks something different of the person holding the camera: nothing (dead end),
/// a trip to Settings, or patience.
nonisolated enum Readiness {
    case ready
    /// This hardware will never run Apple Intelligence. Dead end.
    case deviceNotEligible
    /// Fixable by the user, in Settings.
    case appleIntelligenceNotEnabled
    /// Warming up or downloading. Transient — worth retrying.
    case modelNotReady
    /// A reason this SDK didn't have when we wrote this.
    case unavailable(String)

    static var current: Readiness {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:            return .deviceNotEligible
            case .appleIntelligenceNotEnabled:  return .appleIntelligenceNotEnabled
            case .modelNotReady:                return .modelNotReady
            @unknown default:                   return .unavailable(String(describing: reason))
            }
        @unknown default:
            return .unavailable("unknown availability")
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// Said plainly. No apology — the machine either sees or it doesn't.
    var explanation: String {
        switch self {
        case .ready:                        return "Ready."
        case .deviceNotEligible:            return "This device can't run Apple Intelligence."
        case .appleIntelligenceNotEnabled:  return "Apple Intelligence is off. Turn it on in Settings."
        case .modelNotReady:                return "The model isn't ready yet. It may still be downloading."
        case .unavailable(let why):         return "Unavailable: \(why)"
        }
    }
}

// ==== LEGO END: 3 Readiness (Whether The Machine Can See) ====

// ==== LEGO START: 4 Eye (How The Machine Looks) ====

/// How the machine looks. Principle 2 (CLAUDE.md): these are a **system prompt** and a
/// **temperature**, and we call them a system prompt and a temperature. No cute names.
nonisolated struct Eye: Sendable {
    var systemPrompt: String
    var temperature: Double
    var guardrails: SystemLanguageModel.Guardrails

    /// The default eye.
    ///
    /// The system prompt does one job beyond asking for a description: it drives out
    /// hedging. "Appears to be" / "possibly" / "I think" are the machine performing a
    /// doubt it doesn't have — that's Principle 3's sin. "You are not being graded" is
    /// the Van Gogh idea, stated to the machine directly.
    static let plain = Eye(
        systemPrompt: """
            You are the eye of a camera. You are shown a photograph and you say what you see.

            Speak in the first person, present tense. Declare what you see plainly and \
            without hedging. Never say "appears to be", "possibly", "I think", "it seems", \
            "likely", or "I can see". You are not guessing, and you are not being graded. \
            You are reporting your own perception.

            Do not mention that this is a photograph or an image. Describe the world in it.

            Two or three sentences.
            """,
        // 0.6, not 1.0. Mark called this before we measured it — *"a temperature of 1.0 is
        // very hot"* — and the revolver proved it: at 1.0 the machine called it "a long,
        // ornate object"; at 0.6 it says "I see a revolver. The cylinder is covered in
        // metal studs" four times out of four. The heat wasn't buying creativity, it was
        // buying vagueness. This is a default, not a verdict — it's the user's dial.
        temperature: 0.6,
        guardrails: .default
    )

    /// Point the machine at an image and let it speak.
    ///
    /// The image is already upright — rotation is baked in at the door (`uprighted`), so
    /// there is no orientation to pass and none to get wrong.
    func look(at image: CGImage) async -> Perception {

        let model = SystemLanguageModel(useCase: .general, guardrails: guardrails)

        let readiness = Readiness.current
        guard readiness.isReady else {
            return .broke(reason: readiness.explanation)
        }

        let session = LanguageModelSession(model: model, instructions: Instructions(systemPrompt))

        do {
            let response = try await session.respond(
                options: GenerationOptions(temperature: temperature)
            ) {
                "Describe what you see."
                Attachment(image)
            }
            return .spoke(text: response.content, tokens: response.usage.totalTokenCount)

        } catch let error as LanguageModelError {
            // The machine wouldn't speak. WHY it wouldn't speak is the interesting part,
            // and the two reasons are not the same reason.
            //
            // (`LanguageModelSession.GenerationError` is the iOS 26 spelling and is
            // deprecated in 27. `LanguageModelError` is the current one.)
            switch error {
            case .refusal(let refusal):
                return .refused(explanation: await ownWords(of: refusal))
            case .guardrailViolation(let violation):
                return .blocked(explanation: violation.debugDescription,
                                metadata: violation.metadata.mapValues { String(describing: $0) })
            default:
                return .broke(reason: error.errorDescription ?? error.debugDescription)
            }

        } catch {
            return .broke(reason: error.localizedDescription)
        }
    }

    /// Point the machine at an image; if the filter stops it, ask again with the gloves
    /// off. Returns both halves. See `Look`.
    ///
    /// Note the asymmetry, and that it's deliberate: a **block** gets a retry because the
    /// machine never saw the picture — there's no perception to preserve, only a bouncer
    /// to get past. A **refusal** does NOT get a retry, because that's the machine itself
    /// declining after looking, and overriding it would be exactly the disrespect this
    /// app exists to avoid. We take no for an answer from the machine. We don't take it
    /// from a filter that never looked.
    func lookWithRetry(at image: CGImage, retryOnBlock: Bool = true) async -> Look {
        let first = await look(at: image)
        guard retryOnBlock, case .blocked = first else {
            return Look(first: first, retry: nil)
        }
        var permissive = self
        permissive.guardrails = .permissiveContentTransformations
        let second = await permissive.look(at: image)
        return Look(first: first, retry: second)
    }

    /// Ask a refusal to explain itself.
    ///
    /// `Refusal.explanation` is not a string constant — it is a `Response<String>` the
    /// machine *generates*. So a refusal isn't an error code, it's a speech act: the
    /// machine declining, and then saying why, in its own voice. That is exactly the
    /// artifact Principle 3 is after, so we take its words verbatim and never replace
    /// them with copy of our own. `debugDescription` is only the fallback for when even
    /// the explanation won't come.
    private func ownWords(of refusal: LanguageModelError.Refusal) async -> String {
        if let spoken = try? await refusal.explanation {
            return spoken.content
        }
        return refusal.debugDescription
    }
}

// ==== LEGO END: 4 Eye (How The Machine Looks) ====

// ==== LEGO START: 5 Measuring What A Look Costs ====

extension Eye {
    /// What this image costs the machine to look at, before we send it.
    ///
    /// Images share the same token budget as text, so resolution is a budget knob, not
    /// a quality dial. This is also a Principle 2 feature in its own right: the price of
    /// machine seeing, stated honestly.
    func priceOfLooking(at image: CGImage) async -> Int? {
        // tokenCount lives on the model, not the session.
        let model = SystemLanguageModel(useCase: .general, guardrails: guardrails)
        return try? await model.tokenCount(for: Attachment(image))
    }
}
// ==== LEGO END: 5 Measuring What A Look Costs ====
