# Teachy (website)

Marketing site for **Teachy**, the Mac assistant that lives next to your cursor: hold a key, ask about your screen, and it answers out loud, points and draws, types what you say, remembers you, and can run jobs for you.

Plain static files, no build step.

## Pages

| File | What it is |
|------|------------|
| `index.html` | Landing page: hero with the Mac download, a privacy line, five feature sections (guidance in any app, agent jobs, dictation, memory, 2D/3D drawing), closing download band, footer. |
| `changelog.html` | Release notes, newest first. Add a new `<article class="entry">` at the top for each release. |
| `enterprise.html` | Older teams page. Still uses `styles.css`; not linked from the new pages. |
| `site.css` | Styles for `index.html` and `changelog.html` (light `#f2f2f2` page, chat bubbles, mac-window frames, pointer rings). |
| `app.js` | Small progressive enhancement: chat bubbles drop in on scroll, footer year, sizing for the CSS 3D cube. |
| `registry.json` | Kept for the app and release tooling that may still read it. Not linked from the site. |
| `vercel.json` | Static hosting headers. |

### Feature section pattern

Each feature is a `section.feature` with the copy on the left (waveform glyph, a blue `.bubble-user` and a peach `.bubble-teachy`, an `h2`, a short `.desc`) and a `.mac-window` on the right. Window contents are either the recorded demo (`assets/hero-demo/teachy-hero.*`) or a small HTML scene, plus a labelled `.pointer` ring positioned with inline `left`/`top` percentages. Copy a section to add another.

No third-party media: everything in the windows is our own recording or built in HTML/CSS.

## Download link

All download buttons point at the public releases repo:

`https://github.com/VedSoni-dev/teachy-releases/releases/latest/download/Teachy.dmg`

## Local preview

```bash
cd academy
python3 -m http.server 8765
# http://localhost:8765/
```

## Publishing

```bash
./scripts/publish-academy.sh
```

That copies `academy/` to the `gh-pages` branch and pushes it. Edit files under `academy/` on `main` first, commit, then run the script.
