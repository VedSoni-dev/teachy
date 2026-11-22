//
//  TeachyJev.swift
//  leanring-buddy
//
//  Jev (TypeSafe's "System One" model) through Vercel AI Gateway. Jev does not
//  write text: it reads a state and answers typed questions with calibrated
//  probabilities, in one fast, cheap call:
//
//    noul    is this statement true?          → probability 0…1
//    choice  which of these options?          → option id + confidence
//    score   where on this rubric?            → 0…(levels-1) + confidence
//
//  Teachy uses it where a whole chat model turn is too slow for a small decision
//  (see SceneJevRouter). Every caller must work without it: no key, a timeout or
//  an error all mean "decide the old way".
//
//  Endpoints (same request and answer shape):
//    - Vercel AI Gateway: POST https://ai-gateway.vercel.sh/typesafe/v1/systemone
//    - OpenRouter: POST https://openrouter.ai/api/alpha/decisions (an `sk-or-` key)
//    - Gemini: POST https://generativelanguage.googleapis.com/v1beta/decisions with
//      gemini-decision-1 (an `AIza` key). Same questions and answers; the state is
//      sent as `input` and the key in `x-goog-api-key`.
//  Text state only.
//

import Foundation

enum TeachyJevQuestion {
    case noul(instructions: String)
    /// `criteria`: option id → what the option means.
    case choice(instructions: String, criteria: [String: String])
    /// `levels`: rubric from lowest to highest.
    case score(instructions: String, levels: [String])

    var jsonObject: [String: Any] {
        switch self {
        case .noul(let instructions):
            return ["type": "noul", "instructions": instructions]
        case .choice(let instructions, let criteria):
            return ["type": "choice", "instructions": instructions, "criteria": criteria]
        case .score(let instructions, let levels):
            return ["type": "score", "instructions": instructions, "criteria": levels]
        }
    }
}

struct TeachyJevChoiceAnswer: Equatable {
    let choice: String
    let confidence: Double
}

struct TeachyJevScoreAnswer: Equatable {
    let score: Double
    let confidence: Double
}

struct TeachyJevAnswers: Equatable {
    var nouls: [String: Double] = [:]
    var choices: [String: TeachyJevChoiceAnswer] = [:]
    var scores: [String: TeachyJevScoreAnswer] = [:]

    /// Reads the `answers` object of a systemone response. Unknown or refused answers are skipped.
    static func parse(_ responseData: Data) -> TeachyJevAnswers? {
        guard let json = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any],
              let answerObjects = json["answers"] as? [String: Any]
        else { return nil }
        var answers = TeachyJevAnswers()
        for (questionID, value) in answerObjects {
            guard let answer = value as? [String: Any] else { continue }
            switch answer["type"] as? String {
            case "noul":
                if let probability = (answer["noul"] as? NSNumber)?.doubleValue { answers.nouls[questionID] = probability }
            case "choice":
                if let choice = answer["choice"] as? String {
                    let confidence = (answer["confidence"] as? NSNumber)?.doubleValue ?? 0
                    answers.choices[questionID] = TeachyJevChoiceAnswer(choice: choice, confidence: confidence)
                }
            case "score":
                if let score = (answer["score"] as? NSNumber)?.doubleValue {
                    let confidence = (answer["confidence"] as? NSNumber)?.doubleValue ?? 0
                    answers.scores[questionID] = TeachyJevScoreAnswer(score: score, confidence: confidence)
                }
            default:
                continue
            }
        }
        return answers
    }
}

struct TeachyJevError: LocalizedError {
    let statusCode: Int
    let message: String
    var errorDescription: String? { "Jev error (\(statusCode)): \(message)" }

    /// The gateway answers in two shapes: TypeSafe's `{message, error_type}` and its own `{error: {message, type}}`.
    static func from(statusCode: Int, body: Data) -> TeachyJevError {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let message = (json?["message"] as? String)
            ?? ((json?["error"] as? [String: Any])?["message"] as? String)
            ?? String(data: body.prefix(300), encoding: .utf8)
            ?? "unknown error"
        return TeachyJevError(statusCode: statusCode, message: String(message.prefix(300)))
    }
}

/// Where a Jev call goes, chosen from the key: OpenRouter keys start with `sk-or-`,
/// Google AI Studio (Gemini) keys with `AIza`; anything else is a Vercel AI Gateway key.
enum TeachyJevProvider: Equatable {
    case vercelGateway
    case openRouter
    case gemini

    static func forKey(_ apiKey: String) -> TeachyJevProvider {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.hasPrefix("sk-or-") { return .openRouter }
        if trimmedKey.hasPrefix("AIza") { return .gemini }
        return .vercelGateway
    }

    /// Gemini's Decisions API calls the shared state `input`; the others call it `state`.
    var stateFieldName: String {
        self == .gemini ? "input" : "state"
    }

    var endpoint: URL {
        switch self {
        case .vercelGateway: return URL(string: "https://ai-gateway.vercel.sh/typesafe/v1/systemone")!
        case .openRouter: return URL(string: "https://openrouter.ai/api/alpha/decisions")!
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/decisions")!
        }
    }

    var modelID: String {
        switch self {
        case .vercelGateway: return "typesafe-ai/jev"
        case .openRouter: return "~typesafe/jev-latest"
        case .gemini: return "gemini-decision-1"
        }
    }

    var displayName: String {
        switch self {
        case .vercelGateway: return "Vercel AI Gateway"
        case .openRouter: return "OpenRouter"
        case .gemini: return "Gemini"
        }
    }
}

enum TeachyJev {
    static var isAvailable: Bool { TeachyGatewayKeyStore.isJevConfigured }

    static func requestBody(
        state: String,
        questions: [String: TeachyJevQuestion],
        provider: TeachyJevProvider = .vercelGateway
    ) -> [String: Any] {
        [
            "model": provider.modelID,
            provider.stateFieldName: state,
            "questions": questions.mapValues(\.jsonObject),
        ]
    }

    /// One Jev call. `apiKey` defaults to the saved key (gateway first, then OpenRouter);
    /// the key decides which service is called.
    static func ask(
        state: String,
        questions: [String: TeachyJevQuestion],
        timeout: TimeInterval = 2,
        apiKey: String? = TeachyGatewayKeyStore.jevKey,
        session: URLSession = .shared
    ) async throws -> TeachyJevAnswers {
        guard let apiKey, !apiKey.isEmpty else {
            throw TeachyJevError(statusCode: 0, message: "No Jev key is set.")
        }
        let provider = TeachyJevProvider.forKey(apiKey)
        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if provider == .gemini {
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(state: state, questions: questions, provider: provider))

        let (responseData, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            throw TeachyJevError.from(statusCode: statusCode, body: responseData)
        }
        guard let answers = TeachyJevAnswers.parse(responseData) else {
            throw TeachyJevError(statusCode: statusCode, message: "Jev's answer could not be read.")
        }
        return answers
    }
}
