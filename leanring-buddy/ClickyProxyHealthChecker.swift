//
//  ClickyProxyHealthChecker.swift
//  leanring-buddy
//
//  Lightweight GET /health probe so the app can fail fast with one clear
//  message instead of starting a course and then speaking a proxy error.
//

import Foundation

enum ClickyProxyHealthChecker {
    struct HealthResult: Equatable {
        let isReachable: Bool
        let isOpenRouterConfigured: Bool
        let serviceName: String?

        static let unreachable = HealthResult(
            isReachable: false,
            isOpenRouterConfigured: false,
            serviceName: nil
        )
    }

    static func fetchHealth() async -> HealthResult {
        // publik (or the own-key path) is the backend. Ready means signed in and a
        // payment choice is stored; network trouble shows up on the call itself.
        if TeachyAIRouter.isReadyForAI {
            return HealthResult(
                isReachable: true,
                isOpenRouterConfigured: true,
                serviceName: TeachyAIRouter.isUsingPublik ? "publik" : "own-key"
            )
        }
        return .unreachable
    }

    /// The old local-proxy probe, kept for developers running worker/ by hand.
    static func fetchLocalProxyHealth() async -> HealthResult {

        guard let healthURL = URL(string: "\(ClickyWorkerConfiguration.workerBaseURL)/health") else {
            return .unreachable
        }

        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return .unreachable
            }

            guard let healthObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return HealthResult(
                    isReachable: true,
                    isOpenRouterConfigured: true,
                    serviceName: nil
                )
            }

            let isOK = healthObject["ok"] as? Bool ?? true
            return HealthResult(
                isReachable: isOK,
                isOpenRouterConfigured: healthObject["openrouter"] as? Bool ?? true,
                serviceName: healthObject["service"] as? String
            )
        } catch {
            print("⚠️ ClickyProxyHealthChecker: \(error.localizedDescription)")
            return .unreachable
        }
    }
}
