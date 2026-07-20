//
//  TeachyCourseAIFluency.swift
//  leanring-buddy
//
//  Bundled course: "AI Fluency Essentials"
//  The most widget-heavy course — conceptual foundations for prompting,
//  picking the right tool, verifying AI output, and building reusable habits.
//

import Foundation

enum TeachyCourseAIFluency {
    static let course = ClickyCourse(
        id: "ai-fluency-essentials",
        title: "AI Fluency Essentials",
        subtitle: "Prompt, pick tools, and trust — the core skills",
        description: "The mental models behind getting reliable results from AI — not tricks, but durable habits that apply to every tool you will ever use.",
        iconSystemName: "brain.head.profile",
        estimatedMinutes: 25,
        startURL: nil,
        learningOutcomes: [
            "Understand what LLMs actually do — and why they are great drafting partners but not truth machines",
            "Write strong prompts using the context → task → format → constraints anatomy",
            "Understand few-shot prompting and when to use it",
            "Pick the right AI tool for the job — chat, coding agent, image tool, or voice agent",
            "Verify AI output on factual claims like a pro",
            "Build a reusable personal prompt library for weekly tasks",
        ],
        goals: [
            // Goal 1 — Interactive multiple-choice: what do LLMs actually do?
            CourseLearningGoal(
                id: "what-llms-actually-do",
                title: "What LLMs actually do",
                goal: "Understand that a large language model predicts likely next tokens based on patterns in training data — making it an excellent drafting partner but not a database of verified facts.",
                coachAsk: "I keep hearing about LLMs and AI models. Before I do anything else, I want to understand what they actually do under the hood — why are they sometimes wrong?",
                doneWhen: nil,
                artifactDelta: nil,
                remediationGoalID: nil,
                tips: nil,
                teachingContext: nil,
                toolPolicy: .pointOnly,
                outcome: "You know LLMs predict likely text — they are not databases, and they confidently produce wrong answers when their training data was sparse or wrong.",
                interactiveMultipleChoice: CourseInteractiveMultipleChoice(
                    question: "What is a large language model (like Claude or GPT-4) actually doing when it responds to you?",
                    options: [
                        "Searching the internet in real time and summarizing what it finds",
                        "Looking up the correct answer in a curated database of verified facts",
                        "Predicting the most likely continuation of your text based on patterns in its training data",
                        "Running a set of if-then rules written by the company's engineers",
                    ],
                    correctAnswerIndex: 2,
                    explanation: "LLMs predict likely next text — they are pattern-matching engines trained on enormous amounts of text. This makes them brilliant at drafting, summarizing, brainstorming, and writing code. But because they are predicting likelihood rather than retrieving truth, they can confidently generate wrong dates, fake citations, and plausible-sounding errors. Knowing this shapes how you use them: great partner for drafts, never the final word on facts."
                )
            ),

            // Goal 2 — The anatomy of a strong prompt
            CourseLearningGoal(
                id: "anatomy-of-a-strong-prompt",
                title: "The anatomy of a strong prompt",
                goal: "Run a weak prompt and a strong prompt for the same task in any AI chat on screen, and observe the quality difference — internalizing the four-part anatomy: context, task, format, constraints.",
                coachAsk: "I want to learn how to write better prompts. Help me run a weak prompt and then a strong prompt for the same thing, and compare the results.",
                doneWhen: "Two responses to the same underlying task are visible on screen — one from a weak prompt and one from a strong prompt — and the learner can describe what changed.",
                artifactDelta: nil,
                remediationGoalID: nil,
                tips: [
                    "Weak: 'Write me an email' — Strong: 'Write a two-sentence follow-up email from a freelance designer to a client who saw a proposal last week, keeping a warm but professional tone'",
                    "Context is what the AI doesn't know yet — your role, the audience, the situation",
                    "Format means you say exactly what shape the output should take: bullet list, email, one sentence, JSON",
                    "Constraints keep the output from going off-script: 'no jargon', 'under 50 words', 'don't suggest a refund'",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "context: what the AI doesn't already know — your role, the situation, the audience",
                        "task: the specific thing you want the AI to produce, stated as an action",
                        "format: the shape of the output — bullet list, paragraph, code block, numbered steps",
                        "constraints: what to avoid, length limits, tone, what not to include",
                        "why specificity helps: the model's search space shrinks dramatically with each constraint",
                    ],
                    commonMistakes: [
                        "one-word or one-sentence prompts with no context — 'summarize this' without saying what kind of summary or for whom",
                        "asking for too many things in one prompt — split multi-task requests into sequential turns",
                        "not stating the format — the AI picks one, and it's often wrong for the use case",
                        "treating the first response as final — strong prompting includes one iteration turn",
                    ],
                    successExamples: [
                        "'You are a hiring manager at a startup. Write a 3-bullet rejection email to a candidate who interviewed for a senior engineer role. Be kind and specific. Under 80 words.'",
                        "'Summarize the following article in one sentence for a non-technical audience. No jargon.'",
                    ],
                    whyItMatters: "A strong prompt is the difference between a usable first draft and three rounds of back-and-forth corrections. Context + task + format + constraints is the formula professionals use every day.",
                    teachBackPrompt: "what are the four parts of a strong prompt and can you give an example of each from what you just ran?",
                    skipTeachBack: false
                ),
                toolPolicy: .preferPointing,
                outcome: "You have run a weak and a strong prompt side by side and can name the four ingredients that made the difference."
            ),

            // Goal 3 — Interactive fill-in-blank: few-shot prompting
            CourseLearningGoal(
                id: "few-shot-prompting",
                title: "Giving examples to the model",
                goal: "Understand that providing examples of the output you want — called few-shot prompting — is one of the highest-leverage prompt techniques.",
                coachAsk: "I keep seeing people include examples in their prompts. What is that technique called and why does it work?",
                doneWhen: nil,
                artifactDelta: nil,
                remediationGoalID: nil,
                tips: nil,
                teachingContext: nil,
                toolPolicy: .pointOnly,
                outcome: "You know that giving the model one or two examples of the exact output format you want is called few-shot prompting — and why it narrows the model's output more precisely than any description.",
                interactiveFillInBlank: CourseInteractiveFillInBlank(
                    prompt: "Giving the AI one or two examples of the exact output you want is called _____-shot prompting.",
                    acceptableAnswers: [
                        "few",
                        "few shot",
                        "few-shot",
                        "few shot prompting",
                        "few-shot prompting",
                    ],
                    explanation: "Few-shot prompting means including one or more examples of the output format you want directly in your prompt. For example: 'Convert each item to a one-line tweet. Example: Input: Our app launched today. Output: We shipped. 🚀 Now do this one: ...' The model pattern-matches against your example far more precisely than against a description. Zero-shot is no example; one-shot is one example; few-shot is two or more."
                )
            ),

            // Goal 4 — Pick the right tool for the job (multiple-choice)
            CourseLearningGoal(
                id: "pick-the-right-ai-tool",
                title: "Pick the right tool for the job",
                goal: "Know which category of AI tool to reach for in a given situation — chat, coding agent, image generator, or voice agent — and why the wrong category wastes time.",
                coachAsk: "There are so many AI tools now. Help me build a mental map of which one to use for what. When should I use a chat tool vs a coding agent vs an image tool?",
                doneWhen: nil,
                artifactDelta: nil,
                remediationGoalID: nil,
                tips: nil,
                teachingContext: nil,
                toolPolicy: .pointOnly,
                outcome: "You have a mental map of four AI tool categories and can match a task to the right tool in under five seconds.",
                interactiveMultipleChoice: CourseInteractiveMultipleChoice(
                    question: "You need to build a working to-do list web app with a database. Which category of AI tool is the right first reach?",
                    options: [
                        "A chat tool like Claude or ChatGPT",
                        "An AI coding agent like Cursor or Claude Code",
                        "An AI image generator like Midjourney",
                        "A voice agent builder like Vapi",
                    ],
                    correctAnswerIndex: 1,
                    explanation: "A coding agent is the right tool when you need actual files built on disk — HTML, JavaScript, a database schema. A chat tool is excellent for thinking through the architecture, writing copy, or debugging a specific error, but it cannot create and edit files in your project folder the way a coding agent can. Image generators make visuals, not code. Voice agents handle phone calls. Right tool, right job — every time."
                )
            ),

            // Goal 5 — Verify like a pro
            CourseLearningGoal(
                id: "verify-ai-output",
                title: "Verify like a pro",
                goal: "Take one AI-generated answer on a factual topic and actually verify a specific claim — using a search engine or a primary source — demonstrating the habit of checking before trusting.",
                coachAsk: "I want to practice the habit of verifying AI output. Help me take something an AI told me — or have me ask one — and check whether it's actually correct.",
                doneWhen: "A factual claim from an AI response is visible on screen alongside the learner's verification step — a search result, a source page, or a direct check that confirms or contradicts the claim.",
                artifactDelta: nil,
                remediationGoalID: "anatomy-of-a-strong-prompt",
                tips: [
                    "Ask the AI a question with a specific verifiable fact: a date, a statistic, a company name",
                    "Search the claim in a separate tab — source it to a primary page, not just another article summarizing AI output",
                    "If the claim is wrong, note that it was confident and specific — this is why you always verify",
                    "Good domains to test: recent events, specific statistics, academic citations",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "hallucinations: when an LLM generates plausible but false facts with full confidence",
                        "the verification habit: treat every AI-generated factual claim as 'unverified until checked'",
                        "primary sources vs secondary summaries: a primary source is more reliable than another AI-adjacent article",
                        "the confidence-accuracy gap: LLMs often sound most confident on topics where their training data was thinnest",
                    ],
                    commonMistakes: [
                        "using an AI tool to verify another AI tool's claim — the second model was trained on similar data",
                        "only verifying the claims that 'seem off' — the confident-sounding ones are often wrong too",
                        "treating a citation as proof — LLMs fabricate citations; check that the paper/article actually exists",
                        "stopping at a Google snippet summary instead of clicking through to the source",
                    ],
                    successExamples: [
                        "AI says the Eiffel Tower is 324 meters tall. Wikipedia says 330 meters including the broadcast antenna. The AI was citing the structural height only — a real distinction, but easy to misread.",
                        "AI cites a 2021 paper by a specific author. Searching the title finds no such paper. Classic hallucinated citation.",
                    ],
                    whyItMatters: "AI output used in decisions, published work, or shared with others carries your credibility. Verification is not paranoia — it is professionalism.",
                    teachBackPrompt: "what is a hallucination and how does the verification habit protect you from sharing one?",
                    skipTeachBack: false
                ),
                toolPolicy: .pointOnly,
                outcome: "You verified a specific AI-generated factual claim against a primary source — and practiced the habit that separates informed AI users from uncritical ones."
            ),

            // Goal 6 — Make it yours: write a reusable prompt
            CourseLearningGoal(
                id: "write-reusable-prompt",
                title: "Make it yours: a reusable prompt",
                goal: "Write one reusable prompt template for a task you do at least weekly — and save it in a note or document so you can paste it every time.",
                coachAsk: "I want to build my own prompt library. Help me write one reusable prompt for something I do regularly — like summarizing emails, writing updates, or drafting messages.",
                doneWhen: "A reusable prompt template is visible in a note, text file, or document on screen — with a placeholder like [PASTE CONTENT HERE] marking where the variable input goes.",
                artifactDelta: "First prompt in personal library",
                remediationGoalID: "anatomy-of-a-strong-prompt",
                tips: [
                    "Think of tasks you repeat every week where you always want the same format",
                    "Put [PASTE HERE] or [CONTENT] in the prompt where your actual input will go",
                    "Name the note something like 'My Prompts' — you will add more over time",
                    "The best prompts encode your personal style: 'Match my writing style: direct, no filler words'",
                ],
                teachingContext: CourseTeachingContext(
                    concepts: [
                        "prompt templates: prompts with placeholder markers for variable content",
                        "the weekly-task test: if you do something more than once, a template pays for itself immediately",
                        "encoding personal style in a prompt: explicit style instructions give consistent tone across all outputs",
                        "where to keep prompts: a text file, Notion page, Apple Notes — anywhere you can paste from quickly",
                    ],
                    commonMistakes: [
                        "writing a one-off prompt for a recurring task and never saving it",
                        "making the template too rigid — leave enough flexibility for the variable part to change",
                        "not naming or organizing prompts — a pile of unlabeled prompts is as useful as no prompts",
                        "writing the template in a chat window and losing it when the session closes",
                    ],
                    successExamples: [
                        "A 'Weekly Update' template: 'Summarize the following bullet points as a concise Monday update email for a non-technical manager. 3 sentences max. Start with the biggest win. [PASTE UPDATES HERE]'",
                        "A 'Slack Reply' template: 'Write a direct, friendly reply to the following Slack message. No filler phrases like 'Great question'. [PASTE MESSAGE HERE]'",
                    ],
                    whyItMatters: "A saved prompt is compounding leverage. You write it once and it saves time every time you use it — for months or years.",
                    teachBackPrompt: "what task did you write a template for and what placeholder did you use for the variable input?",
                    skipTeachBack: false
                ),
                toolPolicy: .pointOnly,
                outcome: "You have written and saved your first reusable prompt template — the start of a personal prompt library."
            ),

            // Goal 7 — Interactive checklist: the fluency habits
            CourseLearningGoal(
                id: "fluency-habits-checklist",
                title: "The fluency habits",
                goal: "Confirm the four habits that make someone AI-fluent — not just a user, but someone who gets reliable results from AI every time.",
                coachAsk: "What are the four core habits of AI fluency? I want to check that I've got them all.",
                doneWhen: nil,
                artifactDelta: nil,
                remediationGoalID: nil,
                tips: nil,
                teachingContext: nil,
                toolPolicy: .pointOnly,
                outcome: "You have internalized the four fluency habits and can apply them to any AI tool you will ever encounter.",
                interactiveChecklist: CourseInteractiveChecklist(
                    prompt: "Check off the four habits that define AI fluency:",
                    items: [
                        "Context first — give the AI your role, the audience, and the situation before asking it to do anything",
                        "Right tool — match the task to the tool category: chat for thinking, coding agent for building, image tools for visuals, voice agents for calls",
                        "Verify claims — every factual claim from an AI is unverified until you check a primary source",
                        "Iterate, don't settle — the first response is a draft; one focused follow-up almost always makes it significantly better",
                    ]
                )
            ),
        ],
        artifact: nil,
        trackID: nil,
        trackTitle: nil,
        trackOrder: nil,
        prerequisiteCourseIDs: nil
    )
}
