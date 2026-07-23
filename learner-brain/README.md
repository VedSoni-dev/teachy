# Teachy Learner Brain — "MyChart for education"

Teachy's current learner memory is a single JSON blob (`LearnerModel` →
`~/.teachy/engine-state.json`). It stores *conclusions* ("knows X, confused by
Y") and overwrites itself. That is a scratchpad, not a record.

This directory replaces that with a **longitudinal, evidence-cited learner
record** built on [gbrain](https://github.com/garrytan/gbrain) — Garry Tan's
Postgres-native personal-knowledge engine — reshaped for one job: remembering
how a single human is actually learning.

**Teachy is the interface. gbrain is how we store learning.**

This is also **Approach B** in `docs/design/2026-07-22-shipped-it-loop.md`: the
receipt as the product. The shareable proof page (`shipped-it-receipt.html`,
Approach A / brick 1) renders the record this backend produces.

---

## Why gbrain, not a bigger JSON file

gbrain's value isn't the LLM — it's the **discipline of storage**, and three
properties map perfectly onto a learner record:

| gbrain property | What it buys the learner record |
| --- | --- |
| Typed pages + declared graph edges (`put_page` materializes edges for free) | Every skill is backed by the *moments* that proved it — auditable, not asserted |
| Timeline + append-only history | The longitudinal chart itself: every "visit," never overwritten |
| `think` = synthesis **with explicit gap analysis** | The diagnostic — "what to teach next, what they don't know yet" |
| Dream-cycle **contradiction detection** | "Claimed mastery, then failed near-transfer" is surfaced, not discarded — the single most valuable tutoring signal |

The one rule that makes this a *chart* and not a scratchpad: **every claim
traces to a captured moment.** `skills/recursion.md` never just says "knows
recursion (0.8)" — that number is justified by `demonstrated_by` backlinks to
the teachbacks and reviews that earned it.

---

## Architecture

```
Teachy.app (Swift, the interface)
   │  writes learning events        reads grounding + gap analysis
   ▼                                  ▲
gbrain sidecar (single compiled binary, PGLite — no external Postgres)
   │
   ▼
~/.teachy/brain/            ← the learner record (git repo of markdown pages)
   ├── learner/me.md
   ├── skills/*.md          ← proficiency justified by backlinks, not by a number
   ├── sessions/*.md        ← the timeline
   ├── teachbacks/*.md      ← the explanations, verbatim, scored
   ├── reviews/*.md         ← spaced-repetition outcomes
   ├── misconceptions/*.md  ← durable contradictions (open|resolved)
   └── artifacts/*.md       ← the portfolio
```

- **Sidecar, not a rewrite.** gbrain compiles to a self-contained binary
  (`bun build --compile --target=bun-darwin-arm64`) with PGLite WASM embedded,
  so it runs fully local with no Postgres and no Bun install on the user's
  machine. This is the same shape as the C# sidecar already shipped on Windows.
- **Vendoring decision (locked): pinned prebuilt binary.** Build the sidecar at
  a pinned gbrain version, ship the binary + our pack. Keeps the closed-source /
  BYOK model clean; we re-pin to pull upstream fixes.
- **Provisioned on install.** First run initializes `~/.teachy/brain/` as a
  gbrain repo and installs the [`teachy-learner-v1`](./teachy-learner-v1.yaml)
  schema-pack. This is the "install it manually when they install Teachy" step.
- **The schema-pack is the whole "make it education" job.** We do not vendor
  gbrain's knowledge-worker types (deal, email, slack, tweet). The learner
  record is a small, sharp taxonomy — see `teachy-learner-v1.yaml`.

---

## The schema-pack

[`teachy-learner-v1.yaml`](./teachy-learner-v1.yaml) — 11 page types, 10 typed
edges (each with an inverse), and frontmatter-links so one `put_page` writes the
page *and* its graph edges.

- **Nouns:** `learner`, `skill`, `concept`, `goal`, `course`, `session`,
  `teachback`, `review`, `misconception`, `artifact`, `note`.
- **Verbs:** `demonstrates`, `checks`, `covers`, `targets`, `prerequisite_of`,
  `transfers_to`, `contradicts`, `evidences`, `part_of`, `about`.

> **Authoring constraint (confirmed the hard way):** gbrain parses packs with a
> hand-rolled **mini-YAML parser**, not js-yaml. Block/folded scalars (`|`,
> `>`, `>-`), anchors, aliases, and tags are **unsupported** and silently break
> the parse (types come out empty while `validate` still says "valid"). Keep the
> pack to: plain `key: value`, 2-space nested maps, `- ` sequences, flow arrays
> `[a, b]`, and `#` comments. Install location: `~/.gbrain/schema-packs/<name>/pack.yaml`.

### Validated spike (this session)

Ran against a real local gbrain (Bun + PGLite, no Postgres, no server):
`schema validate` → 11 types / 10 verbs clean · `init --pglite --no-embedding`
· `put skills/recursion` + `put teachbacks/…` (type inferred from path) ·
`link … --link-type demonstrates` + `--link-type checks` · `backlinks
skills/recursion` returns both evidence edges. The evidence-cited spine works.

---

## Write path — from signals Teachy already produces

The point: Teachy **already generates** every signal this record needs. Today
those signals collapse into a flat blob and are lost. Here they become durable,
linked pages. Nothing new has to be *measured* — only *restructured*.

| Teachy source (today) | Learner-brain write |
| --- | --- |
| `LessonPlayer` starts a goal | `put_page` a `session`, `targets` the goal, `part_of` the course |
| `TeachBackEngine` scores an explanation | `put_page` a `teachback` (explanation verbatim + score), `demonstrates` the skill |
| `VerificationEngine` near-transfer fails after a pass | `put_page` a `misconception` that `contradicts` the skill (status: open) |
| `SpacedRepetitionEngine` logs a review | `put_page` a `review`, `checks` the skill, carries SM-2 interval |
| Course goal verified (`CourseVerifier`) | update the `skill` page; `evidences` from any produced `artifact` |
| `PortfolioManager` captures an artifact | `put_page` an `artifact`, `evidences` the skill/goal |

Each is a `put_page` **plus an explicit typed `link`** (e.g.
`link teachbacks/… skills/… --link-type demonstrates`). This is deterministic
and is the path proven in the spike. The pack also declares `frontmatter_links`,
but auto-materialization from frontmatter is gated behind gbrain's
link-resolution config and did not fire out of the box — so the writer issues
explicit links rather than depending on that heuristic.

---

## Read path — grounding the coach

Replace the flat `LearnerModel` injection into coach prompts with grounded
retrieval:

- **Before a coaching turn:** `think "what does this learner know about
  <current skill>, and what's the gap?"` → a synthesized, cited answer that
  names what's *missing*. This is the diagnostic the flat profile can't give.
- **Choosing what's next:** `traverse_graph` over `prerequisite_of` to find the
  nearest unmet prerequisite; `get_backlinks` on a skill to see the actual
  evidence behind its proficiency.
- **Continuity:** the existing `LearnerTemporalContext` phrasing is regenerated
  from the timeline instead of from dated fields on the blob.

---

## The "show it to a person" surface

The record is only MyChart if the learner can *see* it. Surfaced in-app and,
crucially, **shareably** (Approach A):

- **The shareable receipt** (`shipped-it-receipt.html`): the win, brag-worthy,
  Teachy-attributed, install-linked — each skill line backed by the moment that
  earned it. This is the growth loop *and* the trust guardrail in one artifact.
- **Skills tab** (`NotchSkillsTabView`): each skill shows its proficiency *and
  the evidence behind it* — "you taught this back on Jul 12, recalled it
  unaided on Jul 19." Tap-through to the actual teachback.
- **Portfolio tab** (`NotchPortfolioTabView`): artifacts with their verification
  provenance — proof the human, not the AI, produced the skill.

---

## Open decisions / honest risks

1. **Transport: CLI vs MCP.** gbrain exposes the same operations over a compiled
   CLI and over MCP (stdio + HTTP). *Leaning MCP-over-stdio* — matches the agent
   tooling Teachy already speaks and avoids per-call process spawn.
2. **Local embedder is a real P1 task (confirmed).** Decision: local embeddings
   in the sidecar. But gbrain's built-in embedding providers are **all cloud**
   (OpenAI / Voyage / ZeroEntropy) — it ships **no local embedder**. So P1
   includes *adding* a local embedding provider to the vendored gbrain (ONNX /
   local model). Confirmed in the spike: `init --pglite --no-embedding` works
   and writes + graph edges + backlinks all function with **zero** embedding
   provider — only hybrid *semantic* search degrades until the local embedder
   lands. So the record is useful from day one; embeddings are a search-quality
   upgrade, not a blocker. LLM `think`/gap-analysis still routes through the
   existing Teachy worker.
3. **Binary size.** Bun-compiled + PGLite WASM + local embedder is tens of MB.
   Acceptable for a sidecar; note it against the DMG size budget.
4. **Migration.** One-time importer: read the existing
   `~/.teachy/engine-state.json` and seed `skill`/`misconception` pages so no
   learner starts cold. Seeded skills carry low-confidence, un-cited proficiency
   until re-earned (the old blob has no moments).

---

## Phased plan

- **P0 — schema + spine spike (done):** `teachy-learner-v1.yaml` + this design;
  validated against real gbrain (PGLite), evidence backlink loop proven. ✅
- **A — share receipt (done, brick 1):** `shipped-it-receipt.html` (live) +
  `shipped-it-receipt.template.html` (fill-in-the-blanks, `{{TOKEN}}`s) — the
  shareable proof page that renders the record. Falsifies the #1 growth risk. ✅
- **P2 — write path (done, code):** `TeachyEngine/LearnerBrainWriter.swift`
  (maps `LearnerEvent`s → `put_page` + explicit `link`) + `GBrainClient.swift`
  (transport seam: `NoOpGBrainClient` today, `GBrainCLIClient` for P1). Wired
  into `TeachyEngine.processEvent` and `shipProject`, nil-safe. The evidence
  spine it produces was verified offline this session (a realistic build-and-
  ship session replayed through the writer's exact rules: 15 pages / 15 typed
  edges, every skill backed by a `demonstrates`/`checks`/`evidences` moment, no
  dangling edges). ✅ (code + spine verified) / ⏳ (inert until a binary is
  present)
- **P1 — provisioning (Swift half done; binary half remains):**
  - **✅ Swift seam (this session):** `TeachyEngine/LearnerBrainProvisioner.swift`
    resolves a gbrain executable (env override → bundled Resource → bun-runtime
    → `~/.teachy/bin/gbrain`), ensures the brain home + schema-pack are
    installed, runs first-run `init --pglite --no-embedding`, constructs
    `GBrainCLIClient`, and assigns `engine.learnerBrainWriter` — wired into
    `CompanionManager.start()`, off-main, best-effort. Safe-by-default: with no
    binary it stays `nil` and Teachy behaves exactly as before. NOTE: it targets
    gbrain's real default home `~/.gbrain` (what the spike produced), not the
    aspirational `~/.teachy/brain` — relocating is gated on verifying gbrain's
    `GBRAIN_HOME` contract against a live binary.
  - **⏳ Binary + embedder (needs a build session):** build the pinned gbrain
    PGLite binary (`bun build --compile`), add a local embedding provider to the
    vendored gbrain (it ships none), and drop the binary + pack into the app
    bundle (or `~/.teachy/bin/gbrain`). The moment that lands, the whole record
    goes live with no further Swift changes. The one gbrain-CLI contract the
    Swift can't re-verify in a coding session — the exact `init` flags — is
    taken from what the spike actually ran (`config.json` confirms `pglite` +
    `embedding_disabled`).
- **P3 — read path:** replace flat `LearnerModel` prompt injection with `think`
  gap-analysis; prerequisite traversal for "what's next."
- **P4 — the chart (Skills surface done):**
  - **✅ Skills evidence surface:** `NotchSkillsTabView` "Proof Behind Your
    Skills" — each learned skill expands to the captured moments that earned its
    level (teach-backs w/ quality, verifications, spaced-review recalls,
    contexts, level-up reasons), read from the existing flat `LearnerModel` so
    it works today. When the gbrain record is live, these become tap-through
    links to the actual teachback/review pages.
  - **⏳ Remaining:** Portfolio provenance UI, a session timeline, and wiring the
    real gbrain record (vs the flat model) into both the Skills surface and the
    share receipt.
- **P5 — dream cycle:** nightly consolidation (contradiction resolution, skill
  decay, review scheduling) as a scheduled sidecar run.

Pack validation (done): install to `~/.gbrain/schema-packs/teachy-learner-v1/pack.yaml`,
then `gbrain schema validate teachy-learner-v1` and `gbrain schema lint teachy-learner-v1`.
