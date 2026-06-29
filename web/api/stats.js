// Guarded, read-only view of the update-counter: GET /api/stats?key=<STATS_KEY>.
// Set the STATS_KEY env var in the Vercel project to enable it. Returns total
// active checks, plus breakdowns by app build and by day.

const KV_URL = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL;
const KV_TOKEN = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN;

async function pipeline(commands) {
  if (!KV_URL || !KV_TOKEN) return null;
  try {
    const r = await fetch(`${KV_URL}/pipeline`, {
      method: "POST",
      headers: { Authorization: `Bearer ${KV_TOKEN}`, "Content-Type": "application/json" },
      body: JSON.stringify(commands),
    });
    return r.ok ? await r.json() : null;
  } catch {
    return null;
  }
}

// Upstash returns [{ result }, ...]; pull the results out.
const results = (rows) => (Array.isArray(rows) ? rows.map((x) => x && x.result) : []);

module.exports = async (req, res) => {
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.setHeader("Cache-Control", "no-store");
  const key = new URL(req.url, "https://x").searchParams.get("key");

  if (!process.env.STATS_KEY) {
    res.statusCode = 503;
    res.end(JSON.stringify({ error: "Set the STATS_KEY env var in Vercel to enable this endpoint." }));
    return;
  }
  if (key !== process.env.STATS_KEY) {
    res.statusCode = 403;
    res.end(JSON.stringify({ error: "forbidden" }));
    return;
  }
  if (!KV_URL || !KV_TOKEN) {
    res.statusCode = 503;
    res.end(JSON.stringify({ error: "No KV store linked yet (KV_REST_API_URL / KV_REST_API_TOKEN unset)." }));
    return;
  }

  const [total, builds, days] = results(
    await pipeline([
      ["GET", "updates:total"],
      ["SMEMBERS", "updates:builds"],
      ["SMEMBERS", "updates:days"],
    ])
  );

  const buildList = builds || [];
  const dayList = (days || []).sort();
  const counts = results(
    await pipeline([
      ...buildList.map((b) => ["GET", `updates:build:${b}`]),
      ...dayList.map((d) => ["GET", `updates:day:${d}`]),
    ])
  );

  const byBuild = {};
  buildList.forEach((b, i) => (byBuild[b] = Number(counts[i]) || 0));
  const byDay = {};
  dayList.forEach((d, i) => (byDay[d] = Number(counts[buildList.length + i]) || 0));

  res.statusCode = 200;
  res.end(JSON.stringify({ totalChecks: Number(total) || 0, byBuild, byDay }, null, 2));
};
