//
//  OpenAPIConnectorParser.swift
//  Parses OpenAPI 3.x JSON specs into Clicky connector tool operations.
//

import Foundation

struct OpenAPIConnectorOperation {
    let operationID: String
    let description: String
    let httpMethod: String
    let pathTemplate: String
    let inputSchema: [String: Any]
}

enum OpenAPIConnectorParser {
    private static let supportedHTTPMethods = ["get", "post", "put", "patch", "delete"]
    private static let excludedPathPrefixes = ["/health", "/openapi"]

    static func parseOperations(from specData: Data) throws -> [OpenAPIConnectorOperation] {
        guard let specObject = try JSONSerialization.jsonObject(with: specData) as? [String: Any] else {
            throw NSError(
                domain: "OpenAPIConnectorParser",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAPI spec is not valid JSON"]
            )
        }

        guard let pathsObject = specObject["paths"] as? [String: Any] else {
            throw NSError(
                domain: "OpenAPIConnectorParser",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "OpenAPI spec is missing paths"]
            )
        }

        var operations: [OpenAPIConnectorOperation] = []

        for (pathTemplate, pathItemValue) in pathsObject {
            if shouldExcludePath(pathTemplate) { continue }
            guard let pathItem = pathItemValue as? [String: Any] else { continue }

            for httpMethod in supportedHTTPMethods {
                guard let operationObject = pathItem[httpMethod] as? [String: Any] else { continue }
                if operationObject["x-clicky-hidden"] as? Bool == true { continue }

                guard let operation = parseOperation(
                    pathTemplate: pathTemplate,
                    httpMethod: httpMethod,
                    operationObject: operationObject
                ) else {
                    continue
                }
                operations.append(operation)
            }
        }

        guard !operations.isEmpty else {
            throw NSError(
                domain: "OpenAPIConnectorParser",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "OpenAPI spec contains no agent-callable operations"]
            )
        }

        return operations.sorted { $0.operationID < $1.operationID }
    }

    private static func shouldExcludePath(_ pathTemplate: String) -> Bool {
        excludedPathPrefixes.contains { pathTemplate.hasPrefix($0) }
    }

    private static func parseOperation(
        pathTemplate: String,
        httpMethod: String,
        operationObject: [String: Any]
    ) -> OpenAPIConnectorOperation? {
        let generatedOperationID = "\(httpMethod)_\(pathTemplate)"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        let operationID = (operationObject["operationId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? generatedOperationID

        let summary = operationObject["summary"] as? String
        let operationDescription = operationObject["description"] as? String
        let description = [summary, operationDescription]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")

        let finalDescription = description.isEmpty ? "Call \(httpMethod.uppercased()) \(pathTemplate)" : description

        var properties: [String: Any] = [:]
        var requiredFields: [String] = []

        if let parameters = operationObject["parameters"] as? [[String: Any]] {
            for parameter in parameters {
                guard let parameterName = parameter["name"] as? String,
                      let parameterLocation = parameter["in"] as? String else {
                    continue
                }
                guard parameterLocation == "path" || parameterLocation == "query" else { continue }

                var propertySchema = parameter["schema"] as? [String: Any] ?? ["type": "string"]
                if let parameterDescription = parameter["description"] as? String {
                    propertySchema["description"] = parameterDescription
                }
                properties[parameterName] = propertySchema

                if parameter["required"] as? Bool == true {
                    requiredFields.append(parameterName)
                }
            }
        }

        if let requestBody = operationObject["requestBody"] as? [String: Any],
           let requestBodyContent = requestBody["content"] as? [String: Any],
           let jsonBody = requestBodyContent["application/json"] as? [String: Any],
           let bodySchema = jsonBody["schema"] as? [String: Any] {
            mergeSchema(bodySchema, into: &properties, requiredFields: &requiredFields)
        }

        var inputSchema: [String: Any] = [
            "type": "object",
            "properties": properties
        ]
        if !requiredFields.isEmpty {
            inputSchema["required"] = Array(Set(requiredFields)).sorted()
        }

        return OpenAPIConnectorOperation(
            operationID: operationID,
            description: finalDescription,
            httpMethod: httpMethod.uppercased(),
            pathTemplate: pathTemplate,
            inputSchema: inputSchema
        )
    }

    private static func mergeSchema(
        _ schema: [String: Any],
        into properties: inout [String: Any],
        requiredFields: inout [String]
    ) {
        if let nestedProperties = schema["properties"] as? [String: Any] {
            for (propertyName, propertyValue) in nestedProperties {
                properties[propertyName] = propertyValue
            }
            if let nestedRequired = schema["required"] as? [String] {
                requiredFields.append(contentsOf: nestedRequired)
            }
            return
        }

        properties["body"] = schema
        if schema["type"] != nil {
            requiredFields.append("body")
        }
    }
}
