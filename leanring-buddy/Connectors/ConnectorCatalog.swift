//
//  ConnectorCatalog.swift
//  leanring-buddy
//
//  Well-known remote MCP servers people can add in one click ("Popular" in the
//  Connectors card). Adding one goes through the same path as typing its URL:
//  `ConnectorCenter.add`, then the browser sign-in if the server asks for one.
//
//  Every entry was checked on 14 Nov 2026 with an unauthenticated MCP
//  `initialize` POST. Kept only if the server answered as an MCP server:
//  - "oauth":   401 with a Bearer challenge, and its authorization server
//               publishes a `registration_endpoint` (Teachy signs in with
//               dynamic client registration; servers without one cannot be
//               added this way and were left out: Slack, HubSpot, Todoist,
//               Box, Dropbox).
//  - "api_key": 401 asking for a bearer token the person creates themselves.
//  - "none":    200 with a normal initialize result.
//  Nothing here calls an AI model, and nothing is contacted until the person
//  presses Add.
//

import Foundation

nonisolated struct ConnectorCatalogEntry: Codable, Equatable, Identifiable, Sendable {
    enum Auth: String, Codable, Sendable {
        /// Sign in through the browser.
        case oauth
        /// Paste a key or token.
        case apiKey = "api_key"
        /// Open to everyone.
        case none
    }

    var id: String
    var name: String
    /// What it lets Teachy do, in a few words.
    var summary: String
    var url: String
    var auth: Auth
    /// For "api_key": where the person gets the key.
    var keyHint: String?
}

nonisolated struct ConnectorCatalogError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

nonisolated enum ConnectorCatalog {
    static let verifiedOn = "2026-11-14"

    static let json = """
    [
      {"id": "linear", "name": "Linear", "summary": "Issues, projects and cycles", "url": "https://mcp.linear.app/mcp", "auth": "oauth"},
      {"id": "notion", "name": "Notion", "summary": "Pages, databases and search", "url": "https://mcp.notion.com/mcp", "auth": "oauth"},
      {"id": "github", "name": "GitHub", "summary": "Repos, issues and pull requests", "url": "https://api.githubcopilot.com/mcp/", "auth": "api_key", "keyHint": "A personal access token from github.com/settings/tokens"},
      {"id": "atlassian", "name": "Jira & Confluence", "summary": "Atlassian issues and pages", "url": "https://mcp.atlassian.com/v1/mcp", "auth": "oauth"},
      {"id": "asana", "name": "Asana", "summary": "Tasks and projects", "url": "https://mcp.asana.com/v2/mcp", "auth": "oauth"},
      {"id": "monday", "name": "monday.com", "summary": "Boards and items", "url": "https://mcp.monday.com/mcp", "auth": "oauth"},
      {"id": "airtable", "name": "Airtable", "summary": "Bases, tables and records", "url": "https://mcp.airtable.com/mcp", "auth": "oauth"},
      {"id": "sentry", "name": "Sentry", "summary": "Errors and performance issues", "url": "https://mcp.sentry.dev/mcp", "auth": "oauth"},
      {"id": "vercel", "name": "Vercel", "summary": "Projects, deployments and logs", "url": "https://mcp.vercel.com", "auth": "oauth"},
      {"id": "supabase", "name": "Supabase", "summary": "Databases, tables and logs", "url": "https://mcp.supabase.com/mcp", "auth": "oauth"},
      {"id": "neon", "name": "Neon", "summary": "Postgres projects and branches", "url": "https://mcp.neon.tech/mcp", "auth": "oauth"},
      {"id": "cloudflare", "name": "Cloudflare", "summary": "Workers, KV, R2 and D1", "url": "https://bindings.mcp.cloudflare.com/mcp", "auth": "oauth"},
      {"id": "posthog", "name": "PostHog", "summary": "Product analytics and flags", "url": "https://mcp.posthog.com/mcp", "auth": "oauth"},
      {"id": "stripe", "name": "Stripe", "summary": "Customers, payments and invoices", "url": "https://mcp.stripe.com", "auth": "oauth"},
      {"id": "paypal", "name": "PayPal", "summary": "Invoices, orders and payouts", "url": "https://mcp.paypal.com/mcp", "auth": "oauth"},
      {"id": "square", "name": "Square", "summary": "Payments, catalog and customers", "url": "https://mcp.squareup.com/mcp", "auth": "oauth"},
      {"id": "intercom", "name": "Intercom", "summary": "Conversations and contacts", "url": "https://mcp.intercom.com/mcp", "auth": "oauth"},
      {"id": "canva", "name": "Canva", "summary": "Designs and folders", "url": "https://mcp.canva.com/mcp", "auth": "oauth"},
      {"id": "webflow", "name": "Webflow", "summary": "Sites, pages and CMS items", "url": "https://mcp.webflow.com/mcp", "auth": "oauth"},
      {"id": "granola", "name": "Granola", "summary": "Meeting notes and transcripts", "url": "https://mcp.granola.ai/mcp", "auth": "oauth"},
      {"id": "huggingface", "name": "Hugging Face", "summary": "Models, datasets and Spaces", "url": "https://huggingface.co/mcp", "auth": "none"},
      {"id": "context7", "name": "Context7", "summary": "Up-to-date library docs", "url": "https://mcp.context7.com/mcp", "auth": "none"},
      {"id": "exa", "name": "Exa", "summary": "Web and code search", "url": "https://mcp.exa.ai/mcp", "auth": "none"},
      {"id": "deepwiki", "name": "DeepWiki", "summary": "Ask about any public repo", "url": "https://mcp.deepwiki.com/mcp", "auth": "none"},
      {"id": "cloudflare-docs", "name": "Cloudflare Docs", "summary": "Search Cloudflare's docs", "url": "https://docs.mcp.cloudflare.com/mcp", "auth": "none"},
      {"id": "microsoft-learn", "name": "Microsoft Learn", "summary": "Search Microsoft's docs", "url": "https://learn.microsoft.com/api/mcp", "auth": "none"},
      {"id": "aws-knowledge", "name": "AWS Knowledge", "summary": "Search AWS docs and guidance", "url": "https://knowledge-mcp.global.api.aws", "auth": "none"}
    ]
    """

    /// The curated list. Empty only if the embedded JSON is broken (a test guards that).
    static let entries: [ConnectorCatalogEntry] = (try? decode(json)) ?? []

    /// Reads and checks a catalog: every entry needs an id, a name, a summary and an https URL,
    /// ids and URLs must be unique, and a key-based entry must say where the key comes from.
    static func decode(_ text: String) throws -> [ConnectorCatalogEntry] {
        guard let data = text.data(using: .utf8) else { throw ConnectorCatalogError(message: "The catalog is not text.") }
        let entries: [ConnectorCatalogEntry]
        do {
            entries = try JSONDecoder().decode([ConnectorCatalogEntry].self, from: data)
        } catch {
            throw ConnectorCatalogError(message: "The catalog could not be read: \(error.localizedDescription)")
        }
        var seenIDs: Set<String> = []
        var seenURLs: Set<String> = []
        for entry in entries {
            guard !entry.id.isEmpty, entry.id.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" }) else {
                throw ConnectorCatalogError(message: "Bad id \"\(entry.id)\".")
            }
            guard seenIDs.insert(entry.id).inserted else { throw ConnectorCatalogError(message: "The id \(entry.id) appears twice.") }
            guard !entry.name.trimmingCharacters(in: .whitespaces).isEmpty, !entry.summary.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ConnectorCatalogError(message: "\(entry.id) needs a name and a summary.")
            }
            guard let url = URL(string: entry.url), url.scheme == "https", let host = url.host, host.contains("."), url.user == nil, url.query == nil else {
                throw ConnectorCatalogError(message: "\(entry.id) needs a plain https URL.")
            }
            guard seenURLs.insert(normalized(entry.url)).inserted else { throw ConnectorCatalogError(message: "The URL of \(entry.id) appears twice.") }
            if entry.auth == .apiKey, (entry.keyHint ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                throw ConnectorCatalogError(message: "\(entry.id) takes a key, so it needs a keyHint.")
            }
        }
        return entries
    }

    /// The form the normal "Add connector" path takes.
    static func draft(for entry: ConnectorCatalogEntry, apiKey: String = "") -> McpConnectorDraft {
        McpConnectorDraft(label: entry.name, serverURL: entry.url, apiKey: entry.auth == .apiKey ? apiKey : "")
    }

    /// True when a saved connector already points at this entry's server.
    static func isAdded(_ entry: ConnectorCatalogEntry, serverURLs: [String]) -> Bool {
        let wanted = normalized(entry.url)
        return serverURLs.contains { normalized($0) == wanted }
    }

    static func normalized(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

extension ConnectorCenter {
    /// The server URLs of the saved remote connectors.
    var remoteServerURLs: [String] {
        connectors.compactMap { connector -> String? in
            if case .http(let url, _, _) = connector.transport { return url }
            return nil
        }
    }

    /// One-click add from the catalog: saves the connector exactly as the Add form would, waits
    /// for the server's first answer, and opens the browser sign-in if it asks for one.
    /// Returns the new connector's id; watch `states[id]` for how it went.
    @discardableResult
    func addFromCatalog(_ entry: ConnectorCatalogEntry, apiKey: String = "") async throws -> String {
        if entry.auth == .apiKey, apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConnectorCatalogError(message: "\(entry.name) needs a key. \(entry.keyHint ?? "")")
        }
        let id = try add(ConnectorCatalog.draft(for: entry, apiKey: apiKey))
        await waitUntilSettled(timeout: 15)
        if entry.auth != .apiKey, state(for: id) == .needsSignIn {
            await signIn(id: id)
        }
        return id
    }
}
