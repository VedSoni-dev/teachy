import Combine
import Foundation

nonisolated struct AgentProject: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
}

/// Personal workspaces. Membership is a stable ID independent of a coding job's disk access.
@MainActor
final class AgentProjectStore: ObservableObject {
    private struct Catalog: Codable {
        var projects: [AgentProject] = []
        var activeProjectID: String?
    }

    struct Problem: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Published private var catalog = Catalog()
    private let file: URL
    private(set) var loadProblem: String?
    var projects: [AgentProject] { catalog.projects }
    var activeProjectID: String? { catalog.activeProjectID }

    init(file: URL) {
        self.file = file
        do {
            let data = try Data(contentsOf: file)
            catalog = try JSONDecoder().decode(Catalog.self, from: data)
            if let id = catalog.activeProjectID, !projects.contains(where: { $0.id == id }) {
                catalog.activeProjectID = nil
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A fresh installation starts in All projects.
        } catch {
            loadProblem = "Couldn’t read your projects. " + error.localizedDescription
        }
    }

    @discardableResult
    func create(name: String) throws -> AgentProject {
        let project = try AgentProject(id: UUID().uuidString, name: validated(name))
        var next = catalog
        next.projects.append(project)
        next.activeProjectID = project.id
        try commit(next)
        return project
    }

    func rename(id: String, name: String) throws {
        var next = catalog
        guard let index = next.projects.firstIndex(where: { $0.id == id }) else {
            throw Problem(message: "This project no longer exists.")
        }
        next.projects[index].name = try validated(name, except: id)
        try commit(next)
    }

    func select(_ id: String?) throws {
        guard id == nil || catalog.projects.contains(where: { $0.id == id }) else {
            throw Problem(message: "This project no longer exists.")
        }
        var next = catalog
        next.activeProjectID = id
        try commit(next)
    }

    private func validated(_ input: String, except id: String? = nil) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Problem(message: "Enter a name for your project.") }
        guard name.count <= 100 else { throw Problem(message: "Use a project name of 100 characters or fewer.") }
        guard !catalog.projects.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw Problem(message: "A project with that name already exists.")
        }
        return name
    }

    private func commit(_ next: Catalog) throws {
        if let loadProblem { throw Problem(message: loadProblem) }
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        catalog = next
    }
}
