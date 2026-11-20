# Skill Market download counter

A small Cloudflare Worker + D1 database behind the download counts in the Skills Library
(the app and https://vedsoni-dev.github.io/teachy/skillmarket/).

- `GET /counts` returns `{ "counts": { "<skill id>": <downloads> } }` (cached 60 s).
- `POST /count` with `{ "id": "<skill id>", "source": "app" | "download" }` adds one.
  The app sends it after someone adds a market skill; the site sends it when someone
  downloads the file. "Add to Teachy" on the site isn't counted, because the app counts
  the add itself.

The same visitor counts once per skill per day. Only a keyed hash of IP + skill + day is
kept, for two days. Unknown IDs (not in the published `index.json`) are refused.

## Set up once

```bash
cd skillmarket-worker
npx wrangler d1 create teachy-skillmarket       # paste the id into wrangler.toml
npx wrangler d1 execute teachy-skillmarket --remote --file schema.sql
openssl rand -hex 32 | npx wrangler secret put SALT_SECRET
npx wrangler deploy
```

Then put the Worker's URL in `SkillMarketConfiguration.countsBaseURL` (app) and
`COUNTS_URL` in `academy/skillmarket/skillmarket.js` (site).
