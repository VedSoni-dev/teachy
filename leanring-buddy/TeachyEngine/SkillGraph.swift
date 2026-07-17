//
//  SkillGraph.swift
//  leanring-buddy
//
//  Connected skill nodes with prerequisites, cross-domain transfers, and
//  difficulty ratings. Powers placement, transfer detection, and the
//  visual skill tree in the portfolio view.
//

import Foundation

// MARK: - Skill graph node

struct SkillNode: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let domain: String
    let description: String
    let prerequisites: [String]
    let transfersTo: [String]
    let difficulty: Double
    let category: String

    init(
        id: String,
        name: String,
        domain: String,
        description: String,
        prerequisites: [String] = [],
        transfersTo: [String] = [],
        difficulty: Double = 0.5,
        category: String = "general"
    ) {
        self.id = id
        self.name = name
        self.domain = domain
        self.description = description
        self.prerequisites = prerequisites
        self.transfersTo = transfersTo
        self.difficulty = difficulty
        self.category = category
    }
}

// MARK: - Skill graph

struct SkillGraph: Codable, Equatable {
    var nodes: [SkillNode]

    init(nodes: [SkillNode] = []) {
        self.nodes = nodes
    }

    func node(byID id: String) -> SkillNode? {
        nodes.first { $0.id == id }
    }

    func nodes(inDomain domain: String) -> [SkillNode] {
        nodes.filter { $0.domain == domain }
    }

    func prerequisites(for skillID: String) -> [SkillNode] {
        guard let matchingNode = node(byID: skillID) else { return [] }
        return matchingNode.prerequisites.compactMap { self.node(byID: $0) }
    }

    func transfers(from skillID: String) -> [SkillNode] {
        guard let matchingNode = node(byID: skillID) else { return [] }
        return matchingNode.transfersTo.compactMap { self.node(byID: $0) }
    }

    func findTransfers(for learnedSkillID: String, in learnerModel: LearnerModel) -> [SkillTransfer] {
        guard let sourceNode = node(byID: learnedSkillID),
              let sourceSkill = learnerModel.skillNode(byID: learnedSkillID) else { return [] }

        var transfers: [SkillTransfer] = []
        for transferID in sourceNode.transfersTo {
            guard let targetNode = node(byID: transferID) else { continue }
            let existingProficiency = learnerModel.skillNode(byID: transferID)?.proficiencyLevel ?? .novice
            if existingProficiency < .competent {
                transfers.append(SkillTransfer(
                    sourceSkillID: learnedSkillID,
                    sourceSkillName: sourceSkill.skillName,
                    targetSkillID: transferID,
                    targetSkillName: targetNode.name,
                    transferDescription: "You already get \(sourceSkill.skillName) — \(targetNode.name) works the same way"
                ))
            }
        }
        return transfers
    }

    func suggestedNextSkills(for learnerModel: LearnerModel) -> [SkillNode] {
        var suggestions: [SkillNode] = []
        for node in nodes {
            let currentLevel = learnerModel.skillNode(byID: node.id)?.proficiencyLevel ?? .novice
            guard currentLevel < .competent else { continue }
            let prerequisitesMet = node.prerequisites.allSatisfy { prereqID in
                let prereqLevel = learnerModel.skillNode(byID: prereqID)?.proficiencyLevel ?? .novice
                return prereqLevel >= .competent
            }
            if prerequisitesMet {
                suggestions.append(node)
            }
        }
        return suggestions.sorted { $0.difficulty < $1.difficulty }
    }

    func placementRecommendation(for answers: [String], learnerModel: LearnerModel) -> PlacementRecommendation {
        var matchedSkills: [String] = []
        let loweredAnswers = answers.map { $0.lowercased() }

        for node in nodes {
            let nameMatch = loweredAnswers.contains { answer in
                answer.contains(node.name.lowercased())
            }
            let domainMatch = loweredAnswers.contains { answer in
                answer.contains(node.domain.lowercased())
            }
            if nameMatch || domainMatch {
                matchedSkills.append(node.id)
            }
        }

        let proficientInPrereqs: [String] = nodes.filter { node in
            node.prerequisites.allSatisfy { prereqID in
                matchedSkills.contains(prereqID)
                    || (learnerModel.skillNode(byID: prereqID)?.proficiencyLevel ?? .novice) >= .competent
            }
        }.map(\.id)

        let suggestedStart = proficientInPrereqs.first ?? nodes.first?.id
        let suggestedIndex = suggestedStart.flatMap { id in
            nodes.firstIndex(where: { $0.id == id })
        } ?? 0

        return PlacementRecommendation(
            matchedSkillIDs: matchedSkills,
            suggestedStartIndex: suggestedIndex,
            summary: matchedSkills.isEmpty
                ? "Starting from the beginning"
                : "Skipping \(matchedSkills.count) skills you already know"
        )
    }
}

// MARK: - Transfer recommendation

struct SkillTransfer: Codable, Equatable {
    let sourceSkillID: String
    let sourceSkillName: String
    let targetSkillID: String
    let targetSkillName: String
    let transferDescription: String
}

// MARK: - Placement recommendation

struct PlacementRecommendation: Codable, Equatable {
    let matchedSkillIDs: [String]
    let suggestedStartIndex: Int
    let summary: String
}

// MARK: - Bundled AI fluency skill graph

enum BundledSkillGraph {
    static let aiFluencyGraph = SkillGraph(nodes: [
        // Core AI interaction
        SkillNode(
            id: "ai-basic-interaction",
            name: "Basic AI Interaction",
            domain: "ai-fluency",
            description: "Opening an AI chat, typing a question, reading the response",
            prerequisites: [],
            difficulty: 0.1,
            category: "fundamentals"
        ),
        SkillNode(
            id: "prompt-engineering-basics",
            name: "Prompt Engineering Basics",
            domain: "ai-fluency",
            description: "Writing clear, specific prompts that get useful responses",
            prerequisites: ["ai-basic-interaction"],
            transfersTo: ["excel-formulas", "database-queries"],
            difficulty: 0.3,
            category: "fundamentals"
        ),
        SkillNode(
            id: "prompt-iteration",
            name: "Prompt Iteration",
            domain: "ai-fluency",
            description: "Refining prompts based on responses to get better results",
            prerequisites: ["prompt-engineering-basics"],
            difficulty: 0.4,
            category: "fundamentals"
        ),
        SkillNode(
            id: "output-verification",
            name: "Output Verification",
            domain: "ai-fluency",
            description: "Checking AI output for accuracy, completeness, and relevance",
            prerequisites: ["ai-basic-interaction"],
            transfersTo: ["fact-checking", "code-review"],
            difficulty: 0.35,
            category: "fundamentals"
        ),
        SkillNode(
            id: "context-window-management",
            name: "Context Management",
            domain: "ai-fluency",
            description: "Providing relevant context, managing conversation length, using system prompts",
            prerequisites: ["prompt-engineering-basics"],
            difficulty: 0.45,
            category: "fundamentals"
        ),

        // Tool-specific skills
        SkillNode(
            id: "cursor-ide-usage",
            name: "Cursor IDE",
            domain: "ai-tools",
            description: "Using Cursor's AI features for code generation and editing",
            prerequisites: ["prompt-engineering-basics"],
            transfersTo: ["copilot-usage", "claude-code-usage"],
            difficulty: 0.4,
            category: "tools"
        ),
        SkillNode(
            id: "claude-code-usage",
            name: "Claude Code",
            domain: "ai-tools",
            description: "Using Claude Code for terminal-based AI-assisted development",
            prerequisites: ["prompt-engineering-basics"],
            transfersTo: ["cursor-ide-usage"],
            difficulty: 0.45,
            category: "tools"
        ),
        SkillNode(
            id: "chatgpt-usage",
            name: "ChatGPT",
            domain: "ai-tools",
            description: "Effective use of ChatGPT for research, writing, and analysis",
            prerequisites: ["ai-basic-interaction"],
            difficulty: 0.2,
            category: "tools"
        ),
        SkillNode(
            id: "claude-usage",
            name: "Claude",
            domain: "ai-tools",
            description: "Effective use of Claude for analysis, writing, and coding",
            prerequisites: ["ai-basic-interaction"],
            difficulty: 0.2,
            category: "tools"
        ),

        // Programming with AI
        SkillNode(
            id: "ai-assisted-coding",
            name: "AI-Assisted Coding",
            domain: "programming",
            description: "Using AI to write, debug, and understand code",
            prerequisites: ["prompt-engineering-basics", "output-verification"],
            transfersTo: ["automated-testing", "documentation-writing"],
            difficulty: 0.5,
            category: "programming"
        ),
        SkillNode(
            id: "ai-debugging",
            name: "AI-Assisted Debugging",
            domain: "programming",
            description: "Using AI to find and fix bugs, understand error messages",
            prerequisites: ["ai-assisted-coding"],
            difficulty: 0.55,
            category: "programming"
        ),
        SkillNode(
            id: "code-review-with-ai",
            name: "Code Review with AI",
            domain: "programming",
            description: "Using AI to review code quality, security, and best practices",
            prerequisites: ["ai-assisted-coding", "output-verification"],
            difficulty: 0.6,
            category: "programming"
        ),

        // Writing with AI
        SkillNode(
            id: "ai-writing-assistance",
            name: "AI Writing Assistance",
            domain: "writing",
            description: "Using AI for drafting, editing, and improving written content",
            prerequisites: ["prompt-engineering-basics"],
            difficulty: 0.35,
            category: "writing"
        ),
        SkillNode(
            id: "ai-research",
            name: "AI Research",
            domain: "writing",
            description: "Using AI to gather, synthesize, and cite information",
            prerequisites: ["prompt-engineering-basics", "output-verification"],
            difficulty: 0.45,
            category: "writing"
        ),

        // Data with AI
        SkillNode(
            id: "ai-data-analysis",
            name: "AI Data Analysis",
            domain: "data",
            description: "Using AI to analyze datasets, create visualizations, find patterns",
            prerequisites: ["prompt-engineering-basics"],
            transfersTo: ["excel-formulas"],
            difficulty: 0.5,
            category: "data"
        ),

        // Cross-domain
        SkillNode(
            id: "excel-formulas",
            name: "Excel Formulas",
            domain: "productivity",
            description: "Writing and understanding Excel/Sheets formulas",
            prerequisites: [],
            transfersTo: ["prompt-engineering-basics", "database-queries"],
            difficulty: 0.3,
            category: "productivity"
        ),
        SkillNode(
            id: "database-queries",
            name: "Database Queries",
            domain: "data",
            description: "Writing SQL queries to retrieve and manipulate data",
            prerequisites: [],
            transfersTo: ["prompt-engineering-basics"],
            difficulty: 0.4,
            category: "data"
        ),
        SkillNode(
            id: "fact-checking",
            name: "Fact-Checking AI Output",
            domain: "ai-fluency",
            description: "Verifying AI claims against authoritative sources",
            prerequisites: ["output-verification"],
            difficulty: 0.4,
            category: "fundamentals"
        ),
        SkillNode(
            id: "ai-automation",
            name: "AI Automation",
            domain: "ai-fluency",
            description: "Using AI to automate repetitive tasks and workflows",
            prerequisites: ["prompt-engineering-basics", "context-window-management"],
            difficulty: 0.6,
            category: "advanced"
        ),
        SkillNode(
            id: "ai-agent-usage",
            name: "AI Agents",
            domain: "ai-fluency",
            description: "Using AI agents that can take actions, use tools, and complete multi-step tasks",
            prerequisites: ["ai-automation", "output-verification"],
            difficulty: 0.7,
            category: "advanced"
        )
    ])

    static let domains = ["ai-fluency", "ai-tools", "programming", "writing", "data", "productivity"]

    static func domainDisplayName(_ domain: String) -> String {
        switch domain {
        case "ai-fluency": return "AI Fluency"
        case "ai-tools": return "AI Tools"
        case "programming": return "Programming"
        case "writing": return "Writing"
        case "data": return "Data"
        case "productivity": return "Productivity"
        default: return domain.capitalized
        }
    }
}
