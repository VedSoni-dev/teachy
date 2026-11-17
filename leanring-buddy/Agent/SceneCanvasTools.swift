// Direct access to Teachy's own live drawing. These tools do not capture the screen,
// drive Teachy's UI, run shell commands, or recreate an existing scene.
import Foundation

final class CanvasInspectTool: BackgroundAgentTool {
    let name = "canvas_inspect"
    let description = "Inspect Teachy's live 3D canvas directly from the engine: part IDs, hierarchy, transforms, appearance, motion and camera. Always use this instead of screenshots/computer/Drive to understand Teachy's own drawing. Inspect before editing and use the returned IDs exactly. The default snapshot is a bounded page (up to 64 parts / 18,000 characters) with total count and next offset. Follow next offsets to discover every part. Pass part_ids to inspect up to 32 exact IDs directly; explicit IDs bypass pagination. Returns an explicit no-canvas result when none is live."
    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "part_ids": [
                "type": "array",
                "items": ["type": "string", "minLength": 1],
                "maxItems": 32,
                "description": "Optional exact part IDs. Omit for paginated discovery; supply up to 32 IDs to inspect their details directly, bypassing offset."
            ] as [String: Any],
            "offset": [
                "type": "integer",
                "minimum": 0,
                "description": "Zero-based part offset for paginated discovery, default 0. Use the next offset returned by the previous snapshot; ignored when part_ids are supplied."
            ] as [String: Any]
        ],
        "additionalProperties": false
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        try Task.checkCancellation()
        let ids: [String]
        if let requested = arguments["part_ids"] {
            guard let values = requested as? [String], values.count <= 32,
                  values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw CanvasToolError(message: "part_ids must be an array of up to 32 nonempty exact part ID strings.")
            }
            ids = values
        } else {
            ids = []
        }
        let offset: Int
        if let requested = arguments["offset"] {
            guard let value = requested as? Int, value >= 0,
                  !(requested is NSNumber && CFGetTypeID(requested as! NSNumber) == CFBooleanGetTypeID()) else {
                throw CanvasToolError(message: "offset must be a nonnegative integer from the previous canvas page.")
            }
            offset = value
        } else {
            offset = 0
        }
        return try await MainActor.run {
            try Task.checkCancellation()
            return SceneDirector.shared.canvasStateText(partIDs: ids, offset: offset)
        }
    }
}

final class CanvasEditTool: BackgroundAgentTool {
    let name = "canvas_edit"
    let description = "Edit Teachy's existing 3D canvas through its native command engine, without screenshots or UI clicks. First call canvas_inspect. Supply newline-separated TeachyScene commands using exact part IDs: focus ID zoom=tight; move ID by=x,y,z dur=0.3; set ID at=x,y,z rotation=x,y,z scale=x,y,z color=blue opacity=1; hide ID; show ID; frame all hold; set scene-motion bind=timescale value=0.5. Positions/rotations/scales are parent-local; rotation is in degrees. This changes existing content in place. Scene replacement, clearing and unsupported commands are rejected. Inspect the returned engine state to verify the result."
    let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "script": [
                "type": "string",
                "maxLength": 16000,
                "description": "Newline-separated native TeachyScene commands. Use only IDs from canvas_inspect; do not send shell commands, prose or Markdown fences."
            ]
        ],
        "required": ["script"],
        "additionalProperties": false
    ]

    func execute(arguments: [String: Any]) async throws -> String {
        try Task.checkCancellation()
        guard let script = arguments["script"] as? String,
              !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CanvasToolError(message: "Provide a nonempty 'script' string containing TeachyScene commands.")
        }
        guard script.utf8.count <= 16000 else {
            throw CanvasToolError(message: "Canvas script exceeds 16,000 bytes. Split it into smaller edits and inspect between them.")
        }
        return try await MainActor.run {
            try Task.checkCancellation()
            return SceneDirector.shared.applyCanvasCommands(script)
        }
    }
}

private struct CanvasToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
