//
//  OpenAPIConnectorTool.swift
//  Executes a single OpenAPI operation as a Clicky agent tool.
//

import Foundation

final class OpenAPIConnectorTool: BackgroundAgentTool {
    let connectorID: String
    let connectorName: String
    let baseURL: URL
    let operation: OpenAPIConnectorOperation

    let name: String
    let description: String
    let jsonSchema: [String: Any]

    init(
        connectorID: String,
        connectorName: String,
        baseURL: URL,
        operation: OpenAPIConnectorOperation
    ) {
        self.connectorID = connectorID
        self.connectorName = connectorName
        self.baseURL = baseURL
        self.operation = operation
        self.name = AppConnectorToolNaming.registeredToolName(
            connectorID: connectorID,
            remoteToolName: operation.operationID
        )
        self.description = "[\(connectorName)] \(operation.description)"
        self.jsonSchema = operation.inputSchema
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let requestComponents = try buildRequestComponents(arguments: arguments)

        var request = URLRequest(url: requestComponents.url)
        request.httpMethod = operation.httpMethod
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let requestBodyData = requestComponents.bodyData {
            request.httpBody = requestBodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "OpenAPIConnectorTool",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response from \(connectorName)"]
            )
        }

        let responseText = String(data: data, encoding: .utf8) ?? "(binary \(data.count) bytes)"

        if (200...299).contains(httpResponse.statusCode) {
            if let responseObject = try? JSONSerialization.jsonObject(with: data),
               let prettyData = try? JSONSerialization.data(withJSONObject: responseObject, options: [.prettyPrinted, .sortedKeys]),
               let prettyJSON = String(data: prettyData, encoding: .utf8) {
                return prettyJSON
            }
            return responseText
        }

        if let responseObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errorMessage = responseObject["error"] as? String {
            return "Error from \(connectorName) (HTTP \(httpResponse.statusCode)): \(errorMessage)"
        }

        return "HTTP \(httpResponse.statusCode) from \(connectorName):\n\(responseText.prefix(8000))"
    }

    private struct BuiltRequestComponents {
        let url: URL
        let bodyData: Data?
    }

    private func buildRequestComponents(arguments: [String: Any]) throws -> BuiltRequestComponents {
        var remainingArguments = arguments
        var resolvedPath = operation.pathTemplate

        let pathParameterNames = pathParameterNames(in: operation.pathTemplate)
        for pathParameterName in pathParameterNames {
            guard let pathValue = remainingArguments.removeValue(forKey: pathParameterName) else {
                throw NSError(
                    domain: "OpenAPIConnectorTool",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Missing required path parameter '\(pathParameterName)'"]
                )
            }
            let pathValueString = stringifyArgumentValue(pathValue)
            resolvedPath = resolvedPath.replacingOccurrences(of: "{\(pathParameterName)}", with: pathValueString)
        }

        guard var urlComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw NSError(
                domain: "OpenAPIConnectorTool",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to build request URL"]
            )
        }

        let normalizedPath = resolvedPath.hasPrefix("/") ? resolvedPath : "/\(resolvedPath)"
        let basePath = urlComponents.path == "/" ? "" : urlComponents.path
        urlComponents.path = basePath + normalizedPath

        let queryParameterNames = queryParameterNames(from: operation.inputSchema)
        if !queryParameterNames.isEmpty {
            var queryItems: [URLQueryItem] = []
            for queryParameterName in queryParameterNames {
                guard let queryValue = remainingArguments.removeValue(forKey: queryParameterName) else { continue }
                let queryValueString = stringifyArgumentValue(queryValue)
                if !queryValueString.isEmpty {
                    queryItems.append(URLQueryItem(name: queryParameterName, value: queryValueString))
                }
            }
            if !queryItems.isEmpty {
                urlComponents.queryItems = queryItems
            }
        }

        guard let finalURL = urlComponents.url else {
            throw NSError(
                domain: "OpenAPIConnectorTool",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to build final request URL"]
            )
        }

        let bodyData: Data?
        if let explicitBody = remainingArguments.removeValue(forKey: "body") {
            bodyData = try JSONSerialization.data(withJSONObject: explicitBody)
        } else if !remainingArguments.isEmpty,
                  operation.httpMethod == "POST" || operation.httpMethod == "PUT" || operation.httpMethod == "PATCH" {
            bodyData = try JSONSerialization.data(withJSONObject: remainingArguments)
        } else {
            bodyData = nil
        }

        return BuiltRequestComponents(url: finalURL, bodyData: bodyData)
    }

    private func pathParameterNames(in pathTemplate: String) -> [String] {
        let pattern = #"\{([^}]+)\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(pathTemplate.startIndex..., in: pathTemplate)
        return regex.matches(in: pathTemplate, range: range).compactMap { match in
            guard let parameterRange = Range(match.range(at: 1), in: pathTemplate) else { return nil }
            return String(pathTemplate[parameterRange])
        }
    }

    private func queryParameterNames(from inputSchema: [String: Any]) -> [String] {
        guard let properties = inputSchema["properties"] as? [String: Any] else { return [] }
        let pathParameterNameSet = Set(pathParameterNames(in: operation.pathTemplate))
        return properties.keys
            .filter { !pathParameterNameSet.contains($0) && $0 != "body" }
            .sorted()
    }

    private func stringifyArgumentValue(_ value: Any) -> String {
        if let stringValue = value as? String {
            return stringValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.stringValue
        }
        if let boolValue = value as? Bool {
            return boolValue ? "true" : "false"
        }
        return String(describing: value)
    }
}
