# P1 — Light up the Learner Brain (the one blocked step)

**Date:** 2026-07-22 · **Status:** everything *around* this is done; this is the
single remaining gate.

The Swift half of the Learner Brain is complete and shipping-safe: the write path
(`LearnerBrainWriter` + `GBrainClient`) is wired into `TeachyEngine`, the
provisioning seam (`LearnerBrainProvisioner`) runs at app start, and the
learner-facing surfaces (Skills "Proof Behind Your Skills", Portfolio provenance)
render today from the flat model. All of it is **nil-safe**: with no gbrain
binary present, `provisionClient()` returns `nil` and Teachy behaves exactly as
before.

The record goes **live** the moment `LearnerBrainProvisioner.resolveExecutable()`
finds a runnable gbrain. This doc is how to make that happen and verify it.

> ⚠️ **Name collision — do not `npm/bunx install gbrain`.** The npm package
> `gbrain@1.3.1` is an unrelated old "GPU Javascript Library for ML" by stormcolor
> and is **not** the personal-knowledge engine we target. It will land in the bun
> cache and mislead you. The real one is Garry Tan's Postgres-native engine
> (github.com/garrytan/gbrain — verify the exact repo before cloning).

---

## Fastest dev bring-up (env-override, uses the bun already on this machine)

`bun` is installed at `/Users/ved.soni/.bun/bin/bun` (1.3.14) but off PATH. The
provisioner's resolution order #1 is env overrides, so no bundling is needed to
prove the loop:

1. **Get the real gbrain source** checked out locally (its `src/cli.ts`
   entrypoint is what the bun path drives). Confirm the repo is the PGLite
   knowledge engine, not the npm collision above.
2. **Point Teachy at it** via the Xcode scheme's environment variables
   (Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables):
   ```
   TEACHY_GBRAIN_BUN = /Users/ved.soni/.bun/bin/bun
   TEACHY_GBRAIN_CLI = /absolute/path/to/gbrain/src/cli.ts
   ```
   (These map 1:1 to `resolveExecutable()` step 1, which builds the
   `bun run <cli.ts>` launch prefix `GBrainCLIClient` already understands.)
3. **Run Teachy** (Cmd+R — never `xcodebuild` from terminal; it invalidates TCC).
   In a DEBUG build, watch the console for the `[LearnerBrain:provision]` lines:
   - `gbrain executable: …` → resolution succeeded
   - `installing schema-pack teachy-learner-v1` (first run only)
   - `initializing gbrain PGLite brain (first run)` (first run only)
   - `learner record is live` → **the seam flipped on.**

The brain already exists on this machine from the P0 spike
(`~/.gbrain/{config.json, schema-packs/teachy-learner-v1/pack.yaml, brain.pglite}`,
`embedding_disabled: true`), so init should no-op and the client should report
ready immediately.

---

## Verify the three CLI contracts the Swift client assumes

`GBrainClient` was written against the shapes the spike ran; they are the one
thing no Swift code could re-verify without a live binary. Confirm each against
the real gbrain, adjusting `GBrainCLIClient` / `LearnerBrainProvisioner` if the
real CLI differs:

| Swift call | Command issued | Verify |
| --- | --- | --- |
| `writePage(slug:…)` | `gbrain put <slug>` with composed `---\ntype: …\n---\n\n<body>` on **stdin** | page created, `type` inferred from frontmatter, frontmatter parsed |
| `addLink(from:to:type:)` | `gbrain link <from> <slug> --link-type <type>` | edge created; re-issuing is idempotent |
| `runInit()` | `gbrain init --pglite --no-embedding` | exits 0; produces `brain.pglite` |
| (read-side, later) | `gbrain backlinks <skillSlug>` | returns the evidence edges |

Quick manual smoke test (from `~/.gbrain`, with bun on PATH):
```bash
export PATH="/Users/ved.soni/.bun/bin:$PATH"
printf -- '---\ntype: skill\nskill_id: recursion\n---\n\n# Recursion\n' \
  | bun run /path/to/gbrain/src/cli.ts put skills/recursion
bun run /path/to/gbrain/src/cli.ts put teachbacks/2026-07-22-demo   # (with a teachback doc on stdin)
bun run /path/to/gbrain/src/cli.ts link teachbacks/2026-07-22-demo skills/recursion --link-type demonstrates
bun run /path/to/gbrain/src/cli.ts backlinks skills/recursion       # expect the demonstrates edge
```
If `put`/`link`/`backlinks` differ (subcommand names, `--link-type` flag,
stdin vs. arg), fix the two Swift files — the writer above the seam is unaffected.

---

## Shipping path (later, for the DMG)

Env overrides are dev-only. To ship the record to users, satisfy
`resolveExecutable()` step 2 by bundling under the app's `Resources/gbrain/`:

- **Option A (binary):** `bun build --compile --target=bun-darwin-arm64` the
  pinned gbrain into `Resources/gbrain/gbrain`. Blocked by gbrain #1340 (PGLite
  WASM can't extract from the compiled read-only VFS) unless resolved upstream.
- **Option B (runtime, matches the bun path):** bundle the `bun` binary at
  `Resources/gbrain/bun` and gbrain's source at `Resources/gbrain/src/cli.ts`.
  Larger DMG, but sidesteps #1340.

Then the real P1 infra task the design doc flagged: **add a local embedder** to
the vendored gbrain (it ships only cloud embedders — OpenAI/Voyage/ZeroEntropy).
Until then `--no-embedding` is correct and everything except semantic search
works; `think`/gap-analysis still routes through the existing Teachy worker.

---

## After it's live

- **P3 read path:** replace flat `LearnerModel` prompt injection with `think`
  gap-analysis + `prerequisite_of` traversal for "what's next."
- **P4 remainder:** wire the real record (vs the flat model) into the Skills
  evidence tap-through, add the session timeline (real "visits"), and render the
  live record into `learner-brain/shipped-it-receipt.template.html`.
