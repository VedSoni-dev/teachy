//
//  AppConnectorManifest.swift
//  Connector manifest types for Teachy App Connectors.
//

import Foundation

// MARK: - Manifest

struct AppConnectorManifest: Codable, Identifiable {
    let connectorID: String
    let name: String
    let description: String?
    let transport: AppConnectorTransport
    let enabled: Bool?

    var id: String { connectorID }

    var isEnabled: Bool { enabled ?? true }

    enum CodingKeys: String, CodingKey {
        case connectorID = "connector_id"
        case name
        case description
        case transport
        case enabled
    }
}

struct AppConnectorTransport: Codable {
    let type: String
    let baseURL: String
    let specURL: String?
    let specPath: String?

    enum CodingKeys: String, CodingKey {
        case type
        case baseURL = "base_url"
        case specURL = "spec_url"
        case specPath = "spec_path"
    }

    var isHTTPTransport: Bool { type == "http" }
    var isOpenAPITransport: Bool { type == "openapi" }
}

enum AppConnectorTransportKind: String {
    case http
    case openapi
}

// MARK: - Remote tool definitions (fetched from connector at runtime)

struct AppConnectorRemoteToolDefinition {
    let name: String
    let description: String
    let inputSchema: [String: Any]

    static func parseList(from responseObject: [String: Any]) -> [AppConnectorRemoteToolDefinition] {
        guard let toolObjects = responseObject["tools"] as? [[String: Any]] else {
            return []
        }

        return toolObjects.compactMap { toolObject in
            guard let name = toolObject["name"] as? String,
                  let description = toolObject["description"] as? String else {
                return nil
            }

            let inputSchema = toolObject["input_schema"] as? [String: Any]
                ?? toolObject["parameters"] as? [String: Any]
                ?? ["type": "object", "properties": [:] as [String: Any]]

            return AppConnectorRemoteToolDefinition(
                name: name,
                description: description,
                inputSchema: inputSchema
            )
        }
    }
}

// MARK: - Connection state (for UI + agent prompt)

enum AppConnectorStatus: Equatable {
    case connected
    case disabled
    case unreachable
    case misconfigured
}

struct AppConnectorConnectionState: Identifiable, Equatable {
    let connectorID: String
    let name: String
    let description: String?
    let transportKind: AppConnectorTransportKind
    let status: AppConnectorStatus
    let registeredToolNames: [String]
    let lastError: String?

    var id: String { connectorID }
}

// MARK: - Tool naming

enum AppConnectorToolNaming {
    /// Namespaced tool name registered with the agent, e.g. `plant_maint__create_work_order`.
    static func registeredToolName(connectorID: String, remoteToolName: String) -> String {
        let sanitizedConnectorID = connectorID
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "\(sanitizedConnectorID)__\(remoteToolName)"
    }

    static func parseRegisteredToolName(_ registeredToolName: String) -> (connectorID: String, remoteToolName: String)? {
        let parts = registeredToolName.split(separator: "__", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (connectorID: parts[0], remoteToolName: parts[1])
    }
}

// MARK: - Default seed manifest

enum AppConnectorDefaults {
    static let plantMaintConnectorID = "plant-maint"
    static let plantMaintBaseURL = "http://127.0.0.1:9477"

    static var connectorsDirectoryURL: URL {
        TeachyDataPaths.connectorsDirectoryURL
    }

    static let plantMaintOpenAPISpecURL = "http://127.0.0.1:9477/openapi.json"
    static let plantMaintBundledOpenAPISpecFileName = "plant-maint.openapi.json"

    static let plantMaintSeedManifest: AppConnectorManifest = AppConnectorManifest(
        connectorID: plantMaintConnectorID,
        name: "Plant Maintenance ERP",
        description: "Legacy plant maintenance system — work orders, assets, and status updates via OpenAPI instead of UI automation.",
        transport: AppConnectorTransport(
            type: "openapi",
            baseURL: plantMaintBaseURL,
            specURL: plantMaintOpenAPISpecURL,
            specPath: nil
        ),
        enabled: true
    )

    static func seedManifestJSONData() throws -> Data {
        let seedObject: [String: Any] = [
            "connector_id": plantMaintConnectorID,
            "name": plantMaintSeedManifest.name,
            "description": plantMaintSeedManifest.description as Any,
            "transport": [
                "type": "openapi",
                "base_url": plantMaintBaseURL,
                "spec_url": plantMaintOpenAPISpecURL
            ],
            "enabled": true
        ]
        return try JSONSerialization.data(withJSONObject: seedObject, options: [.prettyPrinted, .sortedKeys])
    }

    static var bundledPlantMaintOpenAPISpecURL: URL? {
        Bundle.main.url(
            forResource: "plant-maint.openapi",
            withExtension: "json",
            subdirectory: "AppConnectors"
        )
    }
}
