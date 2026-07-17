//
//  PortfolioManager.swift
//  leanring-buddy
//
//  Persistent portfolio system that captures real artifacts from learning
//  sessions, enriches them with verification and teach-back data, and
//  makes them shareable. What you build during a lesson persists and compounds.
//

import Combine
import Foundation

// MARK: - Portfolio item

struct PortfolioItem: Codable, Identifiable, Equatable {
    let id: String
    let courseID: String
    let goalID: String
    let kind: PortfolioItemKind
    let title: String
    let description: String
    var artifactURL: String?
    let artifactContent: String?
    var verificationSummary: String?
    var teachBackSummary: String?
    let skillsUsed: [String]
    var skillLevels: [String: String]
    let verificationDepth: String?
    let qualityScore: Double?
    let createdAt: Date
    var updatedAt: Date
    let shareable: Bool

    init(
        courseID: String,
        goalID: String,
        kind: PortfolioItemKind,
        title: String,
        description: String,
        artifactURL: String? = nil,
        artifactContent: String? = nil,
        verificationSummary: String? = nil,
        teachBackSummary: String? = nil,
        skillsUsed: [String] = [],
        skillLevels: [String: String] = [:],
        verificationDepth: String? = nil,
        qualityScore: Double? = nil,
        shareable: Bool = true
    ) {
        self.id = UUID().uuidString
        self.courseID = courseID
        self.goalID = goalID
        self.kind = kind
        self.title = title
        self.description = description
        self.artifactURL = artifactURL
        self.artifactContent = artifactContent
        self.verificationSummary = verificationSummary
        self.teachBackSummary = teachBackSummary
        self.skillsUsed = skillsUsed
        self.skillLevels = skillLevels
        self.verificationDepth = verificationDepth
        self.qualityScore = qualityScore
        self.createdAt = Date()
        self.updatedAt = Date()
        self.shareable = shareable
    }
}

// MARK: - Portfolio item kind

enum PortfolioItemKind: String, Codable, CaseIterable {
    case code
    case website
    case document
    case dataAnalysis
    case prompt
    case automation
    case screenshot
    case teachingDemo
    case project

    var displayName: String {
        switch self {
        case .code: return "Code"
        case .website: return "Website"
        case .document: return "Document"
        case .dataAnalysis: return "Data Analysis"
        case .prompt: return "Prompt"
        case .automation: return "Automation"
        case .screenshot: return "Screenshot"
        case .teachingDemo: return "Teaching Demo"
        case .project: return "Project"
        }
    }

    var icon: String {
        switch self {
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .website: return "globe"
        case .document: return "doc.text"
        case .dataAnalysis: return "chart.bar"
        case .prompt: return "text.bubble"
        case .automation: return "gearshape.2"
        case .screenshot: return "camera"
        case .teachingDemo: return "person.2"
        case .project: return "hammer"
        }
    }
}

// MARK: - Portfolio summary

struct PortfolioSummary: Codable {
    let totalItems: Int
    let itemsByKind: [String: Int]
    let skillsDemonstrated: [String]
    let averageQualityScore: Double
    let totalCoursesCompleted: Int
    let recentItems: [PortfolioItem]
    let topSkills: [String]
}

// MARK: - Portfolio share card

struct PortfolioShareCard: Codable {
    let learnerName: String
    let skillName: String
    let skillLevel: String
    let verificationScore: Double
    let artifactTitle: String
    let courseTitle: String
    let earnedAt: Date
    let shareURL: String
}

// MARK: - Portfolio manager

@MainActor
final class PortfolioManager: ObservableObject {
    @Published private(set) var items: [PortfolioItem] = []
    @Published private(set) var summary: PortfolioSummary?

    private static let directoryName = "portfolio"
    private static let itemsFileName = "items.json"

    var portfolioDirectoryURL: URL {
        let baseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".teachy", isDirectory: true)
        return baseURL.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    var itemsFileURL: URL {
        portfolioDirectoryURL.appendingPathComponent(Self.itemsFileName)
    }

    init() {
        loadFromDisk()
    }

    // MARK: - Public API

    /// Create a new portfolio item from a completed goal.
    func createItem(
        courseID: String,
        goalID: String,
        kind: PortfolioItemKind,
        title: String,
        description: String,
        artifactURL: String? = nil,
        artifactContent: String? = nil,
        verificationResult: CourseVerificationResult? = nil,
        teachBackSummary: String? = nil,
        skillsUsed: [String] = [],
        skillLevels: [String: String] = [:],
        verificationDepth: String? = nil,
        qualityScore: Double? = nil
    ) -> PortfolioItem {
        let item = PortfolioItem(
            courseID: courseID,
            goalID: goalID,
            kind: kind,
            title: title,
            description: description,
            artifactURL: artifactURL,
            artifactContent: artifactContent,
            verificationSummary: verificationResult.map { result in
                "\(result.status.rawValue): \(result.whatsGood)"
            },
            teachBackSummary: teachBackSummary,
            skillsUsed: skillsUsed,
            skillLevels: skillLevels,
            verificationDepth: verificationDepth,
            qualityScore: qualityScore
        )
        items.append(item)
        saveToDisk()
        updateSummary()
        print("📋 Portfolio item created: \(item.title) (\(item.kind.displayName))")
        return item
    }

    /// Update an existing item with additional data (e.g., after teach-back).
    func enrichItem(
        withID itemID: String,
        verificationResult: CourseVerificationResult? = nil,
        teachBackSummary: String? = nil,
        artifactURL: String? = nil,
        skillLevels: [String: String]? = nil
    ) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }

        if let result = verificationResult {
            items[idx].verificationSummary = "\(result.status.rawValue): \(result.whatsGood)"
        }
        if let teachBack = teachBackSummary {
            items[idx].teachBackSummary = teachBack
        }
        if let url = artifactURL {
            items[idx].artifactURL = url
        }
        if let levels = skillLevels {
            for (key, value) in levels {
                items[idx].skillLevels[key] = value
            }
        }
        items[idx].updatedAt = Date()
        saveToDisk()
        updateSummary()
    }

    /// Get items for a specific course.
    func items(forCourseID courseID: String) -> [PortfolioItem] {
        items.filter { $0.courseID == courseID }
    }

    /// Get items that use a specific skill.
    func items(withSkill skillID: String) -> [PortfolioItem] {
        items.filter { $0.skillsUsed.contains(skillID) }
    }

    /// Get the most recent items.
    func recentItems(limit: Int = 10) -> [PortfolioItem] {
        Array(items.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    /// Get all unique skills demonstrated across the portfolio.
    func allSkillsDemonstrated() -> [String] {
        Array(Set(items.flatMap(\.skillsUsed))).sorted()
    }

    /// Generate a share card for a specific item.
    func generateShareCard(
        for item: PortfolioItem,
        learnerName: String,
        courseTitle: String
    ) -> PortfolioShareCard? {
        guard item.shareable else { return nil }

        let topSkill = item.skillsUsed.first ?? "learning"
        let skillLevel = item.skillLevels[topSkill] ?? "learned"

        return PortfolioShareCard(
            learnerName: learnerName,
            skillName: topSkill,
            skillLevel: skillLevel,
            verificationScore: item.qualityScore ?? 0.5,
            artifactTitle: item.title,
            courseTitle: courseTitle,
            earnedAt: item.createdAt,
            shareURL: "https://teachy.app/portfolio/\(item.id)"
        )
    }

    /// Generate a full portfolio export for sharing.
    func exportPortfolio(learnerName: String) -> PortfolioExport {
        PortfolioExport(
            learnerName: learnerName,
            exportedAt: Date(),
            items: items.filter(\.shareable),
            totalItems: items.count,
            skillsDemonstrated: allSkillsDemonstrated(),
            averageQualityScore: items.compactMap(\.qualityScore).reduce(0, +) / max(1, Double(items.compactMap(\.qualityScore).count))
        )
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        ensureDirectoryExists()
        guard let data = try? Data(contentsOf: itemsFileURL),
              let decoded = try? JSONDecoder().decode([PortfolioItem].self, from: data) else {
            items = []
            return
        }
        items = decoded
        updateSummary()
    }

    private func saveToDisk() {
        ensureDirectoryExists()
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: itemsFileURL, options: .atomic)
    }

    private func ensureDirectoryExists() {
        if !FileManager.default.fileExists(atPath: portfolioDirectoryURL.path) {
            try? FileManager.default.createDirectory(at: portfolioDirectoryURL, withIntermediateDirectories: true)
        }
    }

    private func updateSummary() {
        let itemsByKind = Dictionary(grouping: items, by: { $0.kind.rawValue })
            .mapValues { $0.count }
        let allSkills = allSkillsDemonstrated()
        let qualityScores = items.compactMap(\.qualityScore)
        let avgScore = qualityScores.isEmpty ? 0 : qualityScores.reduce(0, +) / Double(qualityScores.count)
        let coursesCompleted = Set(items.map(\.courseID)).count

        let skillCounts = items.flatMap(\.skillsUsed).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let topSkills = skillCounts.sorted { $0.value > $1.value }.prefix(5).map(\.key)

        summary = PortfolioSummary(
            totalItems: items.count,
            itemsByKind: itemsByKind,
            skillsDemonstrated: allSkills,
            averageQualityScore: avgScore,
            totalCoursesCompleted: coursesCompleted,
            recentItems: recentItems(limit: 5),
            topSkills: Array(topSkills)
        )
    }
}

// MARK: - Portfolio export

struct PortfolioExport: Codable {
    let learnerName: String
    let exportedAt: Date
    let items: [PortfolioItem]
    let totalItems: Int
    let skillsDemonstrated: [String]
    let averageQualityScore: Double
}
