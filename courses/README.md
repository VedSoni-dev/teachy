# Teachy Courses (open curriculum)

Courses are JSON learning paths. Teachy coaches on the learner’s real screen — no hardcoded buttons or YouTube embeds in the app chrome.

For **your own teaching**, use the same beside-cursor video player as Farza’s intro: short **parts** that float next to Teachy, then hands-on coaching for that goal. Every goal can have its own teacher clip.

## Where courses live

| Location | Role |
|----------|------|
| `courses/*.json` (this folder) | Authoring / open-source source of truth |
| `academy/` | **Teachy Academy** website + `registry.json` wall |
| Bundled Swift catalog | Ships in the app today (mirrors core JSON files) |
| `~/.teachy/courses/*.json` | Installed from URL / academy (Learn → Add) |

### Install from the academy

1. Open `academy/index.html` (or the hosted Academy site)
2. **Copy install URL** on a wall post
3. In Teachy → **Learn** → paste → **Add**

GitHub blob links are auto-converted to raw URLs.

### Publishing & continuous updates

Ship (or fix) a course with one command — it copies the JSON into the public
`teachy-releases` repo and upserts its store registry entry:

```bash
./scripts/publish-course.sh courses/my-course.json --blurb "Store card one-liner" --track "How to do"
```

Installed copies **auto-update**: on every app launch and Academy refresh,
Teachy re-fetches each installed course from its source URL and silently
swaps in the new version (never mid-lesson). Publishing a fix upstream is
all it takes to update every learner.

**Rule: keep goal `id`s stable across updates.** Learner progress is keyed
by goal id — renaming an id makes completed steps look incomplete. Add new
goals with new ids and edit existing goals freely, but don't rename ids.

## Teacher videos (Farza-style, every part)

Do **not** paste normal YouTube watch URLs into the course UI. Upload your clips (Mux, Cloudflare Stream, or any **HLS `.m3u8` / progressive `.mp4`** CDN) and put the stream URL on the course and/or each goal.

Preferred keys (new courses):

- `teacherVideoURL` — your clip for that part
- `teacherName` — credit shown on the beside-cursor player (e.g. `"Farza"`, `"Maya"`)

Legacy alias still works: `introVideoURL` (same player).

```json
{
  "id": "my-course",
  "title": "My Course",
  "teacherName": "Your Name",
  "teacherVideoURL": "https://stream.mux.com/YOUR_COURSE_INTRO_PLAYBACK_ID.m3u8",
  "goals": [
    {
      "id": "part-1",
      "title": "First skill",
      "goal": "…",
      "coachAsk": "…",
      "doneWhen": "…",
      "teacherVideoURL": "https://stream.mux.com/PART_1_PLAYBACK_ID.m3u8",
      "teacherName": "Your Name"
    },
    {
      "id": "part-2",
      "title": "Second skill",
      "goal": "…",
      "coachAsk": "…",
      "doneWhen": "…",
      "teacherVideoURL": "https://stream.mux.com/PART_2_PLAYBACK_ID.m3u8"
    }
  ]
}
```

Omit `teacherVideoURL` on a goal if that part is coach-only (still fine). Put a clip on **every** part when you’re filming a full Farza-style track.

### Playback order per goal

1. Optional course `startURL` (opens a soft homepage once)
2. Optional course `teacherVideoURL` / `introVideoURL` (once per session)
3. Optional goal `teacherVideoURL` / `introVideoURL` (this part’s clip beside Teachy, with your name on it)
4. Teachy coaches + points on screen
5. Learner’s turn → verify `doneWhen` → next goal

Learners can **Skip video** on the HUD, or say **“skip”**.

### Suggested part length

- **2–8 minutes** per part works best (explain, then do)
- One part ≈ one `goal`
- Keep `coachAsk` / `doneWhen` about the durable outcome — the video is context, not a layout contract

### Mux (recommended)

1. Upload each part to [Mux](https://www.mux.com/)
2. Use the playback HLS URL: `https://stream.mux.com/{PLAYBACK_ID}.m3u8`
3. Paste into `teacherVideoURL`

Same pattern Farza’s onboarding uses in the app.

## Goal fields

| Field | Required | Purpose |
|-------|----------|---------|
| `id` | yes | Stable id for progress |
| `title` | yes | Short label in HUD |
| `goal` | yes | What success looks like (plain language) |
| `coachAsk` | yes | Natural ask Teachy auto-sends |
| `doneWhen` | no | Vision YES/NO check to advance |
| `tips` | no | Soft hints for the tutor |
| `teacherVideoURL` | no | Part clip beside Teachy before coaching (preferred) |
| `introVideoURL` | no | Legacy alias for the same part clip |
| `teacherName` | no | Credit on the player (falls back to course `teacherName`) |
| `teacherVideoNotes` | no | Bullets / transcript Teachy reads after the clip |
| `teachingContext` | no | Lesson brief: concepts, mistakes, successExamples, whyItMatters, teachBackPrompt, skipTeachBack |
| `toolPolicy` | no | `pointOnly` · `preferPointing` (default) · `helpWhenStuck` · `canDoForThem` |

Never encode button names, grid cells, or pixel layouts in goals.

### Teaching that actually sticks

After vision `doneWhen` passes, Teachy runs a soft **teach-back** (“in your words…”) unless `teachingContext.skipTeachBack` is true. Answers update a durable **learner model** per course (`knows` / `confusedBy` / hint vs do-it-for-me prefs). Coach replies can also stash facts with `[MEMORY:knows:…]` / `[MEMORY:confused:…]` (stripped before speech).

## Example template

See [`_template-with-video-parts.json`](_template-with-video-parts.json). Replace Mux URLs with yours and drop the file into `~/.teachy/courses/` to try it without rebuilding.
