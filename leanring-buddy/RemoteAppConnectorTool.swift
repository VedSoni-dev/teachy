//
//  RemoteAppConnectorTool.swift
//  Proxies a single tool call to a local HTTP App Connector.
//

import Foundation

final class RemoteAppConnectorTool: BackgroundAgentTool {
    let connectorID: String
    let connectorName: String
    let baseURL: URL
    let remoteToolName: String

    let name: String
    let description: String
    let jsonSchema: [String: Any]

    init(
        connectorID: String,
        connectorName: String,
        baseURL: URL,
        remoteToolDefinition: AppConnectorRemoteToolDefinition
    ) {
        self.connectorID = connectorID
        self.connectorName = connectorName
        self.baseURL = baseURL
        self.remoteToolName = remoteToolDefinition.name
        self.name = AppConnectorToolNaming.registeredToolName(
            connectorID: connectorID,
            remoteToolName: remoteToolDefinition.name
        )
        self.description = "[\(connectorName)] \(remoteToolDefinition.description)"
        self.jsonSchema = remoteToolDefinition.inputSchema
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let invokeURL = baseURL
            .appendingPathComponent("tools")
            .appendingPathComponent(remoteToolName)

        var request = URLRequest(url: invokeURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody: [String: Any] = ["arguments": arguments]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "RemoteAppConnectorTool",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response from \(connectorName)"]
            )
        }

        let responseText = String(data: data, encoding: .utf8) ?? "(binary \(data.count) bytes)"

        if let responseObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errorMessage = responseObject["error"] as? String {
                return "Error from \(connectorName): \(errorMessage)"
            }
            if let result = responseObject["result"] {
                if let resultString = result as? String {
                    return resultString
                }
                if let resultData = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
                   let resultJSON = String(data: resultData, encoding: .utf8) {
                    return resultJSON
                }
            }
        }

        if (200...299).contains(httpResponse.statusCode) {
            return responseText
        }

        return "HTTP \(httpResponse.statusCode) from \(connectorName):\n\(responseText.prefix(8000))"
    }
}
