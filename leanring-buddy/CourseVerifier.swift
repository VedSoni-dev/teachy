//
//  CourseVerifier.swift
//  leanring-buddy
//
//  Checks whether a course `do` beat / step is complete via vision (and optional heuristics).
//

import Foundation

struct CourseSuccessCriteria: Equatable {
    var visionDescription: String?
    var urlContains: String?
    var requireUserAdvance: Bool?
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
        let visionDescription = criteria.visionDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let urlContains = criteria.urlContains?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasVisionDescription = !(visionDescription?.isEmpty ?? true)
        let hasURLContains = !(urlContains?.isEmpty ?? true)
        let allowsUserAdvance = criteria.requireUserAdvance == true

        // Author opted into tap-to-confirm with no vision check.
        if treatAsUserAdvance, allowsUserAdvance, !hasVisionDescription, !hasURLContains {
            return CourseVerifyResult(passed: true, reason: "user advance")
        }

        // Phase 1: no live browser URL API — fold urlContains into the vision question.
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
                return CourseVerifyResult(passed: true, reason: "user advance (no criteria)")
            }
            return CourseVerifyResult(passed: false, reason: "no success criteria")
        }

        let screenCapture = try await CourseUIGrounder.captureCursorScreen()
        let annotatedImageData = ScreenGridAnnotationUtility.annotateScreenshotForModel(
            originalJPEGData: screenCapture.imageData,
            screenshotWidthInPixels: screenCapture.screenshotWidthInPixels,
            screenshotHeightInPixels: screenCapture.screenshotHeightInPixels
        ) ?? screenCapture.imageData

        let (verifyResponse, _) = try await claudeAPI.analyzeImage(
            images: [(data: annotatedImageData, label: screenCapture.label)],
            systemPrompt: "you verify whether a course goal is complete. look at the screenshot only. reply YES or NO only.",
            userPrompt: """
            completion criteria: \(checkDescription)
            is this complete on the current screen? answer YES or NO only.
            """
        )

        let normalized = verifyResponse.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let passed = normalized.hasPrefix("YES")

        // Soft pass when the author allows user advance and the learner confirmed.
        if !passed, treatAsUserAdvance, allowsUserAdvance {
            return CourseVerifyResult(passed: true, reason: "user advance (vision soft-fail)")
        }

        return CourseVerifyResult(
            passed: passed,
            reason: passed ? "vision yes" : "vision no: \(verifyResponse.prefix(80))"
        )
    }
}
