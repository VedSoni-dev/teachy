// Teachy Skill Market download counter.
//
//   GET  /counts                      → { "counts": { "<skill id>": <downloads>, … } }
//   POST /count  { "id": "<skill id>", "source": "app" | "download" }  → { "counted": bool }
//
// The app posts when someone adds a market skill; the site posts when someone downloads the file.
// Nothing about the person is stored: each count is deduplicated by a hash of their IP address,
// the skill and the day, keyed with the SALT_SECRET Worker secret (so the hashes can't be
// reversed by trying every IP), and those hashes are deleted after two days.
// Only listings in the published index are counted.

export interface Env {
  DB: D1Database;
  INDEX_URL: string;
  /** Set with `npx wrangler secret put SALT_SECRET` (any long random string). */
  SALT_SECRET: string;
}

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Access-Control-Max-Age": "86400",
};

const validSkillID = /^[a-z0-9]+(-[a-z0-9]+)*$/;

function json(body: unknown, status = 200, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders, ...extraHeaders },
  });
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** The listing IDs in the published index, cached at the edge for five minutes. */
async function publishedSkillIDs(env: Env): Promise<Set<string>> {
  const response = await fetch(env.INDEX_URL, { cf: { cacheTtl: 300, cacheEverything: true } });
  if (!response.ok) throw new Error(`index ${response.status}`);
  const index = (await response.json()) as { skills?: Array<{ id?: string }> };
  return new Set((index.skills ?? []).map((skill) => skill.id ?? "").filter(Boolean));
}


async function handleCount(request: Request, env: Env): Promise<Response> {
  let body: { id?: unknown; source?: unknown };
  try {
    body = await request.json();
  } catch {
    return json({ error: "Send JSON: {\"id\": \"…\"}" }, 400);
  }
  const skillID = typeof body.id === "string" ? body.id : "";
  if (!validSkillID.test(skillID) || skillID.length > 64) return json({ error: "Unknown skill." }, 400);
  if (body.source !== undefined && body.source !== "app" && body.source !== "download") {
    return json({ error: "source must be app or download." }, 400);
  }

  const known = await publishedSkillIDs(env).catch(() => null);
  if (!known) return json({ error: "Try again later." }, 503);
  if (!known.has(skillID)) return json({ error: "Unknown skill." }, 404);

  if (!env.SALT_SECRET) return json({ error: "Counting isn't set up." }, 503);
  const day = new Date().toISOString().slice(0, 10);
  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const visitorKey = await sha256Hex(`${env.SALT_SECRET}|${day}|${ip}|${skillID}`);

  const firstToday = await env.DB.prepare("INSERT OR IGNORE INTO recent_counts (visitor_key, day) VALUES (?, ?)")
    .bind(visitorKey, day)
    .run();
  const counted = (firstToday.meta.changes ?? 0) > 0;
  if (counted) {
    await env.DB.prepare(
      "INSERT INTO skill_counts (skill_id, downloads) VALUES (?, 1) ON CONFLICT(skill_id) DO UPDATE SET downloads = downloads + 1",
    ).bind(skillID).run();
  }
  // Housekeeping: forget visitor hashes from before yesterday.
  const twoDaysAgo = new Date(Date.now() - 2 * 86_400_000).toISOString().slice(0, 10);
  await env.DB.prepare("DELETE FROM recent_counts WHERE day < ?").bind(twoDaysAgo).run();

  return json({ counted });
}

async function handleCounts(env: Env): Promise<Response> {
  const result = await env.DB.prepare("SELECT skill_id, downloads FROM skill_counts").all<{ skill_id: string; downloads: number }>();
  const counts: Record<string, number> = {};
  for (const row of result.results ?? []) counts[row.skill_id] = row.downloads;
  return json({ counts }, 200, { "Cache-Control": "public, max-age=60" });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
    try {
      if (request.method === "GET" && url.pathname === "/counts") return await handleCounts(env);
      if (request.method === "POST" && url.pathname === "/count") return await handleCount(request, env);
      if (request.method === "GET" && url.pathname === "/") return json({ ok: true, service: "teachy-skillmarket" });
      return json({ error: "Not found." }, 404);
    } catch (error) {
      console.error("skillmarket error", error);
      return json({ error: "Something went wrong." }, 500);
    }
  },
} satisfies ExportedHandler<Env>;
