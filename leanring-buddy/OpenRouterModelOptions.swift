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
