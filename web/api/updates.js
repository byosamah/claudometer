// Serverless update feed + anonymous active-install counter.
//
// The macOS app's UpdateChecker polls /updates.json (rewritten here by vercel.json).
// We return the exact JSON it has always expected AND best-effort count each check
// in Upstash Redis, so we can see how many installs are active and which builds they
// run. Counting NEVER blocks the response: if the store is unconfigured or down, the
// feed still returns normally. No npm dependencies (Upstash REST via global fetch),
// matching the project's no-third-party-deps ethos.

// Single source of truth for the published build. BUMP THIS ON EVERY RELEASE
// (this replaced the old static web/updates.json; see docs/RELEASING.md).
const FEED = {
  version: "1.2",
  build: 2,
  downloadURL: "https://github.com/byosamah/claudometer/releases/latest/download/Claudometer.dmg",
  notes:
    'New: "Claude is waiting on you" alerts. When a Claude Code session in any ' +
    "terminal needs your approval, the menu-bar mascot shows a count badge plus an " +
    "on-brand pop, and the panel lists which project is waiting, so you never leave " +
    'Claude hanging after tabbing away. Opt in from the panel footer. Also: a ' +
    'reliability fix so usage never gets stuck on "Connecting".',
  minimumSystemVersion: "26.0",
};

const KV_URL = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL;
const KV_TOKEN = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN;

// Run several Redis commands in one Upstash REST round-trip. Returns null when the
// store is unconfigured or the call fails, so callers degrade gracefully.
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

module.exports = async (req, res) => {
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.statusCode = 405;
    res.end("method not allowed");
    return;
  }

  // Anonymous dimensions newer app builds append (?v=<build>&os=<major.minor>).
  // The current 1.2 build sends none -> counted as build "unknown". Nothing here
  // identifies a device or user. `v` is attacker-controlled input: the app only
  // ever sends a small integer (CFBundleVersion), so anything else collapses to
  // "unknown" instead of minting a fresh Redis key per junk value.
  const q = new URL(req.url, "https://x").searchParams;
  const raw = q.get("v") || "";
  // Also bound by the newest PUBLISHED build: no real install can run a build
  // above it, so numeric junk (v=100..163) can't fill the Lua gate's 64-slot
  // set and freeze out future real releases.
  const build = /^\d{1,6}$/.test(raw) && Number(raw) >= 1 && Number(raw) <= FEED.build ? raw : "unknown";
  const day = new Date().toISOString().slice(0, 10);

  // Capped, atomic counting (Lua so the check-then-add can't race). Per-build
  // counters and the builds set only grow for already-known builds or while the
  // set is small, so a curl loop with unique v= values can never inflate Redis
  // or blow up /api/stats' one-GET-per-member fan-out. Real builds arrive one
  // per release; 64 is years of headroom. Totals and per-day always count.
  const COUNT = `
    redis.call('INCR', 'updates:total')
    redis.call('INCR', 'updates:day:' .. ARGV[2])
    redis.call('SADD', 'updates:days', ARGV[2])
    if redis.call('SISMEMBER', 'updates:builds', ARGV[1]) == 1
       or redis.call('SCARD', 'updates:builds') < 64 then
      redis.call('INCR', 'updates:build:' .. ARGV[1])
      redis.call('SADD', 'updates:builds', ARGV[1])
    end
    return 1`;

  // Best-effort counting; swallowed failures never touch the feed response.
  await pipeline([["EVAL", COUNT, "0", build, day]]);

  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Cache-Control", "no-store"); // each check must reach the function to count
  res.statusCode = 200;
  res.end(JSON.stringify(FEED));
};
