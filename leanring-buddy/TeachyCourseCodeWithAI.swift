//
//  TeachyCourseCodeWithAI.swift
//  leanring-buddy
//
//  Bundled course: "Code with AI"
//  Teaches the instruct → verify → iterate loop for non-developers who want to
//  direct coding agents (Cursor, Claude Code, claude.ai) to build real things.
//

import Foundation

enum TeachyCourseCodeWithAI {
    static let course = ClickyCourse(
        id: "code-with-ai",
        title: "Code with AI",
        subtitle: "Direct an AI coding agent like a pro",
        description: "Non-developers bounce off coding agents because they don't know how to instruct them. This course teaches you the instruct → verify → iterate loop so you can actually ship things.",
        iconSystemName: "curlybraces",
        estimatedMinutes: 40,
        startURL: nil,
        learningOutcomes: [
            "Understand what an AI coding agent actually does (writes and edits real files, not just chatting)",
            "Craft a clear build instruction: what to build, where, acceptance criteria, and what not to touch",
            "Send an instruction and read what the agent produced in plain words",
            "Iterate on a result with a focused change request",
            "Recover from a broken build by reading the error and framing it for the agent",
            "Internalize the full instruct → verify → iterate loop as a repeatable skill",
        ],
        goals: [
            // Goal 1 — Interactive multiple-choice: what does a coding agent actually do?
            CourseLearningGoal(
                id: "what-a-coding-agent-does",
                title: "What a coding agent actually does",
                goal: "Understand that an AI coding agent writes and edits real files on disk — it is not just a chat window that suggests snippets.",
                coachAsk: "Before I start, I want to understand what a coding agent actually does. Is it just autocomplete? Does it change my files? What's the difference from ChatGPT?",
                doneWhen: nil,
                artifactDelta: nil,
                remediationGoalID: nil,
                tips: nil,
                teachingContext: nil,
                toolPolicy: .pointOnly,
                outcome: "You know a coding agent writes real files — it is not just a chatbot that suggests text.",
                interactiveMultipleChoice: CourseInteractiveMultipleChoice(
                    question: "What does an AI coding agent like Cursor or Claude Code actually do when you give it an instruction?",
                    options: [
                        "It suggests code snippets you copy and paste manually",
                        "It writes, edits, and creates real files in your project folder",
                        "It opens a web search and finds Stack Overflow answers for you",
                        "It compiles your code and runs tests automatically",
                    ],
                    correctAnswerIndex: 1,
                    explanation: "A coding agent writes and edits real files on disk — it's more like having a developer pair with you than getting autocomplete. When you give it an instruction it can create index.html, modify App.swift, run terminal commands, and show you the diff. That's what makes it powerful and also what makes clear instructions so important."
                )
            ),

            // Goal 2 — Get a coding agent open on screen
            CourseLearningGoal(
                id: "open-a-coding-agent",
                title: "Get a coding agent open",
                goal: "A coding agent interface — Cursor, Claude Code in Terminal, or claude.ai as a fallback — is visible and ready to accept an instruction.",
                coachAsk: "Help me get a coding agent open. I've heard of Cursor and Claude Code but I'm not sure what to use. What's easiest to start with right now?",
                doneWhen: "A coding agent interface is visible on screen — either the Cursor editor, a Terminal running Claude Code, or the claude.ai chat window.",
                artifactDelta: "Coding agent open and ready",
                remediationGoalID: nil,
                tips: [
                    "Cursor is a free download at cursor.com — easiest for beginners",
                    "Claude Code runs in Terminal: 'npm install -g @anthropic-ai/claude-code' then 'claude'",
                    "claude.ai in a browser works as a fallback if you just want to try the concepts",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "Cursor: a code editor with an AI agent built in — installs like any app",
                        "Claude Code: a command-line agent that works in any project folder",
                        "claude.ai: a browser chat that can write code but can't directly edit your files",
                        "all three accept the same kind of natural-language build instructions",
                    ],
                    commonMistakes: [
                        "spending too long choosing the perfect tool instead of just opening one",
                        "trying to learn the editor's keyboard shortcuts before writing any instruction",
                        "opening the wrong window (text editor vs the agent chat pane inside it)",
                    ],
                    successExamples: [
                        "Cursor is open with the Composer / Chat pane visible and a blank project",
                        "Terminal shows Claude Code's prompt waiting for input",
                    ],
                    whyItMatters: "You cannot learn to direct an agent without one open in front of you — the tool choice barely matters at this stage.",
                    teachBackPrompt: "which coding agent did you open and why?",
                    skipTeachBack: true
                ),
                toolPolicy: .helpWhenStuck,
                outcome: "A coding agent interface is open and waiting for your first instruction."
            ),

            // Goal 3 — Craft your first build instruction
            CourseLearningGoal(
                id: "craft-build-instruction",
                title: "Craft your first build instruction",
                goal: "Write a complete build instruction for a tiny personal web app — covering what to build, where to put it, acceptance criteria, and what not to touch.",
                coachAsk: "Help me write a good instruction for a tiny web app — something like a tip calculator or a to-do page. I want to learn how to write instructions that actually work.",
                doneWhen: "A typed instruction is visible in the coding agent interface or in a note on screen — it names what to build, specifies a file/folder, states how to know it worked, and notes any constraint.",
                artifactDelta: "First build instruction written",
                remediationGoalID: "open-a-coding-agent",
                tips: [
                    "Name the file and folder ('put it in a folder called tip-calc') — agents guess wrong without this",
                    "State acceptance criteria: 'the tip should update as I type the bill amount'",
                    "Say what NOT to change: 'don't touch any existing files'",
                    "Pick something tiny: a single HTML file is a perfect first project",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "anatomy of a strong instruction: what to build + where + acceptance criteria + constraints",
                        "why acceptance criteria matter — the agent needs to know when it's done",
                        "constraints prevent the agent from touching things you didn't intend",
                        "specificity collapses the agent's search space and dramatically improves output quality",
                    ],
                    commonMistakes: [
                        "writing 'make me an app' with no further detail — the agent will make arbitrary choices",
                        "no acceptance criteria — the agent ships whatever it thinks 'done' means",
                        "forgetting where to put the output so it lands in an unexpected place",
                        "over-specifying implementation ('use a div with class tipRow') instead of outcome ('show the tip amount below the input')",
                    ],
                    successExamples: [
                        "Build a single-file tip calculator in a new folder called 'tip-calc'. Put all HTML, CSS, and JS in one index.html file. The user types a bill amount and tip percentage, and the tip and total update immediately as they type. Don't create any other files.",
                        "Create a minimal to-do list in todo/index.html. The user can type a task and press Enter to add it to a list. Clicking a task marks it done with a strikethrough. No frameworks, plain JS only.",
                    ],
                    whyItMatters: "The instruction is the only thing standing between your idea and a real file. A vague instruction gets vague code.",
                    teachBackPrompt: "what are the four parts of a strong build instruction and why does each matter?",
                    skipTeachBack: false
                ),
                toolPolicy: .pointOnly,
                outcome: "A complete build instruction is written — what to build, where, how to verify, and what to leave alone."
            ),

            // Goal 4 — Let it build
            CourseLearningGoal(
                id: "send-instruction-and-watch",
                title: "Let it build",
                goal: "Send the build instruction to the coding agent and let it produce files or code — watch it work without interrupting.",
                coachAsk: "I've written my instruction. Help me send it to the agent and watch it actually build the thing. What should I watch for?",
                doneWhen: "The coding agent has produced at least one file or visible code output — either a diff in Cursor, a new file in the project folder, or a code block in claude.ai.",
                artifactDelta: "First files generated by the agent",
                remediationGoalID: "craft-build-instruction",
                tips: [
                    "Don't interrupt the agent mid-generation — let it finish before replying",
                    "Cursor's Composer shows a diff; Claude Code prints a summary of changes",
                    "A single-file HTML project usually takes under 30 seconds",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "the agent 'thinking' phase: it plans before writing, which is normal",
                        "diffs and change summaries: how agents show what they created or changed",
                        "accepting changes in Cursor vs the agent writing files directly in Claude Code",
                        "the output is a starting point — every first draft needs review",
                    ],
                    commonMistakes: [
                        "sending a follow-up message before the agent finishes",
                        "clicking Accept All without reading what was created",
                        "panicking if the output is longer than expected — scan the structure first",
                        "treating the first draft as finished",
                    ],
                    successExamples: [
                        "Cursor shows a diff panel with new HTML, CSS, and JS highlighted in green",
                        "Claude Code prints 'Created tip-calc/index.html' and a short summary",
                    ],
                    whyItMatters: "Watching the agent work builds intuition for how it interprets your instructions — you will write better ones next time.",
                    teachBackPrompt: "what did the agent create and how does that compare to what you asked for?",
                    skipTeachBack: false
                ),
                toolPolicy: .preferPointing,
                outcome: "The agent has produced files or code based on your instruction — something new exists on screen."
            ),

            // Goal 5 — Read what it did in plain words
            CourseLearningGoal(
                id: "explain-what-agent-did",
                title: "Read what it did — in plain words",
                goal: "Explain in plain English what the agent created or changed, without using code-speak — as if describing it to a friend who cannot see the screen.",
                coachAsk: "The agent built something. I want to understand what it actually did in plain words, not in code. Can you help me read through the output?",
                doneWhen: "The learner can describe in one or two sentences what the agent built — the feature, how it works, and roughly what files were created.",
                artifactDelta: nil,
                remediationGoalID: "send-instruction-and-watch",
                tips: [
                    "Ignore the actual code for now — read file names and the agent's summary",
                    "Ask: what does this do for the user? That's the plain-words version",
                    "If the agent wrote a summary message, read it aloud — that's already the plain version",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "separating what was built (behavior) from how it was built (implementation)",
                        "reading change summaries before reading code — summaries are faster",
                        "the habit of translating output to user impact before iterating",
                    ],
                    commonMistakes: [
                        "reading code line by line before understanding the overall shape of the output",
                        "skipping the review step and jumping straight to the next instruction",
                        "describing the code syntax instead of the user-facing behavior",
                    ],
                    successExamples: [
                        "'It made one HTML file with a form where I enter the bill, and it shows the tip below the inputs'",
                        "'It created three files — the HTML page, a CSS file for styling, and a JavaScript file that does the calculation'",
                    ],
                    whyItMatters: "If you cannot describe what the agent did in plain words, you cannot verify it did what you asked — and you cannot write a good follow-up instruction.",
                    teachBackPrompt: "in one sentence, what did the agent build and what can a user do with it?",
                    skipTeachBack: false
                ),
                toolPolicy: .pointOnly,
                outcome: "You can explain what the agent built in plain words, without reading code syntax."
            ),

            // Goal 6 — Ask for one change (iterate)
            CourseLearningGoal(
                id: "iterate-one-change",
                title: "Ask for one change",
                goal: "Write a focused change instruction — a visible tweak like a color, label, or layout adjustment — and confirm the change appeared.",
                coachAsk: "I want to change something in what the agent built — like the color, a label, or how something looks. Help me write a focused change request.",
                doneWhen: "The coding agent has applied a visible change and the updated output is visible on screen — either in the browser or in the code diff.",
                artifactDelta: "First iteration applied",
                remediationGoalID: "send-instruction-and-watch",
                tips: [
                    "One change at a time — asking for five things in one message leads to mixed results",
                    "Be specific about the outcome: 'make the tip amount display in bold green text' not 'make it look better'",
                    "Open the file in a browser to see the visual change",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "the iterate step: coding is always first draft → review → refine",
                        "one change per message: keeps the diff small and the result verifiable",
                        "outcome-based change requests vs code-level instructions",
                        "how to open and preview the file in a browser to verify the change",
                    ],
                    commonMistakes: [
                        "bundling multiple changes into one message — hard to spot what broke",
                        "describing a change using code terms the agent misinterprets",
                        "not opening the file in a browser after the change — visual output differs from code",
                        "accepting a change without verifying it on screen",
                    ],
                    successExamples: [
                        "'Change the background of the result box to a light blue' → the box turns blue in the browser",
                        "'Rename the button label from Submit to Calculate' → the button shows the new label",
                    ],
                    whyItMatters: "Single-focus iteration is the core professional skill. It keeps changes small, testable, and reversible.",
                    teachBackPrompt: "why should you change one thing at a time instead of sending a big list?",
                    skipTeachBack: false
                ),
                toolPolicy: .preferPointing,
                outcome: "You made one focused change request and verified the result appeared on screen."
            ),

            // Goal 7 — When it breaks: paste the error back
            CourseLearningGoal(
                id: "paste-error-back",
                title: "When it breaks: paste the error back",
                goal: "When something breaks, read the first line of the error, paste it back to the agent with a short framing sentence, and let the agent fix it.",
                coachAsk: "Something broke — or I want to learn what to do when it does. Help me understand how to read an error and what to send back to the agent to fix it.",
                doneWhen: "Either an error has been pasted back to the agent with a framing sentence and the agent has responded with a fix, or the learner has deliberately introduced a small error, read the first error line, and sent it back.",
                artifactDelta: "Error recovery demonstrated",
                remediationGoalID: "iterate-one-change",
                tips: [
                    "Read the FIRST error line — it's almost always the root cause",
                    "Frame it: 'I got this error when I [action]: [error text]' — don't just paste the error naked",
                    "If nothing broke, introduce a tiny typo in the code on purpose to practice",
                    "The agent almost always fixes a pasted error faster than any search",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "error reading protocol: first line = root cause; rest = consequences",
                        "framing the error for the agent: what you were doing + the exact error text",
                        "why pasting the raw error back works — the agent has seen thousands like it",
                        "deliberate breakage as a practice technique when nothing is broken",
                    ],
                    commonMistakes: [
                        "pasting the entire stack trace when only the first line is needed",
                        "asking 'why is it broken?' without including any error text",
                        "copying a paraphrase of the error instead of the exact text",
                        "giving up and starting over instead of pasting the error",
                    ],
                    successExamples: [
                        "'I got this error when I opened the file in Chrome: Uncaught ReferenceError: tipAmount is not defined at index.html:42' → agent finds and fixes the missing variable",
                        "Introducing a deliberate syntax error, pasting the console message, and watching the agent patch the exact line",
                    ],
                    whyItMatters: "Errors are inevitable. Knowing how to route them back to the agent — fast and precisely — is the skill that keeps projects moving instead of getting stuck.",
                    teachBackPrompt: "what is the error-reading protocol: which line do you read first and how do you frame it for the agent?",
                    skipTeachBack: false
                ),
                toolPolicy: .helpWhenStuck,
                outcome: "You can read an error, identify the first-line cause, and frame it for the agent in one sentence."
            ),

            // Goal 8 — Interactive checklist: the loop internalized
            CourseLearningGoal(
                id: "the-loop-internalized",
                title: "The loop internalized",
                goal: "Confirm you have internalized the full instruct → verify → iterate loop by checking off its four habits.",
                coachAsk: "I want to lock in the loop I just learned. What are the four habits I should always use with a coding agent?",
                doneWhen: nil,
                artifactDelta: nil,
                remediationGoalID: nil,
                tips: nil,
                teachingContext: nil,
                toolPolicy: .pointOnly,
                outcome: "The instruct → verify → iterate loop is yours. You know how to move a project forward with a coding agent.",
                interactiveChecklist: CourseInteractiveChecklist(
                    prompt: "Check off the four habits of the instruct → verify → iterate loop:",
                    items: [
                        "Clear ask with acceptance criteria — tell the agent what 'done' looks like, not just what to build",
                        "Verify on screen — open the file in a browser or read the diff before moving on",
                        "Iterate small — one focused change per message so every result is verifiable",
                        "Paste errors back — read the first line, frame it with context, send it back to the agent",
                    ]
                )
            ),
        ],
        artifact: CourseArtifactSpec(
            kind: "webApp",
            icon: "curlybraces",
            initialState: "no files yet — just an idea for a tiny web app",
            finalState: "a working web app built entirely by directing an AI coding agent",
            previewIfNoProgress: "No app yet — let's build one with a coding agent"
        ),
        trackID: nil,
        trackTitle: nil,
        trackOrder: nil,
        prerequisiteCourseIDs: nil
    )
}
