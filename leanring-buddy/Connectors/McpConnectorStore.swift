//
//  McpConnectorStore.swift
//  leanring-buddy
//
//  The list of MCP connectors the person added, saved as
//  ~/.teachy/connectors/mcp.json. The file never holds a secret: tokens, API-key
//  headers and secret environment variables live in the Keychain and the file
//  only carries a reference ("keychainRef") to each.
//
//  Also reads the `{"mcpServers": {...}}` shape people already have for other
//  apps, moving any secrets it finds into the Keychain on the way in.
//

import Foundation

// MARK: - Secrets

/// Where connector secrets live. The app uses the Keychain; tests use the in-memory one.
nonisolated protocol McpSecretStore: Sendable {
    func secret(for reference: String) -> String?
    func setSecret(_ value: String, for reference: String) throws
    func removeSecret(for reference: String)
}

nonisolated final class InMemoryMcpSecretStore: McpSecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()

    init() {}

    func secret(for reference: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[reference]
    }

    func setSecret(_ value: String, for reference: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[reference] = value
    }

    func removeSecret(for reference: String) {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: reference)
    }

    var allReferences: [String] {
        lock.lock(); defer { lock.unlock() }
        return values.keys.sorted()
    }
}

// MARK: - Model

nonisolated struct McpConnectorConfig: Sendable, Equatable, Identifiable {
    nonisolated enum Transport: Sendable, Equatable {
        /// `secretEnvironment` maps a variable name to its Keychain reference.
        case stdio(command: String, arguments: [String], environment: [String: String], secretEnvironment: [String: String], workingDirectory: String?)
        /// `secretHeaders` maps a header name to its Keychain reference.
        case http(url: String, headers: [String: String], secretHeaders: [String: String])
    }

    nonisolated enum Auth: Sendable, Equatable {
        case none
        /// A fixed credential. Sent as `<header>: <scheme> <secret>`; the defaults give `Authorization: Bearer <secret>`.
        case bearer(keychainRef: String, header: String, scheme: String)
        case oauth
    }

    var id: String
    var label: String
    var transport: Transport
    var auth: Auth
    var enabled: Bool
    /// Tells two sign-ins to the same server apart ("work", "personal").
    var accountLabel: String?

    init(id: String, label: String, transport: Transport, auth: Auth = .none, enabled: Bool = true, accountLabel: String? = nil) {
        self.id = id
        self.label = label
        self.transport = transport
        self.auth = auth
        self.enabled = enabled
        self.accountLabel = accountLabel
    }

    var isRemote: Bool {
        if case .http = transport { return true }
        return false
    }

    /// "Linear · work"
    var displayName: String {
        guard let accountLabel, !accountLabel.isEmpty else { return label }
        return "\(label) · \(accountLabel)"
    }

    /// What it connects to, safe to show: the URL, or the command line.
    var targetSummary: String {
        switch transport {
        case .http(let url, _, _): return url
        case .stdio(let command, let arguments, _, _, _): return ([command] + arguments).joined(separator: " ")
        }
    }

    var oauthSecretReference: String { "\(id).oauth" }

    /// Every Keychain reference this connector owns (used to clean up on remove).
    var secretReferences: [String] {
        var references: [String] = [oauthSecretReference]
        if case .bearer(let keychainRef, _, _) = auth { references.append(keychainRef) }
        switch transport {
        case .stdio(_, _, _, let secretEnvironment, _): references.append(contentsOf: secretEnvironment.values)
        case .http(_, _, let secretHeaders): references.append(contentsOf: secretHeaders.values)
        }
        return references
    }

    static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasSuffix(".localhost")
    }

    /// Returns a sentence describing what's wrong, or nil when the entry is usable.
    func validationProblem() -> String? {
        if label.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the connector a name." }
        switch transport {
        case .stdio(let command, _, _, _, _):
            if command.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the command that starts the server." }
            if auth != .none { return "A local command can't sign in with a token; put the key in its environment instead." }
        case .http(let urlString, _, let secretHeaders):
            guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), url.host != nil,
                  scheme == "https" || scheme == "http" else {
                return "Enter a full server URL, starting with https://."
            }
            let sendsCredentials = auth != .none || !secretHeaders.isEmpty
            if scheme == "http", sendsCredentials, !Self.isLoopbackHost(url.host) {
                return "Teachy won't send a token over plain http. Use an https:// address."
            }
        }
        return nil
    }
}

nonisolated extension McpConnectorConfig: Codable {
    private enum CodingKeys: String, CodingKey { case id, label, transport, auth, enabled, accountLabel }
    private enum TransportKeys: String, CodingKey { case type, command, args, env, secretEnv, cwd, url, headers, secretHeaders }
    private enum AuthKeys: String, CodingKey { case type, keychainRef, header, scheme }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? id
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        accountLabel = try container.decodeIfPresent(String.self, forKey: .accountLabel)

        let transportContainer = try container.nestedContainer(keyedBy: TransportKeys.self, forKey: .transport)
        let transportType = try transportContainer.decode(String.self, forKey: .type)
        switch transportType {
        case "stdio":
            transport = .stdio(
                command: try transportContainer.decode(String.self, forKey: .command),
                arguments: try transportContainer.decodeIfPresent([String].self, forKey: .args) ?? [],
                environment: try transportContainer.decodeIfPresent([String: String].self, forKey: .env) ?? [:],
                secretEnvironment: try transportContainer.decodeIfPresent([String: String].self, forKey: .secretEnv) ?? [:],
                workingDirectory: try transportContainer.decodeIfPresent(String.self, forKey: .cwd)
            )
        case "http":
            transport = .http(
                url: try transportContainer.decode(String.self, forKey: .url),
                headers: try transportContainer.decodeIfPresent([String: String].self, forKey: .headers) ?? [:],
                secretHeaders: try transportContainer.decodeIfPresent([String: String].self, forKey: .secretHeaders) ?? [:]
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: transportContainer, debugDescription: "Unknown transport \(transportType)")
        }

        if container.contains(.auth) {
            let authContainer = try container.nestedContainer(keyedBy: AuthKeys.self, forKey: .auth)
            switch try authContainer.decode(String.self, forKey: .type) {
            case "bearer":
                auth = .bearer(
                    keychainRef: try authContainer.decode(String.self, forKey: .keychainRef),
                    header: try authContainer.decodeIfPresent(String.self, forKey: .header) ?? "Authorization",
                    scheme: try authContainer.decodeIfPresent(String.self, forKey: .scheme) ?? "Bearer"
                )
            case "oauth":
                auth = .oauth
            default:
                auth = .none
            }
        } else {
            auth = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(accountLabel, forKey: .accountLabel)

        var transportContainer = container.nestedContainer(keyedBy: TransportKeys.self, forKey: .transport)
        switch transport {
        case .stdio(let command, let arguments, let environment, let secretEnvironment, let workingDirectory):
            try transportContainer.encode("stdio", forKey: .type)
            try transportContainer.encode(command, forKey: .command)
            try transportContainer.encode(arguments, forKey: .args)
            if !environment.isEmpty { try transportContainer.encode(environment, forKey: .env) }
            if !secretEnvironment.isEmpty { try transportContainer.encode(secretEnvironment, forKey: .secretEnv) }
            try transportContainer.encodeIfPresent(workingDirectory, forKey: .cwd)
        case .http(let url, let headers, let secretHeaders):
            try transportContainer.encode("http", forKey: .type)
            try transportContainer.encode(url, forKey: .url)
            if !headers.isEmpty { try transportContainer.encode(headers, forKey: .headers) }
            if !secretHeaders.isEmpty { try transportContainer.encode(secretHeaders, forKey: .secretHeaders) }
        }

        var authContainer = container.nestedContainer(keyedBy: AuthKeys.self, forKey: .auth)
        switch auth {
        case .none:
            try authContainer.encode("none", forKey: .type)
        case .bearer(let keychainRef, let header, let scheme):
            try authContainer.encode("bearer", forKey: .type)
            try authContainer.encode(keychainRef, forKey: .keychainRef)
            if header != "Authorization" { try authContainer.encode(header, forKey: .header) }
            if scheme != "Bearer" { try authContainer.encode(scheme, forKey: .scheme) }
        case .oauth:
            try authContainer.encode("oauth", forKey: .type)
        }
    }
}

// MARK: - File

nonisolated struct McpConnectorStore: Sendable {
    let fileURL: URL

    private struct FileShape: Codable {
        var version: Int
        var connectors: [McpConnectorConfig]
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// A missing file is an empty list. A file we can't read is moved aside (never silently
    /// overwritten) and reported.
    func load() -> (connectors: [McpConnectorConfig], problem: String?) {
        guard let data = try? Data(contentsOf: fileURL) else { return ([], nil) }
        do {
            return (try JSONDecoder().decode(FileShape.self, from: data).connectors, nil)
        } catch {
            let asideURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("mcp.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: asideURL)
            return ([], "mcp.json couldn't be read, so it was set aside as \(asideURL.lastPathComponent).")
        }
    }

    func save(_ connectors: [McpConnectorConfig]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(FileShape(version: 1, connectors: connectors))
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

// MARK: - Ids

nonisolated enum McpConnectorIdentity {
    /// A short id from the label ("Linear (work)" → "linear_work"), made unique against `existing`.
    static func makeID(label: String, existing: Set<String>) -> String {
        let base = McpToolNaming.sanitiseConnectorID(label)
        if !existing.contains(base) { return base }
        var counter = 2
        while true {
            let suffix = "_\(counter)"
            let candidate = String(base.prefix(24 - suffix.count)) + suffix
            if !existing.contains(candidate) { return candidate }
            counter += 1
        }
    }
}

// MARK: - Spotting secrets

nonisolated enum McpSecretHeuristics {
    private static let secretNameFragments = [
        "KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PWD", "AUTH", "CREDENTIAL", "COOKIE",
        "BEARER", "SESSION", "PRIVATE", "DSN", "CONNECTION_STRING", "DATABASE_URL", "WEBHOOK",
    ]
    private static let secretValuePrefixes = [
        "sk-", "sk_", "pk_live", "rk_", "ghp_", "gho_", "ghu_", "ghs_", "github_pat_", "glpat-",
        "xoxb-", "xoxp-", "xoxa-", "xapp-", "AKIA", "eyJ", "Bearer ", "Basic ", "ntn_", "secret_", "lin_api_",
    ]

    static func nameLooksSecret(_ name: String) -> Bool {
        let upper = name.uppercased()
        return secretNameFragments.contains { upper.contains($0) }
    }

    static func valueLooksSecret(_ value: String) -> Bool {
        if secretValuePrefixes.contains(where: { value.hasPrefix($0) }) { return true }
        // user:password@ inside a URL
        if let schemeEnd = value.range(of: "://"), let at = value.range(of: "@", range: schemeEnd.upperBound..<value.endIndex),
           value[schemeEnd.upperBound..<at.lowerBound].contains(":") {
            return true
        }
        return false
    }

    static func isSecret(name: String, value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return nameLooksSecret(name) || valueLooksSecret(value)
    }

    /// Whether a command-line flag ("--api-key", "--header") announces a secret in the next argument.
    static func flagAnnouncesSecret(_ flag: String) -> Bool {
        guard flag.hasPrefix("-") else { return false }
        let upper = flag.uppercased().replacingOccurrences(of: "-", with: "_")
        return upper.contains("HEADER") || nameLooksSecret(upper)
    }
}

// MARK: - Import

nonisolated struct McpImportedConnector: Sendable, Equatable {
    var config: McpConnectorConfig
    /// Keychain reference → secret value, to be written to the Keychain by the caller.
    var secrets: [String: String]
}

nonisolated enum McpConfigImportError: Error, Sendable, Equatable, LocalizedError {
    case notJSON
    case noServers
    case invalidEntry(name: String, problem: String)

    var errorDescription: String? {
        switch self {
        case .notJSON: return "That isn't valid JSON. Paste the whole config, including the outer braces."
        case .noServers: return "No servers found. Teachy looks for an \"mcpServers\" block."
        case .invalidEntry(let name, let problem): return "\"\(name)\": \(problem)"
        }
    }
}

nonisolated enum McpConfigImporter {
    /// The prefix of the placeholder variables that stand in for secrets found in arguments.
    static let argumentSecretPrefix = "TEACHY_SECRET_"

    /// Accepts `{"mcpServers": {name: {...}}}` (also "servers" / "mcp_servers"), a bare
    /// `{name: {...}}` map, a single `{command|url ...}` entry, or Teachy's own `{"connectors": [...]}`.
    static func parse(_ text: String, existingIDs: Set<String> = []) throws -> [McpImportedConnector] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var root: JSONValue
        if let parsed = try? JSONValue.parse(trimmed), case .object = parsed {
            root = parsed
        } else if let wrapped = try? JSONValue.parse("{" + trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ",")) + "}"), case .object = wrapped {
            // People often copy just the `"name": {...}` fragment.
            root = wrapped
        } else {
            throw McpConfigImportError.notJSON
        }

        var takenIDs = existingIDs
        var imported: [McpImportedConnector] = []

        // Teachy's own file: already free of secrets.
        if let ownEntries = root["connectors"]?.arrayValue {
            for entry in ownEntries {
                guard let data = try? entry.serialized(),
                      var config = try? JSONDecoder().decode(McpConnectorConfig.self, from: data) else { continue }
                if takenIDs.contains(config.id) { config.id = McpConnectorIdentity.makeID(label: config.id, existing: takenIDs) }
                takenIDs.insert(config.id)
                imported.append(McpImportedConnector(config: config, secrets: [:]))
            }
            if imported.isEmpty { throw McpConfigImportError.noServers }
            return imported
        }

        var servers: [String: JSONValue]
        if let nested = root["mcpServers"]?.objectValue ?? root["mcp_servers"]?.objectValue ?? root["servers"]?.objectValue
            ?? root["mcp"]?["servers"]?.objectValue {
            servers = nested
        } else if looksLikeServerEntry(root) {
            servers = [suggestedName(for: root): root]
        } else {
            servers = (root.objectValue ?? [:]).filter { looksLikeServerEntry($0.value) }
        }
        guard !servers.isEmpty else { throw McpConfigImportError.noServers }

        for name in servers.keys.sorted() {
            guard let entry = servers[name] else { continue }
            let id = McpConnectorIdentity.makeID(label: name, existing: takenIDs)
            takenIDs.insert(id)
            imported.append(try importEntry(name: name, id: id, entry: entry))
        }
        return imported
    }

    private static func looksLikeServerEntry(_ value: JSONValue) -> Bool {
        value["command"]?.stringValue != nil || remoteURL(of: value) != nil
    }

    private static func remoteURL(of entry: JSONValue) -> String? {
        entry["url"]?.stringValue ?? entry["serverUrl"]?.stringValue ?? entry["httpUrl"]?.stringValue ?? entry["uri"]?.stringValue
    }

    private static func suggestedName(for entry: JSONValue) -> String {
        if let urlString = remoteURL(of: entry), let host = URL(string: urlString)?.host {
            return host
        }
        let command = entry["command"]?.stringValue ?? "server"
        let lastArgument = entry["args"]?.arrayValue?.compactMap(\.stringValue).last { !$0.hasPrefix("-") }
        return lastArgument.map { ($0 as NSString).lastPathComponent } ?? (command as NSString).lastPathComponent
    }

    private static func stringMap(_ value: JSONValue?) -> [String: String] {
        var result: [String: String] = [:]
        for (key, member) in value?.objectValue ?? [:] {
            switch member {
            case .string(let text): result[key] = text
            case .int(let number): result[key] = String(number)
            case .double(let number): result[key] = String(number)
            case .bool(let flag): result[key] = flag ? "true" : "false"
            default: break
            }
        }
        return result
    }

    private static func importEntry(name: String, id: String, entry: JSONValue) throws -> McpImportedConnector {
        var secrets: [String: String] = [:]
        let enabled = !(entry["disabled"]?.boolValue ?? false) && (entry["enabled"]?.boolValue ?? true)

        if let urlString = remoteURL(of: entry) {
            var plainHeaders: [String: String] = [:]
            var secretHeaders: [String: String] = [:]
            var auth = McpConnectorConfig.Auth.none

            for (headerName, headerValue) in stringMap(entry["headers"]).sorted(by: { $0.key < $1.key }) {
                if headerName.lowercased() == "authorization" {
                    // "Bearer abc" → scheme "Bearer", secret "abc". Anything else is kept whole.
                    let pieces = headerValue.split(separator: " ", maxSplits: 1).map(String.init)
                    let reference = "\(id).bearer"
                    if pieces.count == 2 {
                        auth = .bearer(keychainRef: reference, header: "Authorization", scheme: pieces[0])
                        secrets[reference] = pieces[1]
                    } else {
                        auth = .bearer(keychainRef: reference, header: "Authorization", scheme: "")
                        secrets[reference] = headerValue
                    }
                } else if isHarmlessHeader(headerName) {
                    plainHeaders[headerName] = headerValue
                } else {
                    // An unknown header in someone's config is far more likely a key than not.
                    let reference = "\(id).header.\(headerName)"
                    secretHeaders[headerName] = reference
                    secrets[reference] = headerValue
                }
            }

            let config = McpConnectorConfig(
                id: id,
                label: name,
                transport: .http(url: urlString, headers: plainHeaders, secretHeaders: secretHeaders),
                auth: auth,
                enabled: enabled
            )
            if let problem = config.validationProblem() { throw McpConfigImportError.invalidEntry(name: name, problem: problem) }
            return McpImportedConnector(config: config, secrets: secrets)
        }

        guard let command = entry["command"]?.stringValue, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw McpConfigImportError.invalidEntry(name: name, problem: "needs either \"command\" or \"url\".")
        }

        var plainEnvironment: [String: String] = [:]
        var secretEnvironment: [String: String] = [:]
        for (variableName, variableValue) in stringMap(entry["env"]) {
            if McpSecretHeuristics.isSecret(name: variableName, value: variableValue) {
                let reference = "\(id).env.\(variableName)"
                secretEnvironment[variableName] = reference
                secrets[reference] = variableValue
            } else {
                plainEnvironment[variableName] = variableValue
            }
        }

        // Secrets typed straight into the arguments (`--api-key abc`, `--header "Authorization: Bearer abc"`)
        // become `${TEACHY_SECRET_n}` placeholders, filled back in from the Keychain at launch.
        var arguments: [String] = []
        var secretArgumentCount = 0
        var previousArgument: String?
        for argument in entry["args"]?.arrayValue?.map({ $0.stringValue ?? $0.serializedString() }) ?? [] {
            var storedArgument = argument
            let alreadyPlaceholder = argument.contains("${")
            if !alreadyPlaceholder {
                var secretPart: String?
                var prefix = ""
                if let equalsIndex = argument.firstIndex(of: "="), argument.hasPrefix("-"),
                   McpSecretHeuristics.flagAnnouncesSecret(String(argument[..<equalsIndex])) {
                    prefix = String(argument[...equalsIndex])
                    secretPart = String(argument[argument.index(after: equalsIndex)...])
                } else if let previousArgument, McpSecretHeuristics.flagAnnouncesSecret(previousArgument), !argument.hasPrefix("-") {
                    secretPart = argument
                } else if McpSecretHeuristics.valueLooksSecret(argument) {
                    secretPart = argument
                }
                if let secretPart, !secretPart.isEmpty {
                    secretArgumentCount += 1
                    let variableName = "\(argumentSecretPrefix)\(secretArgumentCount)"
                    let reference = "\(id).env.\(variableName)"
                    secretEnvironment[variableName] = reference
                    secrets[reference] = secretPart
                    storedArgument = prefix + "${\(variableName)}"
                }
            }
            arguments.append(storedArgument)
            previousArgument = argument
        }

        let config = McpConnectorConfig(
            id: id,
            label: name,
            transport: .stdio(
                command: command,
                arguments: arguments,
                environment: plainEnvironment,
                secretEnvironment: secretEnvironment,
                workingDirectory: entry["cwd"]?.stringValue
            ),
            auth: .none,
            enabled: enabled
        )
        return McpImportedConnector(config: config, secrets: secrets)
    }

    private static func isHarmlessHeader(_ name: String) -> Bool {
        ["accept", "accept-language", "content-type", "user-agent", "mcp-protocol-version"].contains(name.lowercased())
    }

    /// Replaces `${TEACHY_SECRET_n}` placeholders in arguments with their values.
    static func expandArgumentSecrets(_ arguments: [String], values: [String: String]) -> [String] {
        arguments.map { argument in
            guard argument.contains("${\(argumentSecretPrefix)") else { return argument }
            var expanded = argument
            for (name, value) in values where name.hasPrefix(argumentSecretPrefix) {
                expanded = expanded.replacingOccurrences(of: "${\(name)}", with: value)
            }
            return expanded
        }
    }
}

// MARK: - Building a transport from a saved entry

nonisolated enum McpTransportBuilder {
    /// Reads the entry's secrets and builds its transport. `oauth` is the connector's OAuth
    /// manager when its auth is `.oauth`.
    static func makeTransport(
        for config: McpConnectorConfig,
        secrets: any McpSecretStore,
        oauth: (any McpAuthProvider)?,
        pathProvider: (@Sendable () async -> String)? = nil
    ) throws -> any McpTransport {
        if let problem = config.validationProblem() { throw McpError.invalidConfiguration(problem) }

        switch config.transport {
        case .stdio(let command, let arguments, let environment, let secretEnvironment, let workingDirectory):
            var fullEnvironment = environment
            var secretValues: [String: String] = [:]
            for (variableName, reference) in secretEnvironment {
                guard let value = secrets.secret(for: reference) else { continue }
                secretValues[variableName] = value
                // Placeholder variables exist only to fill arguments; don't leak them into the child's environment.
                if !variableName.hasPrefix(McpConfigImporter.argumentSecretPrefix) { fullEnvironment[variableName] = value }
            }
            let expandedArguments = McpConfigImporter.expandArgumentSecrets(arguments, values: secretValues)
            if let pathProvider {
                return McpStdioTransport(
                    command: command, arguments: expandedArguments, environment: fullEnvironment,
                    workingDirectory: workingDirectory, redactions: Array(secretValues.values), pathProvider: pathProvider
                )
            }
            return McpStdioTransport(
                command: command, arguments: expandedArguments, environment: fullEnvironment,
                workingDirectory: workingDirectory, redactions: Array(secretValues.values)
            )

        case .http(let urlString, let headers, let secretHeaders):
            guard let url = URL(string: urlString) else { throw McpError.invalidConfiguration("The server URL isn't valid.") }
            var staticHeaders = headers
            var carriesCredentials = false
            for (headerName, reference) in secretHeaders {
                if let value = secrets.secret(for: reference) {
                    staticHeaders[headerName] = value
                    carriesCredentials = true
                }
            }
            var authProvider: (any McpAuthProvider)?
            switch config.auth {
            case .none:
                authProvider = nil
            case .bearer(let keychainRef, let header, let scheme):
                // A missing secret is sent as no header at all, and the server's 401 surfaces as "needs sign-in".
                if let token = secrets.secret(for: keychainRef), !token.isEmpty {
                    let value = scheme.isEmpty ? token : "\(scheme) \(token)"
                    authProvider = McpStaticHeaderAuth(headers: [header: value])
                }
            case .oauth:
                authProvider = oauth
            }
            return McpHTTPTransport(
                url: url,
                staticHeaders: staticHeaders,
                staticHeadersCarryCredentials: carriesCredentials,
                auth: authProvider
            )
        }
    }
}
