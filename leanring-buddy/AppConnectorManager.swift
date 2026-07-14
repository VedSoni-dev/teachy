//
//  AppConnectorManager.swift
//  Discovers local App Connectors and registers their tools with the agent.
//

import Combine
import Foundation

@MainActor
final class AppConnectorManager: ObservableObject {
    @Published private(set) var connectionStates: [AppConnectorConnectionState] = []

    private let toolRegistry: BackgroundAgentToolRegistry

    init(toolRegistry: BackgroundAgentToolRegistry) {
        self.toolRegistry = toolRegistry
    }

    func refreshConnectors() async {
        ensureConnectorsDirectoryExists()
        installSeedConnectorFilesIfNeeded()

        let manifests = loadManifestsFromDisk()
        var newConnectionStates: [AppConnectorConnectionState] = []
        var connectorToolsToRegister: [any BackgroundAgentTool] = []

        for manifest in manifests {
            if !manifest.isEnabled {
                newConnectionStates.append(
                    AppConnectorConnectionState(
                        connectorID: manifest.connectorID,
                        name: manifest.name,
                        description: manifest.description,
                        transportKind: transportKind(for: manifest.transport),
                        status: .disabled,
                        registeredToolNames: [],
                        lastError: nil
                    )
                )
                continue
            }

            guard let baseURL = URL(string: manifest.transport.baseURL) else {
                newConnectionStates.append(
                    misconfiguredState(
                        for: manifest,
                        errorMessage: "Invalid base_url in connector manifest"
                    )
                )
                continue
            }

            do {
                let connectorTools: [any BackgroundAgentTool]
                let transportKind = transportKind(for: manifest.transport)

                if manifest.transport.isOpenAPITransport {
                    connectorTools = try await loadOpenAPIConnectorTools(
                        manifest: manifest,
                        baseURL: baseURL
                    )
                } else if manifest.transport.isHTTPTransport {
                    try await verifyLegacyConnectorHealth(
                        baseURL: baseURL,
                        expectedConnectorID: manifest.connectorID
                    )
                    connectorTools = try await loadLegacyHTTPConnectorTools(
                        manifest: manifest,
                        baseURL: baseURL
                    )
                } else {
                    throw NSError(
                        domain: "AppConnectorManager",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Unsupported transport type: \(manifest.transport.type)"]
                    )
                }

                connectorToolsToRegister.append(contentsOf: connectorTools)

                newConnectionStates.append(
                    AppConnectorConnectionState(
                        connectorID: manifest.connectorID,
                        name: manifest.name,
                        description: manifest.description,
                        transportKind: transportKind,
                        status: .connected,
                        registeredToolNames: connectorTools.map(\.name),
                        lastError: nil
                    )
                )
            } catch {
                newConnectionStates.append(
                    AppConnectorConnectionState(
                        connectorID: manifest.connectorID,
                        name: manifest.name,
                        description: manifest.description,
                        transportKind: transportKind(for: manifest.transport),
                        status: .unreachable,
                        registeredToolNames: [],
                        lastError: error.localizedDescription
                    )
                )
            }
        }

        toolRegistry.unregisterAllConnectorTools()
        toolRegistry.registerConnectorTools(connectorToolsToRegister)
        connectionStates = newConnectionStates
    }

    func connectorPromptSection() -> String {
        let connectedConnectors = connectionStates.filter { $0.status == .connected }
        guard !connectedConnectors.isEmpty else { return "" }

        var lines = ["Connections / custom app tools (prefer these over ui_action when the task matches):"]
        for connector in connectedConnectors {
            let toolList = connector.registeredToolNames
                .map { registeredName in
                    registeredName.split(separator: "__", maxSplits: 1).last.map(String.init) ?? registeredName
                }
                .joined(separator: ", ")
            let descriptionSuffix = connector.description.map { " — \($0)" } ?? ""
            let transportLabel = connector.transportKind == .openapi ? "OpenAPI" : "Teachy HTTP"
            lines.append("- \(connector.name) (\(connector.connectorID), \(transportLabel))\(descriptionSuffix)")
            lines.append("  Tools: \(toolList). Call with the full registered name, e.g. \(connector.registeredToolNames.first ?? "connector_id__tool_name").")
        }
        lines.append("- Connection tools talk directly to the app's API. Do not use ui_action or screenshots for tasks these tools can handle.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Disk

    private func ensureConnectorsDirectoryExists() {
        let directoryURL = AppConnectorDefaults.connectorsDirectoryURL
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func installSeedConnectorFilesIfNeeded() {
        installSeedManifestIfNeeded()
        installSeedOpenAPISpecIfNeeded()
        upgradePlantMaintManifestToOpenAPIIfNeeded()
    }

    private func installSeedManifestIfNeeded() {
        let seedFileURL = AppConnectorDefaults.connectorsDirectoryURL
            .appendingPathComponent("\(AppConnectorDefaults.plantMaintConnectorID).json")

        guard !FileManager.default.fileExists(atPath: seedFileURL.path) else { return }

        do {
            let seedData = try AppConnectorDefaults.seedManifestJSONData()
            try seedData.write(to: seedFileURL)
            print("📎 Installed seed connection manifest at \(seedFileURL.path)")
        } catch {
            print("⚠️ Failed to install seed connection manifest: \(error)")
        }
    }

    private func installSeedOpenAPISpecIfNeeded() {
        let destinationURL = AppConnectorDefaults.connectorsDirectoryURL
            .appendingPathComponent(AppConnectorDefaults.plantMaintBundledOpenAPISpecFileName)

        guard !FileManager.default.fileExists(atPath: destinationURL.path) else { return }

        if let bundledSpecURL = AppConnectorDefaults.bundledPlantMaintOpenAPISpecURL,
           let bundledSpecData = try? Data(contentsOf: bundledSpecURL) {
            try? bundledSpecData.write(to: destinationURL)
            return
        }

        let repoSpecURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("connectors/plant-maint/openapi.json")

        if let repoSpecData = try? Data(contentsOf: repoSpecURL) {
            try? repoSpecData.write(to: destinationURL)
        }
    }

    private func upgradePlantMaintManifestToOpenAPIIfNeeded() {
        let manifestURL = AppConnectorDefaults.connectorsDirectoryURL
            .appendingPathComponent("\(AppConnectorDefaults.plantMaintConnectorID).json")

        guard let manifestData = try? Data(contentsOf: manifestURL),
              var manifestObject = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              var transportObject = manifestObject["transport"] as? [String: Any],
              transportObject["type"] as? String == "http" else {
            return
        }

        transportObject["type"] = "openapi"
        transportObject["spec_url"] = AppConnectorDefaults.plantMaintOpenAPISpecURL
        manifestObject["transport"] = transportObject

        guard let upgradedData = try? JSONSerialization.data(
            withJSONObject: manifestObject,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return
        }

        try? upgradedData.write(to: manifestURL)
        print("📎 Upgraded plant-maint connection manifest to OpenAPI transport")
    }

    private func loadManifestsFromDisk() -> [AppConnectorManifest] {
        let directoryURL = AppConnectorDefaults.connectorsDirectoryURL
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        return fileURLs
            .filter { $0.pathExtension.lowercased() == "json" }
            .filter { !$0.lastPathComponent.contains(".openapi.") }
            .compactMap { fileURL -> AppConnectorManifest? in
                guard let data = try? Data(contentsOf: fileURL) else { return nil }
                return try? decoder.decode(AppConnectorManifest.self, from: data)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - OpenAPI

    private func loadOpenAPIConnectorTools(
        manifest: AppConnectorManifest,
        baseURL: URL
    ) async throws -> [any BackgroundAgentTool] {
        let specData = try await loadOpenAPISpecData(
            transport: manifest.transport,
            manifestConnectorID: manifest.connectorID
        )
        let operations = try OpenAPIConnectorParser.parseOperations(from: specData)

        try await verifyOpenAPIConnectorHealth(baseURL: baseURL, expectedConnectorID: manifest.connectorID)

        return operations.map { operation in
            OpenAPIConnectorTool(
                connectorID: manifest.connectorID,
                connectorName: manifest.name,
                baseURL: baseURL,
                operation: operation
            )
        }
    }

    private func loadOpenAPISpecData(
        transport: AppConnectorTransport,
        manifestConnectorID: String
    ) async throws -> Data {
        if let specURLString = transport.specURL,
           let specURL = URL(string: specURLString) {
            var request = URLRequest(url: specURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw NSError(
                    domain: "AppConnectorManager",
                    code: -10,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to fetch OpenAPI spec from \(specURLString)"]
                )
            }
            return data
        }

        if let specPath = transport.specPath {
            let expandedPath = (specPath as NSString).expandingTildeInPath
            let specFileURL = URL(fileURLWithPath: expandedPath, isDirectory: false)
            return try Data(contentsOf: specFileURL)
        }

        let defaultLocalSpecURL = AppConnectorDefaults.connectorsDirectoryURL
            .appendingPathComponent("\(manifestConnectorID).openapi.json")
        if FileManager.default.fileExists(atPath: defaultLocalSpecURL.path) {
            return try Data(contentsOf: defaultLocalSpecURL)
        }

        throw NSError(
            domain: "AppConnectorManager",
            code: -11,
            userInfo: [NSLocalizedDescriptionKey: "OpenAPI connector is missing spec_url or spec_path"]
        )
    }

    private func verifyOpenAPIConnectorHealth(baseURL: URL, expectedConnectorID: String) async throws {
        let healthURL = baseURL.appendingPathComponent("health")
        var request = URLRequest(url: healthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "AppConnectorManager",
                code: -12,
                userInfo: [NSLocalizedDescriptionKey: "Connection not reachable at \(baseURL.absoluteString)"]
            )
        }

        if let responseObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let reportedConnectorID = responseObject["connector_id"] as? String,
           reportedConnectorID != expectedConnectorID {
            throw NSError(
                domain: "AppConnectorManager",
                code: -13,
                userInfo: [NSLocalizedDescriptionKey: "Connector ID mismatch: expected \(expectedConnectorID), got \(reportedConnectorID)"]
            )
        }
    }

    // MARK: - Legacy Teachy HTTP connector

    private func loadLegacyHTTPConnectorTools(
        manifest: AppConnectorManifest,
        baseURL: URL
    ) async throws -> [any BackgroundAgentTool] {
        let remoteToolDefinitions = try await fetchLegacyRemoteToolDefinitions(baseURL: baseURL)
        return remoteToolDefinitions.map { toolDefinition in
            RemoteAppConnectorTool(
                connectorID: manifest.connectorID,
                connectorName: manifest.name,
                baseURL: baseURL,
                remoteToolDefinition: toolDefinition
            )
        }
    }

    private func verifyLegacyConnectorHealth(baseURL: URL, expectedConnectorID: String) async throws {
        try await verifyOpenAPIConnectorHealth(baseURL: baseURL, expectedConnectorID: expectedConnectorID)
    }

    private func fetchLegacyRemoteToolDefinitions(baseURL: URL) async throws -> [AppConnectorRemoteToolDefinition] {
        let toolsURL = baseURL.appendingPathComponent("tools")
        var request = URLRequest(url: toolsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "AppConnectorManager",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: "Failed to fetch tools from \(baseURL.absoluteString)"]
            )
        }

        guard let responseObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "AppConnectorManager",
                code: -21,
                userInfo: [NSLocalizedDescriptionKey: "Invalid tools response from connector"]
            )
        }

        let toolDefinitions = AppConnectorRemoteToolDefinition.parseList(from: responseObject)
        guard !toolDefinitions.isEmpty else {
            throw NSError(
                domain: "AppConnectorManager",
                code: -22,
                userInfo: [NSLocalizedDescriptionKey: "Connector returned no tools"]
            )
        }

        return toolDefinitions
    }

    // MARK: - Helpers

    private func transportKind(for transport: AppConnectorTransport) -> AppConnectorTransportKind {
        transport.isOpenAPITransport ? .openapi : .http
    }

    private func misconfiguredState(
        for manifest: AppConnectorManifest,
        errorMessage: String
    ) -> AppConnectorConnectionState {
        AppConnectorConnectionState(
            connectorID: manifest.connectorID,
            name: manifest.name,
            description: manifest.description,
            transportKind: transportKind(for: manifest.transport),
            status: .misconfigured,
            registeredToolNames: [],
            lastError: errorMessage
        )
    }
}
