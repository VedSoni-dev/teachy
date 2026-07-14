//
//  ComposioToolkitCatalog.swift
//  Curated Composio apps for manual connection in the Agents panel.
//

import Foundation

struct ComposioToolkitOption: Identifiable, Equatable {
    let slug: String
    let name: String
    let description: String
    let logoURL: String?

    var id: String { slug }

    static func parseList(from responseObject: [String: Any]) -> [ComposioToolkitOption] {
        guard let toolkitObjects = responseObject["toolkits"] as? [[String: Any]] else {
            return []
        }

        return toolkitObjects.compactMap { toolkitObject in
            guard let slug = toolkitObject["slug"] as? String,
                  let name = toolkitObject["name"] as? String else {
                return nil
            }

            return ComposioToolkitOption(
                slug: slug,
                name: name,
                description: toolkitObject["description"] as? String ?? "",
                logoURL: toolkitObject["logo_url"] as? String
            )
        }
    }
}

enum ComposioToolkitCatalog {
    /// Popular apps shown in the manual picker before search results load.
    static let popularManualToolkits: [ComposioToolkitOption] = [
        ComposioToolkitOption(slug: "slack", name: "Slack", description: "Team messaging and channels", logoURL: nil),
        ComposioToolkitOption(slug: "gmail", name: "Gmail", description: "Email and inbox", logoURL: nil),
        ComposioToolkitOption(slug: "notion", name: "Notion", description: "Notes, docs, and wikis", logoURL: nil),
        ComposioToolkitOption(slug: "github", name: "GitHub", description: "Repos, issues, and PRs", logoURL: nil),
        ComposioToolkitOption(slug: "linear", name: "Linear", description: "Issue tracking", logoURL: nil),
        ComposioToolkitOption(slug: "jira", name: "Jira", description: "Project management", logoURL: nil),
        ComposioToolkitOption(slug: "discord", name: "Discord", description: "Community chat", logoURL: nil),
        ComposioToolkitOption(slug: "microsoft_teams", name: "Microsoft Teams", description: "Work chat and meetings", logoURL: nil),
        ComposioToolkitOption(slug: "zoom", name: "Zoom", description: "Video meetings", logoURL: nil),
        ComposioToolkitOption(slug: "figma", name: "Figma", description: "Design files", logoURL: nil),
        ComposioToolkitOption(slug: "googledrive", name: "Google Drive", description: "Files and folders", logoURL: nil),
        ComposioToolkitOption(slug: "googlecalendar", name: "Google Calendar", description: "Events and scheduling", logoURL: nil),
        ComposioToolkitOption(slug: "todoist", name: "Todoist", description: "Tasks and to-dos", logoURL: nil),
        ComposioToolkitOption(slug: "spotify", name: "Spotify", description: "Music and playlists", logoURL: nil),
    ]

    static func mergedDisplayedToolkits(
        searchResults: [ComposioToolkitOption],
        searchQuery: String
    ) -> [ComposioToolkitOption] {
        let trimmedSearchQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSearchQuery.isEmpty {
            return deduplicatedToolkits(preferred: popularManualToolkits, additional: searchResults)
        }
        if searchResults.isEmpty {
            return popularManualToolkits.filter { toolkit in
                toolkit.name.localizedCaseInsensitiveContains(trimmedSearchQuery)
                    || toolkit.slug.localizedCaseInsensitiveContains(trimmedSearchQuery)
            }
        }
        return deduplicatedToolkits(preferred: searchResults, additional: popularManualToolkits)
    }

    private static func deduplicatedToolkits(
        preferred: [ComposioToolkitOption],
        additional: [ComposioToolkitOption]
    ) -> [ComposioToolkitOption] {
        var seenSlugs = Set<String>()
        var mergedToolkits: [ComposioToolkitOption] = []

        for toolkit in preferred + additional {
            guard !seenSlugs.contains(toolkit.slug) else { continue }
            seenSlugs.insert(toolkit.slug)
            mergedToolkits.append(toolkit)
        }

        return mergedToolkits
    }
}
