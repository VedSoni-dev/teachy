//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
@testable import leanring_buddy

struct leanring_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func gridCellLabelParsesToCenterPixelCoordinate() async throws {
        let coordinate = ScreenGridAnnotationUtility.screenshotPixelCoordinate(
            forCellLabel: "A1",
            screenshotWidthInPixels: 1000,
            screenshotHeightInPixels: 800
        )

        #expect(coordinate != nil)
        #expect(coordinate?.x == 25)
        #expect(abs((coordinate?.y ?? 0) - (800.0 / 12.0 / 2.0)) < 0.01)
    }

    @Test func pointingParserAcceptsGridCellTags() async throws {
        let parseResult = CompanionManager.parsePointingCoordinates(
            from: "check that button [POINT:E4:save button]"
        )

        #expect(parseResult.spokenText == "check that button")
        #expect(parseResult.gridCellLabel == "E4")
        #expect(parseResult.elementLabel == "save button")
    }

    @Test func pointingParserFindsGridTagAnywhereInResponse() async throws {
        let parseResult = CompanionManager.parsePointingCoordinates(
            from: "[POINT:D3:run button] yeah it's right there"
        )

        #expect(parseResult.gridCellLabel == "D3")
        #expect(parseResult.spokenText == "yeah it's right there")
    }

    @Test func pointingParserFallsBackToMentionedGridCell() async throws {
        let parseResult = CompanionManager.parsePointingCoordinates(
            from: "yeah that's in cell e4 on your screen"
        )

        #expect(parseResult.gridCellLabel == "E4")
    }

    @Test func drawParserAcceptsSingleCellOutline() async throws {
        let parsed = ScreenGridDrawParser.parseDrawInstruction(from: "dropbox [DRAW:M6]")

        #expect(parsed?.spokenText == "dropbox")
        #expect(parsed?.drawInstruction?.gridCellLabels == ["M6"])
    }

    @Test func drawParserAcceptsRectRange() async throws {
        let parsed = ScreenGridDrawParser.parseDrawInstruction(from: "toolbar [DRAW:rect:M6-O8]")

        #expect(parsed?.spokenText == "toolbar")
        #expect(parsed?.drawInstruction?.gridCellLabels.contains("M6") == true)
        #expect(parsed?.drawInstruction?.gridCellLabels.contains("O8") == true)
    }

    @Test func chalkOutlineRectInsetsSingleCell() async throws {
        let screenFrame = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let outlineRect = ScreenGridAnnotationUtility.chalkOutlineRectInSwiftUICoordinates(
            gridCellLabels: ["M6"],
            screenFrame: screenFrame
        )

        #expect(outlineRect != nil)
        let cellRect = ScreenGridAnnotationUtility.cellRectInSwiftUICoordinates(
            gridCellLabel: "M6",
            screenFrame: screenFrame
        )
        #expect(outlineRect!.width < cellRect!.width)
    }

    @Test func refinedOutlineKeepsListRowTight() async throws {
        let refined = ScreenGridAnnotationUtility.refinedOutlineCellLabels(
            from: ["E3", "E4"],
            anchorGridCellLabel: "E4"
        )

        let parsed = refined.compactMap { ScreenGridAnnotationUtility.parseCellLabel($0) }
        let columnSpan = (parsed.map(\.columnIndex).max() ?? 0) - (parsed.map(\.columnIndex).min() ?? 0)
        let rowSpan = (parsed.map(\.rowIndex).max() ?? 0) - (parsed.map(\.rowIndex).min() ?? 0)

        #expect(columnSpan == 3)
        #expect(rowSpan == 0)
        #expect(refined.count == 4)
    }

    @Test func mouseOutlineMapsToGridCells() async throws {
        let screenCapture = CompanionScreenCapture(
            imageData: Data(),
            label: "test",
            isCursorScreen: true,
            displayWidthInPoints: 1000,
            displayHeightInPoints: 800,
            displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            screenshotWidthInPixels: 1000,
            screenshotHeightInPixels: 800
        )

        let outlineContext = CompanionMouseOutlineContext.build(
            globalOutlinePoints: [
                CGPoint(x: 450, y: 350),
                CGPoint(x: 500, y: 400),
                CGPoint(x: 550, y: 450)
            ],
            screenCapture: screenCapture
        )

        #expect(outlineContext != nil)
        #expect(outlineContext?.touchedGridCellLabels.isEmpty == false)
    }

    @Test func backgroundAgentTriggerParsesAgentPrefix() async throws {
        let taskPrompt = VoiceBackgroundAgentTrigger.parseBackgroundAgentTask(
            from: "agent, research my competitors in private equity"
        )

        #expect(taskPrompt == "research my competitors in private equity")
    }

    @Test func backgroundAgentTriggerParsesLongerPrefixes() async throws {
        let taskPrompt = VoiceBackgroundAgentTrigger.parseBackgroundAgentTask(
            from: "hey clicky start a background agent to summarize my inbox"
        )

        #expect(taskPrompt == "to summarize my inbox")
    }

    @Test func backgroundAgentTriggerIgnoresNormalChat() async throws {
        let taskPrompt = VoiceBackgroundAgentTrigger.parseBackgroundAgentTask(
            from: "what's on my screen right now?"
        )

        #expect(taskPrompt == nil)
    }

    @Test func automationTriggerParsesBuildRequest() async throws {
        let taskPrompt = VoiceAutomationTrigger.parseAutomationTask(
            from: "build me a basic Spotify Mac app player"
        )

        #expect(taskPrompt == "build me a basic Spotify Mac app player")
    }

    @Test func automationTriggerParsesOpenTabRequest() async throws {
        let taskPrompt = VoiceAutomationTrigger.parseAutomationTask(
            from: "open a tab to github.com"
        )

        #expect(taskPrompt == "open a tab to github.com")
    }

    @Test func automationTriggerIgnoresHowToQuestions() async throws {
        let taskPrompt = VoiceAutomationTrigger.parseAutomationTask(
            from: "how do I build a Spotify Mac app player"
        )

        #expect(taskPrompt == nil)
    }

    @Test func automationTriggerIgnoresNormalChat() async throws {
        let taskPrompt = VoiceAutomationTrigger.parseAutomationTask(
            from: "what's on my screen right now?"
        )

        #expect(taskPrompt == nil)
    }

    @Test func appConnectorToolNamingPrefixesConnectorID() async throws {
        let registeredName = AppConnectorToolNaming.registeredToolName(
            connectorID: "plant-maint",
            remoteToolName: "create_work_order"
        )

        #expect(registeredName == "plant_maint__create_work_order")
    }

    @Test func appConnectorToolNamingParsesRegisteredName() async throws {
        let parsed = AppConnectorToolNaming.parseRegisteredToolName("plant_maint__list_assets")

        #expect(parsed?.connectorID == "plant_maint")
        #expect(parsed?.remoteToolName == "list_assets")
    }

    @Test func appConnectorRemoteToolDefinitionParsesToolsArray() async throws {
        let responseObject: [String: Any] = [
            "tools": [
                [
                    "name": "list_assets",
                    "description": "List plant assets",
                    "input_schema": [
                        "type": "object",
                        "properties": [:] as [String: Any]
                    ]
                ]
            ]
        ]

        let toolDefinitions = AppConnectorRemoteToolDefinition.parseList(from: responseObject)

        #expect(toolDefinitions.count == 1)
        #expect(toolDefinitions.first?.name == "list_assets")
        #expect(toolDefinitions.first?.description == "List plant assets")
    }

    @Test func openAPIConnectorParserReadsPlantMaintOperations() async throws {
        let openAPISpecURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("connectors/plant-maint/openapi.json")

        let specData = try Data(contentsOf: openAPISpecURL)
        let operations = try OpenAPIConnectorParser.parseOperations(from: specData)
        let operationIDs = Set(operations.map(\.operationID))

        #expect(operationIDs.contains("list_assets"))
        #expect(operationIDs.contains("create_work_order"))
        #expect(operationIDs.contains("update_work_order_status"))
        #expect(!operationIDs.contains("health_check"))
    }

    @Test func youtubeBasicsCourseIsBundledWithFiveGoals() async throws {
        let course = ClickyCourseCatalog.youtubeBasicsCourse

        #expect(course.id == "youtube-basics")
        #expect(course.stepCount == 5)
        #expect(course.startURL == "https://www.youtube.com")
        #expect(course.learningOutcomes.count == 5)
        #expect(course.goals.map(\.id) == [
            "youtube-open",
            "youtube-search",
            "youtube-play",
            "youtube-controls",
            "youtube-navigate",
        ])

        let searchGoal = course.goals.first { $0.id == "youtube-search" }
        #expect(searchGoal?.coachAsk.contains("search") == true)
        #expect(searchGoal?.doneWhen?.contains("Search results") == true)
        #expect(searchGoal?.goal.contains("searching") == true)
    }

    @Test func courseLessonPhaseHasDisplayLabels() async throws {
        #expect(CourseLessonPhase.yourTurn(prompt: "search").displayLabel == "your turn")
        #expect(CourseLessonPhase.checking.displayLabel == "checking…")
        #expect(CourseLessonPhase.coaching.systemImageName.isEmpty == false)
        #expect(CourseLessonPhase.yourTurn(prompt: "x").isYourTurn)
    }

    @Test func youtubeBasicsGoalsHaveNoHardcodedUIContracts() async throws {
        let course = ClickyCourseCatalog.youtubeBasicsCourse
        for goal in course.goals {
            #expect(!goal.coachAsk.isEmpty)
            #expect(!goal.goal.isEmpty)
            // Goals must stay durable — no preferred grid cells or layout jargon in the curriculum.
            #expect(!goal.coachAsk.contains("J2"))
            #expect(!goal.goal.contains("preferredGridCell"))
            #expect(!(goal.doneWhen?.contains("preferredGridCell") ?? false))
        }
    }

    @Test func youtubeBasicsCourseJSONMatchesBundledCatalog() async throws {
        let jsonURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("courses/youtube-basics.json")

        let jsonData = try Data(contentsOf: jsonURL)
        let decodedCourse = try JSONDecoder().decode(ClickyCourse.self, from: jsonData)

        #expect(decodedCourse.id == ClickyCourseCatalog.youtubeBasicsCourse.id)
        #expect(decodedCourse.stepCount == ClickyCourseCatalog.youtubeBasicsCourse.stepCount)
        #expect(decodedCourse.goals.map(\.id) == ClickyCourseCatalog.youtubeBasicsCourse.goals.map(\.id))
        #expect(decodedCourse.startURL == ClickyCourseCatalog.youtubeBasicsCourse.startURL)
    }

    @Test func khanAcademyBasicsCourseIsBundledWithFiveGoals() async throws {
        let course = ClickyCourseCatalog.khanAcademyBasicsCourse

        #expect(course.id == "khan-academy-basics")
        #expect(course.stepCount == 5)
        #expect(course.startURL == "https://www.khanacademy.org")
        #expect(course.goals.map(\.id) == [
            "khan-open",
            "khan-find-subject",
            "khan-open-lesson",
            "khan-try-practice",
            "khan-navigate",
        ])
        #expect(ClickyCourseCatalog.bundledCourses.map(\.id).contains("khan-academy-basics"))
    }

    @Test func khanAcademyBasicsCourseJSONMatchesBundledCatalog() async throws {
        let jsonURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("courses/khan-academy-basics.json")

        let jsonData = try Data(contentsOf: jsonURL)
        let decodedCourse = try JSONDecoder().decode(ClickyCourse.self, from: jsonData)

        #expect(decodedCourse.id == ClickyCourseCatalog.khanAcademyBasicsCourse.id)
        #expect(decodedCourse.goals.map(\.id) == ClickyCourseCatalog.khanAcademyBasicsCourse.goals.map(\.id))
        #expect(decodedCourse.startURL == ClickyCourseCatalog.khanAcademyBasicsCourse.startURL)
    }

    @Test func githubBasicsCourseIsBundledWithSixGoals() async throws {
        let course = ClickyCourseCatalog.githubBasicsCourse

        #expect(course.id == "github-basics")
        #expect(course.title == "Explore GitHub")
        #expect(course.stepCount == 6)
        #expect(course.startURL == "https://github.com")
        #expect(course.trackID == ClickyCourseCatalog.gitAndGitHubTrackID)
        #expect(course.trackOrder == 1)
        #expect(course.goals.map(\.id) == [
            "github-open",
            "github-find-repo",
            "github-explore-code",
            "github-find-issues",
            "github-find-pull-requests",
            "github-navigate",
        ])
        #expect(ClickyCourseCatalog.bundledCourses.map(\.id).contains("github-basics"))
    }

    @Test func gitAndGitHubTrackBuildsProgressively() async throws {
        let trackCourses = ClickyCourseCatalog.bundledCourses
            .filter { $0.trackID == ClickyCourseCatalog.gitAndGitHubTrackID }
            .sorted { ($0.trackOrder ?? 0) < ($1.trackOrder ?? 0) }

        #expect(trackCourses.map(\.id) == [
            "github-basics",
            "github-git-fundamentals",
            "github-make-a-repo",
            "github-collaborate",
        ])
        #expect(trackCourses.map(\.trackOrder) == [1, 2, 3, 4])
        #expect(ClickyCourseCatalog.githubGitFundamentalsCourse.prerequisiteCourseIDs == ["github-basics"])
        #expect(ClickyCourseCatalog.githubMakeARepoCourse.prerequisiteCourseIDs == ["github-git-fundamentals"])
        #expect(ClickyCourseCatalog.githubCollaborateCourse.prerequisiteCourseIDs == ["github-make-a-repo"])
        #expect(ClickyCourseCatalog.githubMakeARepoCourse.goals.contains { $0.id == "repo-push" })
        #expect(ClickyCourseCatalog.githubCollaborateCourse.goals.contains { $0.id == "collab-open-pr" })
    }

    @Test func githubBasicsCourseJSONMatchesBundledCatalog() async throws {
        let jsonURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("courses/github-basics.json")

        let jsonData = try Data(contentsOf: jsonURL)
        let decodedCourse = try JSONDecoder().decode(ClickyCourse.self, from: jsonData)

        #expect(decodedCourse.id == ClickyCourseCatalog.githubBasicsCourse.id)
        #expect(decodedCourse.goals.map(\.id) == ClickyCourseCatalog.githubBasicsCourse.goals.map(\.id))
        #expect(decodedCourse.startURL == ClickyCourseCatalog.githubBasicsCourse.startURL)
        #expect(decodedCourse.trackOrder == 1)
    }

    @Test func githubAdvancedCourseJSONFilesMatchBundledCatalog() async throws {
        let courseFiles = [
            ("courses/github-git-fundamentals.json", ClickyCourseCatalog.githubGitFundamentalsCourse),
            ("courses/github-make-a-repo.json", ClickyCourseCatalog.githubMakeARepoCourse),
            ("courses/github-collaborate.json", ClickyCourseCatalog.githubCollaborateCourse),
        ]

        for (relativePath, bundledCourse) in courseFiles {
            let jsonURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(relativePath)
            let decodedCourse = try JSONDecoder().decode(
                ClickyCourse.self,
                from: try Data(contentsOf: jsonURL)
            )
            #expect(decodedCourse.id == bundledCourse.id)
            #expect(decodedCourse.goals.map(\.id) == bundledCourse.goals.map(\.id))
            #expect(decodedCourse.trackID == bundledCourse.trackID)
            #expect(decodedCourse.prerequisiteCourseIDs == bundledCourse.prerequisiteCourseIDs)
        }
    }

}
