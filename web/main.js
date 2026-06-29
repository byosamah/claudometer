/* Claudometer landing page interactions.
   GSAP for entrance + scroll reveals, an odometer count-up for the readings,
   a live mascot mood, and a changelog pulled from GitHub Releases. */

const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
document.documentElement.classList.add('js'); // belt-and-suspenders (also set in <head>)

/* ---- Nav: frost on scroll --------------------------------------------- */
const nav = document.getElementById('nav');
const onScroll = () => nav.classList.toggle('scrolled', window.scrollY > 8);
onScroll();
window.addEventListener('scroll', onScroll, { passive: true });

/* ---- Mascot: same sparkle as the app, set to a live "playing" mood ----- */
function driveMascot(frame) {
  try {
    const w = frame.contentWindow;
    if (w && w.NotchMascot) w.NotchMascot.setMood('playing', 0.16);
  } catch (_) { /* cross-frame not ready yet; the load handler retries */ }
}
document.querySelectorAll('.mascot-frame').forEach(f => {
  f.addEventListener('load', () => driveMascot(f));
  driveMascot(f);
});

/* ---- Odometer count-up (the Claud-OMETER reading) ---------------------- */
function countUp(el, target, dur = 1200) {
  if (reduce) { el.textContent = target + '%'; return; }
  const start = performance.now();
  (function tick(now) {
    const t = Math.min(1, (now - start) / dur);
    const eased = 1 - Math.pow(1 - t, 3);
    el.textContent = Math.round(eased * target) + '%';
    if (t < 1) requestAnimationFrame(tick);
  })(start);
}

function fillMeter(el) { el.style.width = (el.dataset.fill || 0) + '%'; }
function fireCounts(scope) {
  scope.querySelectorAll('[data-fill]').forEach(fillMeter);
  scope.querySelectorAll('[data-count]').forEach(e => countUp(e, +e.dataset.count));
}

/* ---- Reveals (robust, GSAP-independent) -------------------------------
   IntersectionObserver is reliable and, unlike a scroll listener, fires when a
   full-page capture expands the viewport, so nothing stays hidden. A timeout
   safety net guarantees no section is ever stranded. */
const reveals = document.querySelectorAll('.reveal');
function revealEl(el) { el.classList.add('in'); fireCounts(el); }

if (reduce || !('IntersectionObserver' in window)) {
  reveals.forEach(revealEl);
} else {
  const io = new IntersectionObserver((entries, obs) => {
    entries.forEach(en => { if (en.isIntersecting) { revealEl(en.target); obs.unobserve(en.target); } });
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.05 });
  reveals.forEach(el => io.observe(el));
  setTimeout(() => reveals.forEach(el => { if (!el.classList.contains('in')) revealEl(el); }), 3500);
}

// Hero readings: the copy is visible by default, so just roll the values.
setTimeout(() => fireCounts(document.getElementById('heroPanel')), reduce ? 0 : 550);

// GSAP entrance is purely decorative; the page is fully functional without it.
if (!reduce && window.gsap) {
  gsap.from('.hero-copy > *', { y: 22, opacity: 0, duration: 0.7, ease: 'power3.out', stagger: 0.08, delay: 0.1 });
  gsap.from('#heroPanel', { y: 26, opacity: 0, scale: 0.96, duration: 0.9, ease: 'power3.out', delay: 0.25 });
  gsap.from('.menubar-chip', { y: -10, opacity: 0, duration: 0.6, ease: 'power2.out', delay: 0.75 });
}

/* ---- Changelog from the GitHub Releases API (static fallback in HTML) --- */
(async function loadChangelog() {
  const list = document.getElementById('changelog-list');
  if (!list) return;
  try {
    const res = await fetch('https://api.github.com/repos/byosamah/claudometer/releases');
    if (!res.ok) return;
    const releases = await res.json();
    if (!Array.isArray(releases) || releases.length === 0) return;
    list.innerHTML = releases.slice(0, 6).map(r => {
      const tag = r.tag_name || r.name || '';
      const date = r.published_at
        ? new Date(r.published_at).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' })
        : '';
      return `<div class="release glass"><div class="release-top"><span class="tag">${esc(tag)}</span><span class="date">${esc(date)}</span></div><div class="body">${mdLite(r.body || '')}</div></div>`;
    }).join('');
  } catch (_) { /* offline or rate-limited: keep the static fallback entry */ }
})();

function esc(s) {
  return String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}
// Minimal markdown: turn "- " / "* " lines into a list, other lines into paragraphs.
function mdLite(t) {
  t = t.trim();
  if (!t) return 'See GitHub for the full notes.';
  const lines = esc(t).split('\n');
  let html = '', inList = false;
  for (const ln of lines) {
    if (/^\s*[-*]\s+/.test(ln)) {
      if (!inList) { html += '<ul>'; inList = true; }
      html += '<li>' + ln.replace(/^\s*[-*]\s+/, '') + '</li>';
    } else {
      if (inList) { html += '</ul>'; inList = false; }
      if (ln.trim()) html += '<p>' + ln + '</p>';
    }
  }
  if (inList) html += '</ul>';
  return html;
}

// Vercel Web Analytics: count "Download" clicks as a conversion event (pageviews
// are tracked automatically by /_vercel/insights/script.js). No-ops until Web
// Analytics is enabled for the project; stores no personal data.
for (const a of document.querySelectorAll('a[href*="releases/latest/download"]')) {
  a.addEventListener('click', () => { if (window.va) window.va('event', { name: 'download' }); });
}
