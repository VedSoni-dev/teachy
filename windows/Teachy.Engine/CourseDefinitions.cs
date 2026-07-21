namespace Teachy.Engine;

/// <summary>One learning goal inside a course — ported from the macOS CourseLearningGoal.</summary>
public sealed class CourseLearningGoal
{
    public required string GoalIdentifier { get; init; }
    public required string Title { get; init; }

    /// <summary>What the learner should achieve, in plain words.</summary>
    public required string Goal { get; init; }

    /// <summary>The learner-voice request that seeds the tutor turn for this goal.</summary>
    public required string CoachAsk { get; init; }

    /// <summary>
    /// Natural-language completion criteria — checked by CourseVerifier vision.
    /// Null for concept goals that advance on learner confirmation (mac
    /// requireUserAdvance behavior).
    /// </summary>
    public string? DoneWhen { get; init; }

    public required string Outcome { get; init; }

    /// <summary>Soft teach-back question asked after this goal passes, when present.</summary>
    public string? TeachBackPrompt { get; init; }

    public IReadOnlyList<string> Tips { get; init; } = Array.Empty<string>();
}

/// <summary>
/// Bundled course goal sequences — ported verbatim from the macOS course
/// definitions (ClickyCourse.swift). Flagship "Build &amp; Deploy a Website" is
/// fully ported; remaining courses join as their goal data is carried over.
/// </summary>
public static class CourseDefinitions
{
    /// <summary>Goals for a course id, or null when the course runtime data isn't ported yet.</summary>
    public static IReadOnlyList<CourseLearningGoal>? GoalsForCourse(string courseIdentifier) =>
        courseIdentifier switch
        {
            "build-a-website" => BuildAWebsiteGoals,
            "code-with-ai" => CodeWithAiGoals,
            "build-a-phone-agent" => BuildAPhoneAgentGoals,
            "ai-fluency-essentials" => AiFluencyEssentialsGoals,
            _ => null,
        };

    public static readonly IReadOnlyList<CourseLearningGoal> BuildAWebsiteGoals = new[]
    {
        new CourseLearningGoal
        {
            GoalIdentifier = "plan-your-site",
            Title = "Plan your site",
            Goal = "Decide what your website is about and what content goes on it — even a rough sketch is enough.",
            CoachAsk = "Help me plan a personal website. I'm not sure where to start — what should I think about before writing any code?",
            DoneWhen = "The learner can describe in one sentence what their site is about and roughly what will be on it.",
            Outcome = "You know what your site is called, what it's about, and roughly what goes on the page.",
            TeachBackPrompt = "what is your site about, and who is it for?",
            Tips = new[]
            {
                "A personal site only needs one page to start",
                "Think: who is this for? what do they need to see?",
                "Keep it simple — you can always add more later",
            },
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "create-html-file",
            Title = "Create your first HTML file",
            Goal = "Set up a project folder and write a valid HTML file that opens in a browser.",
            CoachAsk = "Help me create my first HTML file. I have a plan for my site — now I need to set up a folder and write the code. Walk me through it.",
            DoneWhen = "A file named index.html exists in a project folder and opens in a browser showing visible content.",
            Outcome = "A file called index.html that opens in your browser and shows some text.",
            TeachBackPrompt = "what are the main parts of an HTML document and what goes in each?",
            Tips = new[]
            {
                "index.html is the standard name for a homepage",
                "You can open any .html file by double-clicking it",
                "Don't worry about making it pretty yet — just get text on screen",
            },
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "add-content",
            Title = "Add real content",
            Goal = "Fill the page with actual content — a heading, paragraphs, a link, and an image.",
            CoachAsk = "My HTML file exists but it's mostly empty. Help me add real content — a heading, some paragraphs, maybe a link and an image.",
            DoneWhen = "The page has at least a heading, a paragraph, one link, and one image (or clear placeholder).",
            Outcome = "The page has a title, some text about you or your topic, a clickable link, and an image.",
            TeachBackPrompt = "what content does your page have and why did you choose those elements?",
            Tips = new[]
            {
                "Use h1 for the main title, h2 for section headings",
                "Images need both a file and alt text",
                "Links use a tag with href",
            },
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "style-with-css",
            Title = "Style with CSS",
            Goal = "Make the page look intentional with colors, fonts, spacing, and layout.",
            CoachAsk = "My page has content but it looks like a plain document. Help me add CSS to make it look like a real website — colors, fonts, and layout.",
            DoneWhen = "The page has custom colors, fonts, spacing, and at least one layout technique (centering, flexbox, or grid).",
            Outcome = "The page has a background color, readable fonts, proper spacing, and looks designed rather than raw.",
            TeachBackPrompt = "what is the box model and how does flexbox help you layout a page?",
            Tips = new[]
            {
                "A style tag in head is the fastest way to start",
                "body with font-family: system-ui gives you a modern font for free",
                "margin: 0 auto centers content; max-width keeps it readable",
            },
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "make-it-responsive",
            Title = "Make it responsive",
            Goal = "Ensure the site looks good on phones, tablets, and desktops.",
            CoachAsk = "My site looks good on my laptop but probably breaks on a phone. Help me make it responsive so it works everywhere.",
            DoneWhen = "The site looks usable at 320px width (phone) and 1200px plus (desktop) with no horizontal scrolling.",
            Outcome = "The site adapts to different screen sizes — text is readable, nothing overflows, images scale.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "add-more-pages",
            Title = "Add more pages",
            Goal = "Create a second page and link between pages with a consistent navigation menu.",
            CoachAsk = "My one page looks great. Help me add a second page — like an About or Projects page — and link them together so visitors can navigate.",
            DoneWhen = "A second .html file exists with real content, and a nav element on both pages links between them.",
            Outcome = "At least two pages exist (e.g. index.html plus about.html) with a nav that links between them.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "push-to-github",
            Title = "Push to GitHub",
            Goal = "Initialize a Git repo and push your site to GitHub so it is backed up and ready to deploy.",
            CoachAsk = "My site is done locally. Help me put it on GitHub so it is saved online and ready to deploy.",
            DoneWhen = "A GitHub repository exists with all site files committed and pushed.",
            Outcome = "Your site code is on GitHub in a repository with all your files committed.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "deploy-to-github-pages",
            Title = "Deploy to GitHub Pages",
            Goal = "Turn your GitHub repo into a live website with a public URL anyone can visit.",
            CoachAsk = "My code is on GitHub. Help me deploy it to GitHub Pages so I can share a live link with anyone.",
            DoneWhen = "The GitHub Pages URL loads in a browser and shows the deployed site.",
            Outcome = "Your site is live at a public URL anyone can visit.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "share-your-site",
            Title = "Share your site",
            Goal = "Open your live site, verify everything works, and share the link.",
            CoachAsk = "My site is deployed! Help me open it, check that everything looks right, and grab the link so I can share it.",
            DoneWhen = "The learner has opened their live site, verified the content and navigation work, and can state their URL.",
            Outcome = "You shared a real link that anyone in the world can open.",
        },
    };

    public static readonly IReadOnlyList<CourseLearningGoal> CodeWithAiGoals = new[]
    {
        new CourseLearningGoal
        {
            GoalIdentifier = "what-a-coding-agent-does",
            Title = "What a coding agent actually does",
            Goal = "Understand that an AI coding agent writes and edits real files on disk — it is not just a chat window that suggests snippets.",
            CoachAsk = "Before I start, I want to understand what a coding agent actually does. Is it just autocomplete? Does it change my files? What's the difference from ChatGPT?",
            Outcome = "You know a coding agent writes real files — it is not just a chatbot that suggests text.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "open-a-coding-agent",
            Title = "Get a coding agent open",
            Goal = "A coding agent interface — Cursor, Claude Code in Terminal, or claude.ai as a fallback — is visible and ready to accept an instruction.",
            CoachAsk = "Help me get a coding agent open. I've heard of Cursor and Claude Code but I'm not sure what to use. What's easiest to start with right now?",
            DoneWhen = "A coding agent interface is visible on screen — either the Cursor editor, a Terminal running Claude Code, or the claude.ai chat window.",
            TeachBackPrompt = "which coding agent did you open and why?",
            Outcome = "A coding agent interface is open and waiting for your first instruction.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "craft-build-instruction",
            Title = "Craft your first build instruction",
            Goal = "Write a complete build instruction for a tiny personal web app — covering what to build, where to put it, acceptance criteria, and what not to touch.",
            CoachAsk = "Help me write a good instruction for a tiny web app — something like a tip calculator or a to-do page. I want to learn how to write instructions that actually work.",
            DoneWhen = "A typed instruction is visible in the coding agent interface or in a note on screen — it names what to build, specifies a file/folder, states how to know it worked, and notes any constraint.",
            TeachBackPrompt = "what are the four parts of a strong build instruction and why does each matter?",
            Outcome = "A complete build instruction is written — what to build, where, how to verify, and what to leave alone.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "send-instruction-and-watch",
            Title = "Let it build",
            Goal = "Send the build instruction to the coding agent and let it produce files or code — watch it work without interrupting.",
            CoachAsk = "I've written my instruction. Help me send it to the agent and watch it actually build the thing. What should I watch for?",
            DoneWhen = "The coding agent has produced at least one file or visible code output — either a diff in Cursor, a new file in the project folder, or a code block in claude.ai.",
            TeachBackPrompt = "what did the agent create and how does that compare to what you asked for?",
            Outcome = "The agent has produced files or code based on your instruction — something new exists on screen.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "explain-what-agent-did",
            Title = "Read what it did — in plain words",
            Goal = "Explain in plain English what the agent created or changed, without using code-speak — as if describing it to a friend who cannot see the screen.",
            CoachAsk = "The agent built something. I want to understand what it actually did in plain words, not in code. Can you help me read through the output?",
            DoneWhen = "The learner can describe in one or two sentences what the agent built — the feature, how it works, and roughly what files were created.",
            TeachBackPrompt = "in one sentence, what did the agent build and what can a user do with it?",
            Outcome = "You can explain what the agent built in plain words, without reading code syntax.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "iterate-one-change",
            Title = "Ask for one change",
            Goal = "Write a focused change instruction — a visible tweak like a color, label, or layout adjustment — and confirm the change appeared.",
            CoachAsk = "I want to change something in what the agent built — like the color, a label, or how something looks. Help me write a focused change request.",
            DoneWhen = "The coding agent has applied a visible change and the updated output is visible on screen — either in the browser or in the code diff.",
            TeachBackPrompt = "why should you change one thing at a time instead of sending a big list?",
            Outcome = "You made one focused change request and verified the result appeared on screen.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "paste-error-back",
            Title = "When it breaks: paste the error back",
            Goal = "When something breaks, read the first line of the error, paste it back to the agent with a short framing sentence, and let the agent fix it.",
            CoachAsk = "Something broke — or I want to learn what to do when it does. Help me understand how to read an error and what to send back to the agent to fix it.",
            DoneWhen = "Either an error has been pasted back to the agent with a framing sentence and the agent has responded with a fix, or the learner has deliberately introduced a small error, read the first error line, and sent it back.",
            TeachBackPrompt = "what is the error-reading protocol: which line do you read first and how do you frame it for the agent?",
            Outcome = "You can read an error, identify the first-line cause, and frame it for the agent in one sentence.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "the-loop-internalized",
            Title = "The loop internalized",
            Goal = "Confirm you have internalized the full instruct → verify → iterate loop by checking off its four habits.",
            CoachAsk = "I want to lock in the loop I just learned. What are the four habits I should always use with a coding agent?",
            Outcome = "The instruct → verify → iterate loop is yours. You know how to move a project forward with a coding agent.",
        },
    };

    public static readonly IReadOnlyList<CourseLearningGoal> BuildAPhoneAgentGoals = new[]
    {
        new CourseLearningGoal
        {
            GoalIdentifier = "what-is-a-phone-agent",
            Title = "What is a phone agent?",
            Goal = "Understand that a phone agent is an LLM connected to a phone number with a voice — not a recording, not an IVR, not a chatbot with a text UI.",
            CoachAsk = "Before I build anything, I want to understand what a phone agent actually is. Is it like a voicemail recording? How is it different from a regular chatbot?",
            Outcome = "You know a phone agent is a live LLM conversation over a phone call — not a pre-recorded menu.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "vapi-account-and-dashboard",
            Title = "Get into Vapi",
            Goal = "Create a Vapi account and reach the dashboard where assistants are managed.",
            CoachAsk = "Help me get into Vapi. I need an account and I want to reach the dashboard where I can create my assistant.",
            DoneWhen = "The Vapi dashboard is visible in the browser — showing either the Assistants section or a welcome screen with navigation.",
            TeachBackPrompt = "what does Vapi handle for you so you don't have to write code?",
            Outcome = "You have a Vapi account and can see the dashboard where assistants are created.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "create-vapi-assistant",
            Title = "Create an assistant",
            Goal = "Create a new assistant in the Vapi dashboard — pick a voice, a model, and give it a name.",
            CoachAsk = "I'm in the Vapi dashboard. Help me create my first assistant — I need to pick a voice and a model. Walk me through the options.",
            DoneWhen = "An assistant exists in the Vapi dashboard — it has a name, a chosen voice, and a model selected.",
            TeachBackPrompt = "what are the three things you configured when creating the assistant and why does each matter?",
            Outcome = "An assistant exists in the Vapi dashboard with a name, a voice, and a model.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "write-vapi-system-prompt",
            Title = "Write its brain: the system prompt",
            Goal = "Write a system prompt that gives the assistant a persona, describes what it should do, defines how it handles a caller, and sets a clear first message.",
            CoachAsk = "Help me write the system prompt for my assistant. I want to give it a persona and tell it what to do on a call. What makes a good voice prompt?",
            DoneWhen = "The assistant's system prompt field contains a prompt with a persona, a purpose, instructions for how to handle callers, and a first message.",
            TeachBackPrompt = "what makes a voice prompt different from a text chat prompt, and why do short sentences matter?",
            Outcome = "The assistant has a persona, a clear purpose, and a natural first message in its system prompt.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "test-call-in-vapi",
            Title = "Talk to it",
            Goal = "Initiate a test call through Vapi's in-dashboard web call feature and have a real conversation with the assistant — no phone number needed.",
            CoachAsk = "I want to actually talk to my agent. Help me find the test call feature in the Vapi dashboard and start a conversation.",
            DoneWhen = "A test conversation with the assistant has happened — the learner asked at least one question and the assistant responded with spoken audio.",
            TeachBackPrompt = "what happened on the test call — did the agent behave as you expected, and what surprised you?",
            Outcome = "You had a real back-and-forth conversation with your agent in the Vapi browser call.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "iterate-vapi-prompt",
            Title = "Iterate after hearing it",
            Goal = "Fix one thing that sounded wrong on the test call — a greeting that was too wordy, a sentence that sounded rushed, or a response that missed the point — and verify the fix on a second test call.",
            CoachAsk = "Something on the test call didn't sound right. Help me figure out what to fix in the system prompt and verify the change works.",
            DoneWhen = "The system prompt has been edited at least once and a second test call confirms the specific issue is improved.",
            TeachBackPrompt = "what did you fix and how did you verify the fix worked on the second call?",
            Outcome = "You fixed one specific issue you heard on the first call and confirmed the improvement on a second test.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "voice-agent-wrap-and-next-steps",
            Title = "What you built and where to go next",
            Goal = "Confirm what you built and what makes voice prompts unique, and check off the next-step options for making the agent production-ready.",
            CoachAsk = "I have a working agent. What makes voice prompts different from text prompts, and what are my next steps if I want to actually use this?",
            Outcome = "You have a working voice agent and a clear map of how to take it to production.",
        },
    };

    public static readonly IReadOnlyList<CourseLearningGoal> AiFluencyEssentialsGoals = new[]
    {
        new CourseLearningGoal
        {
            GoalIdentifier = "what-llms-actually-do",
            Title = "What LLMs actually do",
            Goal = "Understand that a large language model predicts likely next tokens based on patterns in training data — making it an excellent drafting partner but not a database of verified facts.",
            CoachAsk = "I keep hearing about LLMs and AI models. Before I do anything else, I want to understand what they actually do under the hood — why are they sometimes wrong?",
            Outcome = "You know LLMs predict likely text — they are not databases, and they confidently produce wrong answers when their training data was sparse or wrong.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "anatomy-of-a-strong-prompt",
            Title = "The anatomy of a strong prompt",
            Goal = "Run a weak prompt and a strong prompt for the same task in any AI chat on screen, and observe the quality difference — internalizing the four-part anatomy: context, task, format, constraints.",
            CoachAsk = "I want to learn how to write better prompts. Help me run a weak prompt and then a strong prompt for the same thing, and compare the results.",
            DoneWhen = "Two responses to the same underlying task are visible on screen — one from a weak prompt and one from a strong prompt — and the learner can describe what changed.",
            TeachBackPrompt = "what are the four parts of a strong prompt and can you give an example of each from what you just ran?",
            Outcome = "You have run a weak and a strong prompt side by side and can name the four ingredients that made the difference.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "few-shot-prompting",
            Title = "Giving examples to the model",
            Goal = "Understand that providing examples of the output you want — called few-shot prompting — is one of the highest-leverage prompt techniques.",
            CoachAsk = "I keep seeing people include examples in their prompts. What is that technique called and why does it work?",
            Outcome = "You know that giving the model one or two examples of the exact output format you want is called few-shot prompting — and why it narrows the model's output more precisely than any description.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "pick-the-right-ai-tool",
            Title = "Pick the right tool for the job",
            Goal = "Know which category of AI tool to reach for in a given situation — chat, coding agent, image generator, or voice agent — and why the wrong category wastes time.",
            CoachAsk = "There are so many AI tools now. Help me build a mental map of which one to use for what. When should I use a chat tool vs a coding agent vs an image tool?",
            Outcome = "You have a mental map of four AI tool categories and can match a task to the right tool in under five seconds.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "verify-ai-output",
            Title = "Verify like a pro",
            Goal = "Take one AI-generated answer on a factual topic and actually verify a specific claim — using a search engine or a primary source — demonstrating the habit of checking before trusting.",
            CoachAsk = "I want to practice the habit of verifying AI output. Help me take something an AI told me — or have me ask one — and check whether it's actually correct.",
            DoneWhen = "A factual claim from an AI response is visible on screen alongside the learner's verification step — a search result, a source page, or a direct check that confirms or contradicts the claim.",
            TeachBackPrompt = "what is a hallucination and how does the verification habit protect you from sharing one?",
            Outcome = "You verified a specific AI-generated factual claim against a primary source — and practiced the habit that separates informed AI users from uncritical ones.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "write-reusable-prompt",
            Title = "Make it yours: a reusable prompt",
            Goal = "Write one reusable prompt template for a task you do at least weekly — and save it in a note or document so you can paste it every time.",
            CoachAsk = "I want to build my own prompt library. Help me write one reusable prompt for something I do regularly — like summarizing emails, writing updates, or drafting messages.",
            DoneWhen = "A reusable prompt template is visible in a note, text file, or document on screen — with a placeholder like [PASTE CONTENT HERE] marking where the variable input goes.",
            TeachBackPrompt = "what task did you write a template for and what placeholder did you use for the variable input?",
            Outcome = "You have written and saved your first reusable prompt template — the start of a personal prompt library.",
        },
        new CourseLearningGoal
        {
            GoalIdentifier = "fluency-habits-checklist",
            Title = "The fluency habits",
            Goal = "Confirm the four habits that make someone AI-fluent — not just a user, but someone who gets reliable results from AI every time.",
            CoachAsk = "What are the four core habits of AI fluency? I want to check that I've got them all.",
            Outcome = "You have internalized the four fluency habits and can apply them to any AI tool you will ever encounter.",
        },
    };
}
