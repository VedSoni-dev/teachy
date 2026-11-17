import Foundation

// Test the production tool adapter without launching Teachy, touching user data,
// capturing a screen, or calling a model. Engine validation has its own tests.
protocol BackgroundAgentTool {
    var name: String { get }
    var description: String { get }
    var jsonSchema: [String: Any] { get }
    func execute(arguments: [String: Any]) async throws -> String
}

@MainActor final class SceneDirector {
    static let shared = SceneDirector()
    var scripts: [String] = []
    var inspectedIDs: [[String]] = []
    var inspectedOffsets: [Int] = []
    func canvasStateText(partIDs: [String] = [], offset: Int = 0) -> String {
        inspectedIDs.append(partIDs)
        inspectedOffsets.append(offset)
        return "live engine state: rotor at=1,2,3"
    }
    func applyCanvasCommands(_ script: String) -> String {
        scripts.append(script)
        return "updated engine state"
    }
}

@main struct CanvasToolHarness {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
            checks += 1
        }
        let inspect = CanvasInspectTool(), edit = CanvasEditTool()
        let state = try await inspect.execute(arguments: [:])
        expect(state == "live engine state: rotor at=1,2,3", "inspection reads engine API")
        expect(SceneDirector.shared.inspectedIDs == [[]], "omitted filter requests the default overview")
        _ = try await inspect.execute(arguments: ["part_ids": ["rotor", "engine.fan"]])
        expect(SceneDirector.shared.inspectedIDs.last == ["rotor", "engine.fan"], "exact part IDs pass through for detailed inspection")
        let fullBatch = (1...32).map { "part.\($0)" }
        _ = try await inspect.execute(arguments: ["part_ids": fullBatch])
        expect(SceneDirector.shared.inspectedIDs.last == fullBatch, "32 IDs are accepted")
        for requested: Any in ["rotor", [1], [" "], Array(repeating: "rotor", count: 33)] {
            do {
                _ = try await inspect.execute(arguments: ["part_ids": requested])
                fatalError("invalid inspect filter was accepted")
            } catch { expect(SceneDirector.shared.inspectedIDs.count == 3, "invalid filters never call the engine") }
        }
        _ = try await inspect.execute(arguments: ["offset": 64])
        expect(SceneDirector.shared.inspectedOffsets.last == 64 && SceneDirector.shared.inspectedIDs.last == [], "next offset pages the engine inventory")
        for invalid: Any in [-1, 1.5, true, "64"] {
            do {
                _ = try await inspect.execute(arguments: ["offset": invalid])
                fatalError("invalid offset accepted")
            } catch { expect(SceneDirector.shared.inspectedOffsets.count == 4, "invalid offset never reaches engine") }
        }
        let script = "move rotor by=1,0,0\nset rotor color=blue"
        let result = try await edit.execute(arguments: ["script": script])
        expect(result == "updated engine state" && SceneDirector.shared.scripts == [script], "edits use the direct engine API and preserve command lines")
        for arguments: [String: Any] in [[:], ["script": 12], ["script": " \n "], ["script": String(repeating: "x", count: 16001)]] {
            do {
                _ = try await edit.execute(arguments: arguments)
                fatalError("invalid script was accepted")
            } catch { expect(SceneDirector.shared.scripts.count == 1, "invalid arguments cannot change the canvas") }
        }
        let cancelled = Task { try await edit.execute(arguments: ["script": "hide rotor"]) }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("cancelled edit ran") }
        catch is CancellationError { expect(SceneDirector.shared.scripts.count == 1, "cancelled edit does not mutate engine") }
        expect(inspect.name == "canvas_inspect" && edit.name == "canvas_edit", "stable tool names")
        print("Passed \(checks) canvas tool adapter checks")
    }
}
