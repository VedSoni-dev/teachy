//
//  CourseVerifier.swift
//  leanring-buddy
//
//  Checks whether a course goal is complete via structured vision feedback.
//  Returns pass / partial / offTrack with specific feedback, not just a binary bit.
//

import Foundation

struct CourseSuccessCriteria: Equatable {
    var visionDescription: String?
    var urlContains: String?
    var requireUserAdvance: Bool?
}

enum CourseVerificationStatus: String, Codable {
    case pass
    case partial
    case offTrack
}

struct CourseVerificationResult: Codable {
    let status: CourseVerificationStatus
    let whatsGood: String
    let whatsMissing: String?
    let suggestedNextAction: String?
}

struct CourseVerifyResult {
    let passed: Bool
    let reason: String
}

@MainActor
enum CourseVerifier {

    static func verify(
        criteria: CourseSuccessCriteria,
        claudeAPI: ClaudeAPI,
        treatAsUserAdvance: Bool = false
    ) async throws -> CourseVerifyResult {
        let structured = await verifyStructured(
            criteria: criteria,
            claudeAPI: claudeAPI,
            treatAsUserAdvance: treatAsUserAdvance
        )

        switch structured.status {
        case .pass:
            return CourseVerifyResult(passed: true, reason: structured.whatsGood)
        case .partial:
            let reason: String
            if let missing = structured.whatsMissing {
                reason = "partial: \(structured.whatsGood) | missing: \(missing)"
            } else {
                reason = "partial: \(structured.whatsGood)"
            }
            return CourseVerifyResult(passed: true, reason: reason)
        case .offTrack:
            let reason: String
            if let missing = structured.whatsMissing {
                reason = "offTrack: \(structured.whatsGood) | missing: \(missing)"
            } else {
                reason = "offTrack: \(structured.whatsGood)"
            }
            return CourseVerifyResult(passed: false, reason: reason)
        }
    }

    static func verifyStructured(
        criteria: CourseSuccessCriteria,
        claudeAPI: ClaudeAPI,
        treatAsUserAdvance: Bool = false,
        precapturedScreenCapture: CompanionScreenCapture? = nil
    ) async -> CourseVerificationResult {
        let visionDescription = criteria.visionDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let urlContains = criteria.urlContains?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasVisionDescription = !(visionDescription?.isEmpty ?? true)
        let hasURLContains = !(urlContains?.isEmpty ?? true)
        let allowsUserAdvance = criteria.requireUserAdvance == true

        // Author opted into tap-to-confirm with no vision check.
        if treatAsUserAdvance, allowsUserAdvance, !hasVisionDescription, !hasURLContains {
            return CourseVerificationResult(
                status: .pass,
                whatsGood: "user confirmed advance with no vision criteria",
                whatsMissing: nil,
                suggestedNextAction: nil
            )
        }

        let checkDescription: String?
        if hasVisionDescription, let visionDescription {
            if hasURLContains, let urlContains {
                checkDescription = "\(visionDescription) (page may relate to URL containing \(urlContains))"
            } else {
                checkDescription = visionDescription
            }
        } else if hasURLContains, let urlContains {
            checkDescription = "Does the screen show a page matching URL content like \(urlContains)? (e.g. search results or a watch page)"
        } else {
            checkDescription = nil
        }

        guard let checkDescription else {
            if treatAsUserAdvance {
                return CourseVerificationResult(
                    status: .pass,
                    whatsGood: "user advance with no criteria to check",
                    whatsMissing: nil,
                    suggestedNextAction: nil
                )
            }
            return CourseVerificationResult(
                status: .offTrack,
                whatsGood: "",
                whatsMissing: "no success criteria defined for this goal",
                suggestedNextAction: "try the goal step and say next step when done"
            )
        }

        let screenCapture: CompanionScreenCapture
        // Callers that already captured a screenshot for this turn (e.g. companion
        // guided-task verification, which reuses the same capture used to answer the
        // user's question) can pass it in to avoid a redundant capture.
        if let precapturedScreenCapture {
            screenCapture = precapturedScreenCapture
        } else {
            do {
                screenCapture = try await CourseUIGrounder.captureCursorScreen()
            } catch {
                return CourseVerificationResult(
                    status: .pass,
                    whatsGood: "could not capture screen — soft passing",
                    whatsMissing: nil,
                    suggestedNextAction: nil
                )
            }
        }

        let annotatedImageData = ScreenGridAnnotationUtility.annotateScreenshotForModel(
            originalJPEGData: screenCapture.imageData,
            screenshotWidthInPixels: screenCapture.screenshotWidthInPixels,
            screenshotHeightInPixels: screenCapture.screenshotHeightInPixels
        ) ?? screenCapture.imageData

        let systemPrompt = """
        you verify whether a course goal is complete. look at the screenshot only.

        reply with ONLY a JSON object:
        {"status":"pass"|"partial"|"offTrack","whatsGood":"short description of what IS correct on screen","whatsMissing":"what's still missing or wrong — null if pass","suggestedNextAction":"one specific next move the learner should take — null if pass"}

        rules:
        - status "pass" = the goal is clearly complete on screen.
        - status "partial" = the learner made real progress but something specific is missing or incomplete. name exactly what they got right first, then what's missing.
        - status "offTrack" = the goal is not meaningfully progressed or the screen shows something unrelated. still name any partial progress if it exists.
        - whatsGood should always name something concrete the learner did or that is visible — never leave it empty.
        - suggestedNextAction should be one short, specific instruction — not a list.
        - be honest but kind. "close" is partial, not offTrack.
        """

        let userPrompt = """
        completion criteria: \(checkDescription)

        What is the current state on screen? Is this goal complete, partially complete, or off track?
        """

        let rawResponse: String
        do {
            (rawResponse, _) = try await claudeAPI.analyzeImage(
                images: [(data: annotatedImageData, label: screenCapture.label)],
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
        } catch {
            print("⚠️ CourseVerifier vision error: \(error)")
            return CourseVerificationResult(
                status: .offTrack,
                whatsGood: "",
                whatsMissing: "vision check failed — \(error.localizedDescription)",
                suggestedNextAction: "try the step and say next step when done"
            )
        }

        let parsed = parseStructuredResult(from: rawResponse)

        // Soft pass when the author allows user advance and the learner confirmed.
        if parsed.status == .offTrack && treatAsUserAdvance && allowsUserAdvance {
            return CourseVerificationResult(
                status: .pass,
                whatsGood: parsed.whatsGood.isEmpty ? "user confirmed" : parsed.whatsGood,
                whatsMissing: nil,
                suggestedNextAction: nil
            )
        }

        return parsed
    }

    private static func parseStructuredResult(from rawText: String) -> CourseVerificationResult {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonCandidate: String
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}"),
           start < end {
            jsonCandidate = String(trimmed[start...end])
        } else {
            jsonCandidate = trimmed
        }

        guard let data = jsonCandidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Fallback: try to detect YES/NO from unparsed text.
            let lowered = trimmed.lowercased()
            if lowered.hasPrefix("yes") || lowered.contains("\"status\": \"pass\"") || lowered.contains("\"status\":\"pass\"") {
                return CourseVerificationResult(
                    status: .pass,
                    whatsGood: "vision confirmed completion",
                    whatsMissing: nil,
                    suggestedNextAction: nil
                )
            }
            return CourseVerificationResult(
                status: .offTrack,
                whatsGood: "",
                whatsMissing: "could not parse verification response",
                suggestedNextAction: "try the step and say next step"
            )
        }

        let statusString = (object["status"] as? String)?.lowercased() ?? "offtrack"
        let status: CourseVerificationStatus
        switch statusString {
        case "pass":
            status = .pass
        case "partial":
            status = .partial
        default:
            status = .offTrack
        }

        let whatsGood = (object["whatsGood"] as? String) ?? ""
        let whatsMissing = object["whatsMissing"] as? String
        let suggestedNextAction = object["suggestedNextAction"] as? String

        return CourseVerificationResult(
            status: status,
            whatsGood: whatsGood,
            whatsMissing: whatsMissing,
            suggestedNextAction: suggestedNextAction
        )
    }
}
