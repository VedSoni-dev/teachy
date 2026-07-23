# Teachy — The "I Shipped It" Loop (brick 1 of the shareable Learner Brain)

**Date:** 2026-07-22  ·  **Mode:** Startup  ·  **Stage:** Has users, none paying

## Problem

People love Teachy but it doesn't spread without the founder in the room. Every
user today is someone the founder personally talked to (or reached through his
Instagram audience). For a business whose revenue is **volume-dependent**, that is
the single biggest risk: love that doesn't compound is a workshop, not a company.

The real user, in her own words: a **45-year-old woman who works in a nail salon**,
who *made and deployed her own personal website* with Teachy. She knew she could
use Replit — but (1) she didn't know how to prompt, and (2) she *wanted to learn so
she could do it again*. Teachy didn't build it for her. Teachy was the **"AI
nephew"** who taught her how to plan, how to talk to ChatGPT, how to generate the
images, how to bring it into Cursor, and how to deploy on Vercel. She has since
come back on her own to build more sites and is now learning to make an app. That
is a learning ladder, not a one-and-done — and it's the strongest evidence in the
business.

## What I noticed (founder signals)

- **Named, real users with real artifacts** — not "healthcare enterprises," an
  actual person who shipped an actual deployed website. Interviewed her afterward.
- **Built after talking to hundreds of people.** Every claim has a real
  conversation behind it: "I don't say anything blindly."
- **Sharp counter-position, self-articulated:** "There's a difference between an AI
  that does it for you and an AI nephew who teaches you how." He named the market's
  knife at his own throat ("that's the scariest part") before being pushed on it.
- **Anticipated the trust conflict** before it was fully raised, and already has a
  principle: only route learners to products he'd stake his name on.
- **Proprietary distribution:** 50k Instagram followers who are the exact ICP and
  already DM him asking for personalized help. Teachy is the scalable version of a
  demand he personally can't keep up with.

## Evidence & open questions

**Evidence (strong):** unprompted return, expansion (website → more sites → app),
a shipped+deployed artifact, and a warm audience with pre-qualified demand.

**Riskiest unproven assumptions, in order:**
1. **Does delight compound past the founder's reach?** (learner → learner) — this
   is the #1 risk and what Approach A exists to falsify.
2. **Revenue is a story, not a signature.** "Companies are ready to pay to route
   users" and "learners were willing to pay" are both currently unfalsified. In
   talks, nothing closed.
3. **Trust vs. monetization is a permanent structural tension**, not a one-time
   decision. Good intentions are necessary but not sufficient.
4. **Platform concentration:** growth today rests on one Instagram account /
   algorithm / person.

## Premises (agreed)

1. The product is the **"AI nephew"** — a trusted *teacher* that builds durable
   skill, deliberately counter-positioned against the do-it-for-you crowd
   (Replit/Lovable/v0/Cursor Agent). Learning is the moat.
2. **The learner never pays.** Learners are the inventory, not the customer.
   Revenue = companies paying for trusted routing (Vercel-style) + B2B. Learner
   trust *is* the asset being sold.
3. **Growth is the #1 near-term risk** because revenue is volume-dependent. The
   engine is the 50k warm creator audience as beachhead; the open question is
   whether it compounds past the founder's personal reach.
4. The permanent structural risk is **trust vs. monetization**; it needs a
   *structural* guardrail that makes Teachy provably learner-first.
5. The **Learner Brain** ("MyChart for education," every skill claim backed by a
   receipt) is the structural answer to #4 — it lets Teachy take company money
   without becoming a salesman.

## Market sizing (grounded, 2025–26 data)

Teachy is not primarily in the coding-education market — it's in the
**user-acquisition layer for the AI-build ecosystem**. That ecosystem is in
hypergrowth and cash-rich:

- **AI code tools market:** ~$7.4B (2025) → ~$26–30B (2030–31), ~26% CAGR.
- **Future customers:** Cursor ~$1B ARR / ~$29B val; Replit ~$150–240M ARR / ~$9B;
  Lovable ~$200–400M ARR / ~$6.6–13B. All hypergrowth, all spending heavily on user
  acquisition (dev-tool self-serve CAC ~$50–200/user), with budgets shifting toward
  content/community/influence — Teachy's lane.
- **Programming-education market (B2B/upskilling flank):** ~$64B (2025) → ~$260B
  (2035), ~15% CAGR.

**Scenarios** (`revenue ≈ active learners × tools activated × bounty/activation`):
- **Floor (lifestyle):** ~50k–200k learners, a few partners → **~$100k–1M/yr.**
- **Base (venture-scale):** 500k–2M learners × ~1.5 × ~$30–40 → **~$20–80M/yr.**
- **Ceiling (category-defining):** the trusted front door for learning to build
  with AI + neutral acquisition layer for the whole stack; 10M+ learners →
  **~$500M–1B+/yr.**

**Why a $29B company can't just build this:** Teachy's moat is **cross-tool
neutrality + trust**. Each vendor can only sell its own tool; only a neutral party
can be the nephew who says "use Vercel here, ChatGPT there." Switzerland is the
moat — and premise 5 is what proves the neutrality is real.

## Approaches considered

- **A — The "I shipped it" loop (minimal, S):** instrument the deploy/win moment
  into a shareable, brag-worthy proof artifact ("I built & deployed this, taught by
  Teachy → link") engineered to spread on Instagram/socials. Reuses existing
  `PortfolioManager` + `NotchPortfolioTabView`. Directly falsifies the #1 risk.
- **B — The receipt as the product (ideal, L):** make the Learner Brain
  evidence-cited record public & shareable — one artifact that is the trust
  guardrail, the growth loop, AND the partner pitch. Gated on gbrain provisioning +
  local embedder (real P1 work).
- **C — Manufacture the leverage (lateral, M):** run one public time-boxed build
  challenge to the 50k, produce a spike of shipped sites + hard volume data, then
  walk into partner talks with numbers instead of a hypothesis. A moment, not a
  machine.

## Recommended approach

**A first, built explicitly as brick 1 of B.** It is the fastest falsifiable test
of the #1 agreed risk (does delight compound past the founder), it rides
infrastructure already in the codebase, and every shipped-and-shared artifact
becomes a data point to carry into the partner conversations — capturing much of
C's value without the campaign risk. B is the destination; A is how the growth
thesis earns the right to build B.

Design intent for A (not implementation — that comes later):
- The trigger is the **genuine win** (a vision `doneWhen` pass on a deploy/ship
  goal), so shares are real, not participation badges.
- The artifact must be **brag-worthy to the learner** (their site, their words,
  "I made this") and **legibly Teachy-attributed** (nephew credit + install link)
  so one delighted learner can become the next learner.
- Instrument the loop end-to-end: shares created → link clicks → installs →
  activations. Without that funnel, the test proves nothing.

## The assignment

**This week, put one human in front of the cash register and one artifact in front
of the world:**

1. **Ask the nail salon woman for money.** Not a pricing page — one message: "I'm
   thinking of charging companies like Vercel to be part of Teachy so it stays free
   for you — would you ever have paid $X for the nephew?" You already believe she'd
   say yes. Convert one belief into one data point.
2. **Get ONE of your "in talks" companies to say yes to a paid pilot** — even a
   tiny bounty per activated user. One signature beats ten warm talks.
3. **Ship the crudest possible version of the share artifact by hand** for the next
   learner who deploys — even if it's a manually-made image + link you post to your
   Instagram — and watch whether a single stranger installs from it. That one
   install (or its absence) is the first real read on your #1 risk.
```
