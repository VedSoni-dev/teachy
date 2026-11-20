# Skill Market

The Skill Market lists skills people wrote for Teachy. It is served at
https://vedsoni-dev.github.io/teachy/skillmarket/ and read by the app from
`index.json` (Settings → Skills).

A skill teaches Teachy its way around one app or site: where things are by the
names on screen, how to get to the things people ask for most, what trips people
up, and the shortcuts worth knowing. Teachy adds the skill for the app you're in
to what it reads before it answers.

## Publish a skill

1. Write the skill as Markdown with a front-matter block:

   ```markdown
   ---
   name: Linear
   id: linear
   version: 1.0
   author: Your name
   authorURL: https://github.com/you
   category: Work
   icon: 🎯
   headline: Move fast in Linear: issues, cycles, filters and shortcuts.
   description: For engineers and PMs who want the shortcuts without typing into the wrong issue.
   goodFor: [Linear, Issue tracking, Shortcuts]
   added: 2026-11-19
   highlights:
     - Sidebar, list and issue layout
     - The single-key shortcuts worth knowing
   bundleIds: [com.linear]
   sites: [linear.app]
   summary: Issue tracking for software teams.
   ---
   ## Layout
   ## Where things are
   ## Gotchas
   ## Shortcuts
   ```

   - `id`: lowercase letters, digits and hyphens. The file must be named `<id>.skill.md`.
   - `bundleIds`: the Mac app's bundle identifier (`osascript -e 'id of app "Linear"'`).
   - `sites`: host names, optionally with a path (`docs.google.com/spreadsheets`). A
     skill needs at least one bundle ID or site.
   - `category`: one short word (Work, Design, Notes, Social, Meetings, …).
   - `version`: bump it when you change the file; Teachy offers an Update.
   - `icon` (one emoji), `headline`, `description`, `goodFor` and `highlights` fill the
     Skills Library's detail pane in the app and on the site. `added` (YYYY-MM-DD) shows a
     New badge for 30 days. Only the sections below the front matter go into Teachy's prompt.
   - Keep it under about 2,500 characters. Sections are added to the prompt whole, in
     order, until the budget runs out.

2. Try it: Teachy → Settings → Skills → Add from file. Ask Teachy something in that app.

3. Add it to `academy/skillmarket/skills/`, run `node scripts/build-skillmarket.mjs`
   (it checks the file and rebuilds `index.json`), and open a pull request.

## What gets merged

- Accurate, current notes about a real app, written in plain words.
- Nothing that tries to change how Teachy behaves beyond knowing the app: no
  instructions to run commands, open links, send messages or ignore the person.
  Teachy treats skills as notes and trusts the screen over them, but reviewers
  reject these anyway.
- No secrets, tracking links or personal data.

## Download counts

Each listing shows how many times it was downloaded: adds from the Teachy app plus file
downloads on the site, counted by `skillmarket-worker/` (one per person per skill per day;
no personal data is kept).

## Maintainers

- `node scripts/build-skillmarket.mjs` rebuilds `index.json`; `--check` fails if it
  is out of date. `scripts/tests/run_skill_market_tests.sh` checks that every listing
  installs cleanly.
- The site goes live with `./scripts/publish-academy.sh`.
