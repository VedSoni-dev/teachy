//
//  TeachyCoursePhoneAgent.swift
//  leanring-buddy
//
//  Bundled course: "Build a Phone Agent"
//  Teaches learners to create a voice AI that answers calls, using Vapi.ai
//  as the predetermined tool for phone and voice agent creation.
//

import Foundation

enum TeachyCoursePhoneAgent {
    static let course = ClickyCourse(
        id: "build-a-phone-agent",
        title: "Build a Phone Agent",
        subtitle: "A voice AI that answers calls for you",
        description: "Build a working voice AI assistant that can handle phone calls — without writing a single line of code. You'll have something you can actually talk to in the browser before this course ends.",
        iconSystemName: "phone.fill",
        estimatedMinutes: 35,
        startURL: "https://dashboard.vapi.ai",
        learningOutcomes: [
            "Understand what a phone agent is: an LLM wired to a phone number with a voice",
            "Navigate the Vapi dashboard and create an assistant with a chosen voice and model",
            "Write a system prompt designed for voice — short sentences, a persona, and a first message",
            "Test the agent live using Vapi's in-browser web call — no phone number required",
            "Iterate on the prompt after hearing the agent speak, fixing what sounded wrong",
            "Know what to do next: attaching a real phone number and connecting external tools",
        ],
        goals: [
            // Goal 1 — Interactive multiple-choice: what is a phone/voice agent?
            CourseLearningGoal(
                id: "what-is-a-phone-agent",
                title: "What is a phone agent?",
                goal: "Understand that a phone agent is an LLM connected to a phone number with a voice — not a recording, not an IVR, not a chatbot with a text UI.",
                coachAsk: "Before I build anything, I want to understand what a phone agent actually is. Is it like a voicemail recording? How is it different from a regular chatbot?",
                doneWhen: nil,
                artifactDelta: nil,
                remediationGoalID: nil,
                tips: nil,
                teachingContext: nil,
                toolPolicy: .pointOnly,
                outcome: "You know a phone agent is a live LLM conversation over a phone call — not a pre-recorded menu.",
                interactiveMultipleChoice: CourseInteractiveMultipleChoice(
                    question: "What makes a phone/voice agent different from a phone menu recording or a traditional IVR system?",
                    options: [
                        "It plays pre-recorded messages based on which key the caller presses",
                        "It is a live language model having an actual conversation — it understands any question and responds uniquely every time",
                        "It transcribes the call and emails you a summary afterward",
                        "It is a chatbot with a text-to-speech layer added on top",
                    ],
                    correctAnswerIndex: 1,
                    explanation: "A phone agent runs a real LLM during the call. The caller speaks naturally, the speech is transcribed in real time, the LLM generates a response, and text-to-speech speaks it back — all in under a second. It can handle any question, not just a fixed menu. Vapi handles all the real-time plumbing (telephony, STT, TTS) so you only need to write a system prompt."
                )
            ),

            // Goal 2 — Get into Vapi
            CourseLearningGoal(
                id: "vapi-account-and-dashboard",
                title: "Get into Vapi",
                goal: "Create a Vapi account and reach the dashboard where assistants are managed.",
                coachAsk: "Help me get into Vapi. I need an account and I want to reach the dashboard where I can create my assistant.",
                doneWhen: "The Vapi dashboard is visible in the browser — showing either the Assistants section or a welcome screen with navigation.",
                artifactDelta: "Vapi account created, dashboard open",
                remediationGoalID: nil,
                tips: [
                    "Vapi has a free tier — no credit card required to start",
                    "Sign in with Google is fastest if you have a Google account",
                    "The dashboard URL is dashboard.vapi.ai",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "Vapi is a voice AI platform — it handles telephony, speech-to-text, and text-to-speech so you only write the brain (system prompt)",
                        "the dashboard is where you create and manage assistants",
                        "a Vapi assistant = a voice + a model + a system prompt + optional tools",
                    ],
                    commonMistakes: [
                        "landing on vapi.ai (marketing page) instead of dashboard.vapi.ai",
                        "skipping email verification and wondering why the dashboard won't load",
                        "confusing the API keys section with the Assistants section",
                    ],
                    successExamples: [
                        "The Vapi dashboard loads with a navigation menu and an Assistants section",
                        "A 'Create Assistant' button or equivalent is visible",
                    ],
                    whyItMatters: "Vapi is the predetermined platform for this course because it has the fastest path from zero to a talking agent — account to test call in under 10 minutes.",
                    teachBackPrompt: "what does Vapi handle for you so you don't have to write code?",
                    skipTeachBack: true
                ),
                toolPolicy: .helpWhenStuck,
                outcome: "You have a Vapi account and can see the dashboard where assistants are created."
            ),

            // Goal 3 — Create an assistant
            CourseLearningGoal(
                id: "create-vapi-assistant",
                title: "Create an assistant",
                goal: "Create a new assistant in the Vapi dashboard — pick a voice, a model, and give it a name.",
                coachAsk: "I'm in the Vapi dashboard. Help me create my first assistant — I need to pick a voice and a model. Walk me through the options.",
                doneWhen: "An assistant exists in the Vapi dashboard — it has a name, a chosen voice, and a model selected.",
                artifactDelta: "Vapi assistant created with voice and model",
                remediationGoalID: "vapi-account-and-dashboard",
                tips: [
                    "Start with a 'Blank Template' so you see all the options — avoid pre-built templates for now",
                    "ElevenLabs voices sound the most natural; '11 Labs - Rachel' is a reliable default",
                    "GPT-4o or Claude as the model gives the best conversation quality",
                    "Give it a human-sounding name — it sets the tone for callers",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "voice selection: text-to-speech providers (ElevenLabs, Deepgram, Cartesia) and how voice affects caller trust",
                        "model selection: the LLM brain of the agent — determines conversation quality and cost",
                        "assistant name: not the caller-facing persona name, just the label you see in the dashboard",
                        "first message: the first thing the agent says when someone calls — the caller's first impression",
                    ],
                    commonMistakes: [
                        "picking a robotic default voice and then being put off when the test call sounds bad",
                        "leaving the first message blank — the agent will just sit in silence when a call starts",
                        "choosing a very large model for a simple use case, burning through credits faster",
                        "naming the assistant generically ('Assistant 1') and losing track when you have several",
                    ],
                    successExamples: [
                        "An assistant named 'Maya' with ElevenLabs-Rachel voice, GPT-4o model, and the first message 'Hi, I'm Maya, how can I help you today?'",
                        "The assistant card is visible in the dashboard with all three fields configured",
                    ],
                    whyItMatters: "The voice and model combination is the personality of your agent. Choosing well at setup time saves many iteration rounds later.",
                    teachBackPrompt: "what are the three things you configured when creating the assistant and why does each matter?",
                    skipTeachBack: false
                ),
                toolPolicy: .preferPointing,
                outcome: "An assistant exists in the Vapi dashboard with a name, a voice, and a model."
            ),

            // Goal 4 — Write the system prompt
            CourseLearningGoal(
                id: "write-vapi-system-prompt",
                title: "Write its brain: the system prompt",
                goal: "Write a system prompt that gives the assistant a persona, describes what it should do, defines how it handles a caller, and sets a clear first message.",
                coachAsk: "Help me write the system prompt for my assistant. I want to give it a persona and tell it what to do on a call. What makes a good voice prompt?",
                doneWhen: "The assistant's system prompt field contains a prompt with a persona, a purpose, instructions for how to handle callers, and a first message.",
                artifactDelta: "System prompt written",
                remediationGoalID: "create-vapi-assistant",
                tips: [
                    "Short sentences only — long sentences sound breathless when read aloud",
                    "Guide the caller: ask one question at a time, don't list five things at once",
                    "Handle 'um' and 'uh': tell the agent to wait a moment if the caller pauses",
                    "State the purpose in the first two lines so the agent never sounds confused about its job",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "voice prompt anatomy: persona → purpose → behavior rules → first message",
                        "short-sentence discipline: speech synthesis turns long sentences into run-ons; each idea gets its own sentence",
                        "caller guidance: always tell the agent what to ask next — silence and uncertainty lose callers",
                        "handling natural speech: 'um', pauses, and incomplete sentences are normal on calls; the prompt should acknowledge this",
                        "first message vs system prompt: the first message is what the agent says at pickup; the system prompt shapes everything after",
                    ],
                    commonMistakes: [
                        "copying a text chatbot prompt verbatim — multi-sentence bullets sound terrible when spoken aloud",
                        "not telling the agent what to do when it doesn't know the answer",
                        "forgetting to tell the agent to say goodbye and hang up gracefully",
                        "writing the persona in third person ('The assistant is helpful') instead of first person ('You are Maya')",
                        "no first message — the agent waits in silence for the caller to speak first, which feels dead",
                    ],
                    successExamples: [
                        "You are Maya, a friendly scheduling assistant for Bright Smiles Dental. Your job is to help callers book, change, or cancel appointments. Speak in short, clear sentences. Ask one question at a time. If you don't know something, say 'Let me check on that' and offer to call back.",
                        "First message: 'Hi, thanks for calling. I'm Maya. Are you calling to book an appointment, or is there something else I can help you with?'",
                    ],
                    whyItMatters: "The system prompt is the entire personality and capability of your agent. A weak prompt produces a confused, rambling agent that frustrates callers.",
                    teachBackPrompt: "what makes a voice prompt different from a text chat prompt, and why do short sentences matter?",
                    skipTeachBack: false
                ),
                toolPolicy: .pointOnly,
                outcome: "The assistant has a persona, a clear purpose, and a natural first message in its system prompt."
            ),

            // Goal 5 — Talk to it
            CourseLearningGoal(
                id: "test-call-in-vapi",
                title: "Talk to it",
                goal: "Initiate a test call through Vapi's in-dashboard web call feature and have a real conversation with the assistant — no phone number needed.",
                coachAsk: "I want to actually talk to my agent. Help me find the test call feature in the Vapi dashboard and start a conversation.",
                doneWhen: "A test conversation with the assistant has happened — the learner asked at least one question and the assistant responded with spoken audio.",
                artifactDelta: "First test call completed",
                remediationGoalID: "write-vapi-system-prompt",
                tips: [
                    "Look for a 'Test' or 'Talk' button on the assistant page — it opens a browser-based call",
                    "Allow microphone access when the browser asks",
                    "Wait for the assistant's first message before you speak — it will say it automatically",
                    "The first call might have a slight delay — that is normal on the free tier",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "Vapi's web call feature: a real call in the browser using WebRTC — same stack as a phone call, no SIM needed",
                        "the full pipeline firing in real time: your voice → STT → LLM → TTS → your speakers",
                        "latency: free tier calls can have 1-2 second delays — this is not a bug",
                        "listening to the agent as a caller: hear it the same way your future users will",
                    ],
                    commonMistakes: [
                        "forgetting to save the system prompt before starting the test call",
                        "blocking microphone access and then wondering why the agent can't hear you",
                        "speaking before the first message plays — talk after the greeting",
                        "ending the call immediately when one thing sounds off — hear at least 2-3 turns first",
                    ],
                    successExamples: [
                        "The agent greets with the first message you wrote, you ask a question, it responds naturally in the voice you chose",
                        "The conversation lasts 3-4 turns and the agent stays on-topic",
                    ],
                    whyItMatters: "Hearing your agent as a caller changes everything. You will immediately spot problems you could never see in a text editor.",
                    teachBackPrompt: "what happened on the test call — did the agent behave as you expected, and what surprised you?",
                    skipTeachBack: false
                ),
                toolPolicy: .preferPointing,
                outcome: "You had a real back-and-forth conversation with your agent in the Vapi browser call."
            ),

            // Goal 6 — Iterate after hearing it
            CourseLearningGoal(
                id: "iterate-vapi-prompt",
                title: "Iterate after hearing it",
                goal: "Fix one thing that sounded wrong on the test call — a greeting that was too wordy, a sentence that sounded rushed, or a response that missed the point — and verify the fix on a second test call.",
                coachAsk: "Something on the test call didn't sound right. Help me figure out what to fix in the system prompt and verify the change works.",
                doneWhen: "The system prompt has been edited at least once and a second test call confirms the specific issue is improved.",
                artifactDelta: "Prompt iterated and re-tested",
                remediationGoalID: "test-call-in-vapi",
                tips: [
                    "Fix ONE thing — if the greeting was too long, shorten just the greeting",
                    "Be precise: 'The sentence starting with However is too long — split it into two' beats 'make it better'",
                    "Save the prompt before starting a second test call",
                    "Compare the second call only against the specific thing you fixed — don't re-evaluate everything",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "hear → identify → fix one thing → re-test: the voice agent iteration loop",
                        "specificity in voice fixes: changing one sentence is verifiable; changing everything is noise",
                        "common quick wins: shorten the first message; add 'Only ask one question at a time'; replace long connective sentences",
                        "re-testing in isolation: start a fresh test call to hear only the thing you changed",
                    ],
                    commonMistakes: [
                        "rewriting the entire system prompt after one bad call",
                        "fixing something you cannot measure on a call (like the model's internal 'tone') before fixing the obvious structural issues",
                        "not saving between edits — the test call runs the saved version",
                        "not identifying a specific sentence or instruction to change — 'it sounds bad' is not actionable",
                    ],
                    successExamples: [
                        "The first message went from 4 sentences to 1 sentence — second test call, the greeting feels natural",
                        "Added 'Ask only one question per turn' — the agent stopped listing three questions at once",
                    ],
                    whyItMatters: "Voice prompts iterate differently from text prompts — you must hear the fix, not just read it. One focused change per call session is the professional discipline.",
                    teachBackPrompt: "what did you fix and how did you verify the fix worked on the second call?",
                    skipTeachBack: false
                ),
                toolPolicy: .pointOnly,
                outcome: "You fixed one specific issue you heard on the first call and confirmed the improvement on a second test."
            ),

            // Goal 7 — Interactive checklist + where to go next
            CourseLearningGoal(
                id: "voice-agent-wrap-and-next-steps",
                title: "What you built and where to go next",
                goal: "Confirm what you built and what makes voice prompts unique, and check off the next-step options for making the agent production-ready.",
                coachAsk: "I have a working agent. What makes voice prompts different from text prompts, and what are my next steps if I want to actually use this?",
                doneWhen: nil,
                artifactDelta: nil,
                remediationGoalID: nil,
                tips: nil,
                teachingContext: nil,
                toolPolicy: .pointOnly,
                outcome: "You have a working voice agent and a clear map of how to take it to production.",
                interactiveChecklist: CourseInteractiveChecklist(
                    prompt: "Check off what you now know — and tick the next steps you want to explore:",
                    items: [
                        "Voice prompts need short sentences — long prose sounds breathless when spoken aloud",
                        "Always set a first message — silence at call pickup feels like a dead line",
                        "Ask one question at a time — callers cannot process a list of options spoken quickly",
                        "Attach a real phone number in Vapi (Phone Numbers section) to receive actual calls",
                        "Connect tools in the Tools section to let the agent look up data or book appointments",
                        "Explore Vapi's call logs to see transcripts and improve the prompt with real caller data",
                    ]
                )
            ),
        ],
        artifact: CourseArtifactSpec(
            kind: "voiceAgent",
            icon: "phone.fill",
            initialState: "no assistant yet — just an idea for a voice AI",
            finalState: "a working voice assistant in Vapi that you can talk to in the browser",
            previewIfNoProgress: "No voice agent yet — let's build one"
        ),
        trackID: nil,
        trackTitle: nil,
        trackOrder: nil,
        prerequisiteCourseIDs: nil
    )
}
