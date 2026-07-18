//
//  OpenRouterModelOptions.swift
//  Unified OpenRouter models — vision + tools in one agent loop.
//

import Foundation

struct OpenRouterModelOption: Identifiable, Equatable {
    let id: String
    let displayName: String
    let subtitle: String
    let supportsVision: Bool

    static let defaultModelID = "google/gemini-2.5-flash"
    static let visionFallbackModelID = "google/gemini-2.5-flash"

    /// Reasoning + vision model used for screen-grounded guided-task planning.
    /// Must start with "google/gemini", "google/gemma", or "qwen/qwen3-vl" so the
    /// worker's model-routing allowlist (worker/model-routing.mjs + worker/src/model-routing.ts
    /// VISION_MODEL_PREFIXES) passes the model through untouched when a screenshot is attached.
    /// Swapping to a model outside those prefixes would require also allowlisting its prefix
    /// in both routing files — do not change without updating those files.
    static let reasoningPlannerModelID = "google/gemini-2.5-pro"

    /// One list for the whole app. Pick a model; routing handles screen images when needed.
    static let models: [OpenRouterModelOption] = [
        OpenRouterModelOption(
            id: "google/gemini-2.5-flash",
            displayName: "Gemini 2.5 Flash",
            subtitle: "Vision + tools · recommended",
            supportsVision: true
        ),
        OpenRouterModelOption(
            id: "google/gemma-4-26b-a4b-it",
            displayName: "Gemma 4 26B",
            subtitle: "Vision + tools · cheaper",
            supportsVision: true
        ),
        OpenRouterModelOption(
            id: "google/gemini-2.5-flash-lite",
            displayName: "Gemini 2.5 Flash Lite",
            subtitle: "Vision + tools · fast",
            supportsVision: true
        ),
        OpenRouterModelOption(
            id: "qwen/qwen3-vl-30b-a3b-instruct",
            displayName: "Qwen3 VL 30B",
            subtitle: "Vision + tools",
            supportsVision: true
        ),
        OpenRouterModelOption(
            id: "deepseek/deepseek-v4-flash",
            displayName: "DeepSeek V4 Flash",
            subtitle: "Tools only · auto-upgrades for screen",
            supportsVision: false
        ),
    ]

    static func modelOption(forModelID modelID: String) -> OpenRouterModelOption {
        models.first(where: { $0.id == modelID }) ?? models[0]
    }

    /// Returns a known model ID, or the default when UserDefaults has a stale/unknown value.
    static func sanitizedModelID(_ modelID: String) -> String {
        models.first(where: { $0.id == modelID })?.id ?? defaultModelID
    }

    /// Picks a model that can handle the request. Upgrades to a vision model when screenshots are attached.
    static func resolvedModelID(preferredModelID: String, hasScreenCaptures: Bool) -> String {
        let knownOption = models.first(where: { $0.id == preferredModelID })

        if hasScreenCaptures {
            if let knownOption, knownOption.supportsVision {
                return knownOption.id
            }
            return visionFallbackModelID
        }

        return knownOption?.id ?? defaultModelID
    }
}

enum ClickyWorkerConfiguration {
    private static let defaultWorkerBaseURL = "http://localhost:8787"

    static var workerBaseURL: String {
        AppBundleConfiguration.stringValue(forKey: "WorkerBaseURL") ?? defaultWorkerBaseURL
    }

    static var chatEndpointURL: String {
        "\(workerBaseURL)/chat"
    }

    static var agentCompletionsEndpointURL: String {
        "\(workerBaseURL)/v1/chat/completions"
    }

    static var transcribeTokenEndpointURL: String {
        "\(workerBaseURL)/transcribe-token"
    }

    /// Cloud TTS (ElevenLabs / OpenAI). Returns audio when the proxy has a key configured.
    static var ttsEndpointURL: String {
        "\(workerBaseURL)/tts"
    }

    static var composioConnectionsEndpointURL: String {
        "\(workerBaseURL)/composio/connections"
    }

    static var composioConnectEndpointURL: String {
        "\(workerBaseURL)/composio/connect"
    }

    static var composioToolkitsEndpointURL: String {
        "\(workerBaseURL)/composio/toolkits"
    }
}
