//
//  AgentWebTools.swift
//  leanring-buddy
//
//  Web search and page fetch for the agent loop. Search runs on publik's
//  POST /search (about a cent a search); fetch runs locally on this Mac.
//

import Foundation

final class WebSearchTool: BackgroundAgentTool {
    let name = "web_search"
    let description = "Search the web for current information. Returns titles, URLs and snippets. Use 1–2 focused queries, then answer."

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "What to search for. Quote a phrase to find it exactly."
            ]
        ],
        "required": ["query"]
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        guard let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw NSError(domain: "WebSearchTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing 'query' argument"])
        }
        guard let route = try TeachyAIRouter.routes(for: .agent, hasImages: false).first, route.isPublik else {
            return "Web search isn't available with your own key. Answer from what you know, or use web_fetch on a URL you're sure of."
        }

        let (results, billingMessage, billingURL) = try await Publik.search(
            baseURL: route.baseURL,
            apiKey: route.apiKey,
            q: query,
            count: 5
        )
        if let billingMessage {
            await MainActor.run {
                TeachyPublikSession.shared.reportBilling(TeachyAIBillingError(message: billingMessage, topUpURL: billingURL))
            }
            return "Web search unavailable: \(billingMessage)"
        }
        guard !results.isEmpty else { return "No results for \(query)." }

        return results.enumerated().map { index, result in
            let title = result["title"] as? String ?? "(untitled)"
            let url = result["url"] as? String ?? result["link"] as? String ?? ""
            let snippet = (result["snippet"] as? String)
                ?? (result["description"] as? String)
                ?? (result["content"] as? String)
                ?? ""
            return "\(index + 1). \(title)\n\(url)\n\(snippet.prefix(500))"
        }.joined(separator: "\n\n")
    }
}

final class WebFetchTool: BackgroundAgentTool {
    let name = "web_fetch"
    let description = "Fetch a public web page (http or https) and return its readable text."

    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "url": [
                "type": "string",
                "description": "The page URL"
            ]
        ],
        "required": ["url"]
    ]

    private static let maximumCharacters = 8_000

    func execute(arguments: [String: Any]) async throws -> String {
        guard let urlString = arguments["url"] as? String,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else {
            throw NSError(domain: "WebFetchTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "Give a full http(s) URL"])
        }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (Macintosh) Teachy", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else { return "The page answered \(status)." }

        let raw = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let text = Self.readableText(fromHTML: raw)
        if text.count > Self.maximumCharacters {
            return String(text.prefix(Self.maximumCharacters)) + "\n\n[truncated]"
        }
        return text
    }

    static func readableText(fromHTML html: String) -> String {
        var text = html
        for pattern in [#"(?is)<script\b.*?</script>"#, #"(?is)<style\b.*?</style>"#, #"(?is)<noscript\b.*?</noscript>"#, #"(?s)<!--.*?-->"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"(?i)<(br|/p|/div|/li|/h[1-6]|/tr)\b[^>]*>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
