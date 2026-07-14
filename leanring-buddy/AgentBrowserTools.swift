//
//  AgentBrowserTools.swift
//  Browser-session-aware agent tools using the user's real browser cookies.
//

import Foundation

// MARK: - Authenticated Fetch

final class AuthenticatedFetchTool: BackgroundAgentTool {
    let name = "authenticated_fetch"
    let description = "Fetch a URL using cookies from the user's installed browsers (Chrome, Brave, Arc, Edge, Safari). Use for logged-in sites."

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "url": [
                "type": "string",
                "description": "The URL to fetch"
            ],
            "browser": [
                "type": "string",
                "enum": ["auto", "chrome", "brave", "arc", "edge", "safari"],
                "description": "Which browser's cookies to use (default: auto)"
            ],
            "method": [
                "type": "string",
                "enum": ["GET", "POST"],
                "description": "HTTP method (default GET)"
            ],
            "body": [
                "type": "string",
                "description": "Optional request body for POST"
            ]
        ],
        "required": ["url"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        guard let urlString = arguments["url"] as? String,
              let url = URL(string: urlString) else {
            throw NSError(domain: "AuthenticatedFetchTool", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }

        let browser = AgentBrowserChoice(toolArgument: arguments["browser"] as? String)
        let method = (arguments["method"] as? String ?? "GET").uppercased()
        let requestBody = arguments["body"] as? String

        guard let cookieHeader = try BrowserSessionStore.cookieHeaderValue(for: url, browser: browser) else {
            let installedBrowsers = BrowserSessionStore.installedBrowserNames().joined(separator: ", ")
            return """
            No cookies found for \(url.host ?? urlString) in \(browser.displayName) mode. \
            Installed browsers: \(installedBrowsers.isEmpty ? "none detected" : installedBrowsers). \
            Make sure you are logged in to this site in your browser.
            """
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/json;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        if method == "POST", let requestBody {
            request.httpBody = requestBody.data(using: .utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "AuthenticatedFetchTool", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        let responseText = String(data: data, encoding: .utf8) ?? "(binary \(data.count) bytes)"
        let cookieCount = cookieHeader.components(separatedBy: ";").count

        return """
        HTTP \(httpResponse.statusCode) via \(browser.displayName) (\(cookieCount) cookies)
        
        \(responseText.prefix(12000))
        """
    }
}

// MARK: - Browser Sessions

final class ListBrowserSessionsTool: BackgroundAgentTool {
    let name = "list_browser_sessions"
    let description = "List installed browsers and cookie counts available for authenticated_fetch."

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [:]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        let summaries = BrowserSessionStore.summarizeLoggedInSites(browser: .auto)
        guard !summaries.isEmpty else {
            return "No supported browsers detected. Install Chrome, Brave, Arc, Edge, or Safari."
        }

        return summaries.map { summary in
            let domains = summary.sampleDomains.isEmpty
                ? "no domains sampled"
                : summary.sampleDomains.prefix(8).joined(separator: ", ")
            return "\(summary.browserName): \(summary.cookieCount) cookies — \(domains)"
        }.joined(separator: "\n")
    }
}
