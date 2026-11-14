//
//  McpConnectorState.swift
//  leanring-buddy
//
//  What the Home tab shows next to a connector, the form data for adding one,
//  and splitting a typed command line into command + arguments.
//

import Foundation

nonisolated enum McpConnectorState: Sendable, Equatable {
    /// Not connected and not trying (switched off, or never started).
    case idle
    case checking
    case connected(toolCount: Int)
    /// The server wants a browser sign-in (OAuth).
    case needsSignIn
    /// The server refused the saved API key or token.
    case tokenRejected
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// One short line for the row.
    var summary: String {
        switch self {
        case .idle: return "Not connected"
        case .checking: return "Checking…"
        case .connected(let toolCount): return toolCount == 1 ? "Connected · 1 tool" : "Connected · \(toolCount) tools"
        case .needsSignIn: return "Needs sign-in"
        case .tokenRejected: return "Token rejected"
        case .failed(let message): return message
        }
    }

    /// Turns a connection error into a state. Which auth the connector uses decides whether a
    /// refusal means "sign in" or "that token is wrong".
    static func describing(_ error: Error, auth: McpConnectorConfig.Auth) -> McpConnectorState {
        if error is CancellationError { return .idle }
        if let mcpError = error as? McpError {
            switch mcpError {
            case .needsSignIn:
                return .needsSignIn
            case .unauthorized(let hadCredentials, _):
                switch auth {
                case .bearer: return .tokenRejected
                case .oauth: return .needsSignIn
                case .none: return hadCredentials ? .tokenRejected : .needsSignIn
                }
            default:
                break
            }
        }
        return .failed(message(for: error))
    }

    static func message(for error: Error) -> String {
        var text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 280 { text = String(text.prefix(280)) + "…" }
        return text.isEmpty ? "Couldn't connect." : text
    }
}

/// What the "Add connector" form collects.
nonisolated struct McpConnectorDraft: Sendable, Equatable {
    var label: String = ""
    /// Set for a remote server.
    var serverURL: String = ""
    /// Set for a local server: the whole command line, e.g. `API_KEY=abc npx -y some-server`.
    var commandLine: String = ""
    /// Remote only. Either a bare key (sent as `Authorization: Bearer <key>`) or `Header-Name: value`.
    var apiKey: String = ""
    var accountLabel: String = ""

    init(label: String = "", serverURL: String = "", commandLine: String = "", apiKey: String = "", accountLabel: String = "") {
        self.label = label
        self.serverURL = serverURL
        self.commandLine = commandLine
        self.apiKey = apiKey
        self.accountLabel = accountLabel
    }

    /// Builds the saved entry plus the secrets that belong in the Keychain.
    func build(existingIDs: Set<String>) throws -> McpImportedConnector {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccount = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else { throw McpError.invalidConfiguration("Give the connector a name.") }
        guard trimmedURL.isEmpty != trimmedCommand.isEmpty else {
            throw McpError.invalidConfiguration("Enter either a server URL or a local command.")
        }

        // Two accounts on one server get ids like "linear_work" and "linear_personal".
        let idSeed = trimmedAccount.isEmpty ? trimmedLabel : "\(trimmedLabel)_\(trimmedAccount)"
        let id = McpConnectorIdentity.makeID(label: idSeed, existing: existingIDs)
        var secrets: [String: String] = [:]
        let config: McpConnectorConfig

        if !trimmedURL.isEmpty {
            var auth = McpConnectorConfig.Auth.none
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                let reference = "\(id).bearer"
                if let (header, value) = Self.splitHeader(trimmedKey) {
                    if header.lowercased() == "authorization", let space = value.firstIndex(of: " ") {
                        auth = .bearer(keychainRef: reference, header: "Authorization", scheme: String(value[..<space]))
                        secrets[reference] = String(value[value.index(after: space)...]).trimmingCharacters(in: .whitespaces)
                    } else {
                        auth = .bearer(keychainRef: reference, header: header, scheme: "")
                        secrets[reference] = value
                    }
                } else {
                    var token = trimmedKey
                    if token.lowercased().hasPrefix("bearer ") { token = String(token.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
                    auth = .bearer(keychainRef: reference, header: "Authorization", scheme: "Bearer")
                    secrets[reference] = token
                }
            }
            config = McpConnectorConfig(
                id: id, label: trimmedLabel,
                transport: .http(url: trimmedURL, headers: [:], secretHeaders: [:]),
                auth: auth, enabled: true, accountLabel: trimmedAccount.isEmpty ? nil : trimmedAccount
            )
        } else {
            var words = McpCommandLine.split(trimmedCommand)
            var plainEnvironment: [String: String] = [:]
            var secretEnvironment: [String: String] = [:]
            // Leading NAME=value words are environment variables, as in a shell.
            while let first = words.first, let assignment = McpCommandLine.environmentAssignment(first) {
                words.removeFirst()
                if McpSecretHeuristics.isSecret(name: assignment.name, value: assignment.value) {
                    let reference = "\(id).env.\(assignment.name)"
                    secretEnvironment[assignment.name] = reference
                    secrets[reference] = assignment.value
                } else {
                    plainEnvironment[assignment.name] = assignment.value
                }
            }
            guard let command = words.first else { throw McpError.invalidConfiguration("Enter the command that starts the server.") }
            config = McpConnectorConfig(
                id: id, label: trimmedLabel,
                transport: .stdio(
                    command: command, arguments: Array(words.dropFirst()),
                    environment: plainEnvironment, secretEnvironment: secretEnvironment, workingDirectory: nil
                ),
                auth: .none, enabled: true, accountLabel: trimmedAccount.isEmpty ? nil : trimmedAccount
            )
        }

        if let problem = config.validationProblem() { throw McpError.invalidConfiguration(problem) }
        return McpImportedConnector(config: config, secrets: secrets)
    }

    /// "X-API-Key: abc" → ("X-API-Key", "abc"). Nil for a bare key.
    static func splitHeader(_ text: String) -> (String, String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let name = String(text[..<colon])
        let value = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        let isHeaderName = !name.isEmpty && name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
        guard isHeaderName, !value.isEmpty, text[text.index(after: colon)...].hasPrefix(" ") else { return nil }
        return (name, value)
    }
}

nonisolated enum McpCommandLine {
    /// Splits like a shell would for the simple cases: spaces separate, single and double
    /// quotes group, backslash escapes the next character. No variables, no globbing.
    static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?
        var isEscaped = false

        for character in line {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if character == "\\" && activeQuote == "\"" {
                    isEscaped = true
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\\" {
                isEscaped = true
                hasCurrent = true
            } else if character == "\"" || character == "'" {
                quote = character
                hasCurrent = true
            } else if character == " " || character == "\t" || character == "\n" {
                if hasCurrent || !current.isEmpty { words.append(current) }
                current = ""
                hasCurrent = false
            } else {
                current.append(character)
            }
        }
        if hasCurrent || !current.isEmpty { words.append(current) }
        return words
    }

    /// `NAME=value` with a valid variable name.
    static func environmentAssignment(_ word: String) -> (name: String, value: String)? {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return nil }
        let name = String(word[..<equals])
        guard let firstScalar = name.unicodeScalars.first,
              firstScalar == "_" || CharacterSet.letters.contains(firstScalar),
              name.unicodeScalars.allSatisfy({ $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }) else {
            return nil
        }
        return (name, String(word[word.index(after: equals)...]))
    }
}
