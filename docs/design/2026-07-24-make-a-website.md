# Make a Website — flagship course

**Date:** 2026-07-24  ·  **Mode:** Builder  ·  **Status:** Implemented (v1 course live in catalog)

Interactive tree: `~/.cursor/projects/Users-ved-soni-clicky/canvases/website-course-decision-tree.canvas.tsx`

## Problem

People want a real site online, but they stall on blank prompts (“make me a portfolio”) and tooling busywork (finding links, picking hosts, not knowing Replit vs Cursor). Teachy’s wedge: run the interview they skip, paste a great prompt, open the tools, get them to a live URL.

## What I noticed

- Founder taste is clear: **doing > navigating**. Teachy opens ChatGPT / Replit / Vercel; learner decides and reacts.
- Core insight locked: **Teachy is the active prompter** — asks context questions, writes the perfect first prompt, pastes it. Normies learn good prompting by feeling it work, not by a lecture.
- Hosting choice flipped from GitHub Pages → **Vercel**.
- Build forks: vibe (Replit) vs coding agent, routed by what they already pay for.

## Evidence & open questions

- Free ChatGPT image gens: ~2–3 / rolling 24h (not officially fixed). Course must budget gens (landing first).
- Still unproven in the wild: does the interview → paste loop feel magical or interrogative? Need one real learner sit-through.
- Codex free-tier URL / product surface may shift — verify at ship time.

## Premises (agreed)

1. Shared trophy: a **live Vercel URL** they can text someone.
2. First major beat is **plan in ChatGPT**, not HTML theory.
3. Teachy **asks → writes prompt → opens ChatGPT → pastes**.
4. After “plan is good,” generate **landing mock image** first; more pages only if image quota allows.
5. Build path: **Replit** if vibe; else ask paid ChatGPT / Claude / Cursor → route agent; if unpaid → **Codex free**; if willing to pay → **Claude Code**.
6. Custom domain is **after** `*.vercel.app`, never blocking.
7. One legendary path — not a catalog of weak courses.

## Approaches considered

| Approach | Summary | Effort | Why not / why |
|----------|---------|--------|----------------|
| A. Linear HTML→CSS→GitHub Pages | Classic tutorial railroad | S | Rejected — wrong host, no prompt skill, ignores starting points |
| B. Interview → ChatGPT plan → mocks → Replit/agent → Vercel | Branched on-ramps, Teachy does chrome | M | **Chosen** |
| C. Full multi-track academy (job vs hustle vs school as separate courses) | Cleaner marketing | L | Too early — one path with intake forks is enough |

## Recommended approach

**B.** Happy path:

0. **Intake** — goal, what they have, Replit vs agent (+ paid AI if agent)
1. **Plan** — Teachy interviews → perfect prompt → open + paste into ChatGPT → iterate until learner says plan is good
2. **Mocks** — ChatGPT image gen for landing (+ 1–2 pages if free quota left; skip if they already have Figma/Canva)
3. **Build** — open Replit or recommended agent; paste plan + mock refs
4. **Ship** — open Vercel; get live URL; optional domain later

Agent routing:

| Already pay? | Go here |
|--------------|---------|
| Cursor | Cursor |
| Claude | Claude Code |
| ChatGPT | Stay OpenAI / Codex |
| Nothing | Codex beginner free tier |
| Willing to pay | Claude Code |
| Vibe tool | Replit (skip paid quiz) |

## Course authoring notes (when we implement)

- Encode intake + phases as goals with `doneWhen` that match real screen state (ChatGPT thread, mock image, Replit preview, Vercel URL).
- Prefer `toolPolicy` that lets Teachy **open URLs and paste** early; tighten only when they need to type their own content.
- Keep goal IDs stable once shipped.
- Mirror JSON in `courses/build-a-website.json` + bundled Swift catalog.

## The assignment

**Before writing course JSON:** sit with one real person (or record yourself cold) and run only Phase 0–1 out loud — ask the planning questions, write the prompt by hand, paste into ChatGPT. Note where the interview felt too long or too thin. Bring that back, then we author goals.
