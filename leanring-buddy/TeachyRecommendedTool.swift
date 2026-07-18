//
//  TeachyRecommendedTool.swift
//  leanring-buddy
//
//  A small "go-to tool" registry. When a companion conversation or guided-task
//  title matches a known category (e.g. phone/voice agents), Teachy should always
//  route the recommendation to a specific, named tool rather than guessing generically —
//  and if the user wants to actually build one, ground the guided-task steps in real
//  knowledge about that tool instead of the model inventing UI from scratch.
//
//  This is deliberately a static Swift array, not user-editable — a test of the
//  pattern with one entry (Vapi), built so more entries can be added later without
//  touching any of the call sites below.
//

import Foundation

struct TeachyRecommendedTool {
    let id: String
    let displayName: String
    let url: String
    /// Natural-language category phrases — matched against both what the user asked
    /// and what the model titles its [GUIDE: ...] tag, so a match works whether or
    /// not the model happens to name the tool explicitly in the title.
    let triggerKeywords: [String]
    /// Conceptual grounding for the model — what the tool is, the rough shape of
    /// getting started. Vision-verification (`CourseVerifier`) is what actually keeps
    /// generated steps honest against the real screen; this just needs to be directionally
    /// right, not a pixel-exact script (same spirit as a Course goal's `doneWhen`).
    let knowledgeBrief: String
}

enum TeachyRecommendedToolRegistry {
    static let all: [TeachyRecommendedTool] = [
        TeachyRecommendedTool(
            id: "vapi",
            displayName: "Vapi",
            url: "https://vapi.ai",
            triggerKeywords: [
                "phone agent", "voice agent", "voice ai", "ai that can talk", "ai that talks to",
                "call center ai", "ai receptionist", "outbound calling", "inbound calling",
                "talk to humans", "talk to customers on the phone", "build a voice assistant"
            ],
            knowledgeBrief: """
            Vapi (vapi.ai) is a developer platform for building voice AI agents that can make and
            receive real phone calls (or run as in-browser/in-app voice assistants). The general
            shape of getting started: sign up (usually email or GitHub/Google), land in a dashboard,
            create an "Assistant" — configure its system prompt/first message, pick an LLM provider,
            a voice/TTS provider, and a transcriber — then either test it as an in-browser call or
            provision a phone number (Vapi-provided or bring-your-own via Twilio) to call it for real.
            There's usually an API keys section under account/settings for programmatic use.
            """
        )
    ]

    /// Matches against the tool's own display name first (case-insensitive substring —
    /// most reliable since the model is told to recommend it by name), then falls back
    /// to checking if any triggerKeyword phrase appears in the text (also case-insensitive
    /// substring match, kept simple since this is only the narrow deterministic side-effect
    /// path — the registry text injected into the prompt is what does most of the actual
    /// conversational recommending via the model's own semantic matching).
    static func match(forText text: String) -> TeachyRecommendedTool? {
        let lowered = text.lowercased()
        for tool in all {
            if lowered.contains(tool.displayName.lowercased()) {
                return tool
            }
        }
        for tool in all {
            if tool.triggerKeywords.contains(where: { lowered.contains($0.lowercased()) }) {
                return tool
            }
        }
        return nil
    }
}
