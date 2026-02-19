// Polymarket slugs use the START of the 5-minute window, NOT the resolution time.
// e.g. market 9:25-9:30PM ET has slug btc-updown-5m-{9:25PM epoch}
// Resolution happens at slugTimestamp + 300

export function getCurrentSlugTimestamp() {
  const now = Math.floor(Date.now() / 1000);
  return Math.floor(now / 300) * 300;  // START of current window
}

export function getResolutionTs(slugTs) {
  return slugTs + 300;  // market resolves 5 minutes after slug start
}

export function getMarketSlug(slugTs) {
  return `btc-updown-5m-${slugTs}`;
}

export function getSecondsRemaining(slugTs) {
  const resolutionTs = getResolutionTs(slugTs);
  return Math.max(0, resolutionTs - Math.floor(Date.now() / 1000));
}

export function getSecondsElapsed(slugTs) {
  return Math.min(300, 300 - getSecondsRemaining(slugTs));
}

export async function fetchMarketBySlug(slug) {
  try {
    const res = await fetch(`/api/market?slug=${encodeURIComponent(slug)}`);
    if (!res.ok) return null;
    return res.json();
  } catch { return null; }
}

export async function fetchMidpoint(tokenId) {
  if (!tokenId) return null;
  try {
    const res = await fetch(`/api/midpoint?token_id=${encodeURIComponent(tokenId)}`);
    if (!res.ok) return null;
    const data = await res.json();
    const f = parseFloat(data.mid);
    return (isFinite(f) && f > 0.001) ? f : null;
  } catch { return null; }
}

export function resolveTokenIds(market) {
  let upId = null, downId = null;
  const tokens = market.tokens ?? [];
  for (const t of tokens) {
    const o  = (t.outcome ?? "").toLowerCase();
    const id = t.token_id ?? t.tokenId;
    if (!id) continue;
    if (o === "up")   upId   = String(id);
    if (o === "down") downId = String(id);
  }
  if (!upId   && tokens[0]) upId   = String(tokens[0].token_id ?? tokens[0].tokenId ?? tokens[0]);
  if (!downId && tokens[1]) downId = String(tokens[1].token_id ?? tokens[1].tokenId ?? tokens[1]);
  return { upId, downId };
}

export function detectOutcome(up, down) {
  const T = 0.90;
  if (up   != null && up   >= T) return { outcome: "UP",   confident: true };
  if (down != null && down >= T) return { outcome: "DOWN", confident: true };
  if (up   != null && down != null) return { outcome: up > down ? "UP" : "DOWN", confident: false };
  return { outcome: null, confident: false };
}

export async function pollForOutcome(upId, downId, maxAttempts = 20, intervalMs = 3000) {
  for (let i = 0; i < maxAttempts; i++) {
    if (i > 0) await new Promise(r => setTimeout(r, intervalMs));
    const [up, down] = await Promise.all([
      fetchMidpoint(upId),
      downId ? fetchMidpoint(downId) : Promise.resolve(null),
    ]);
    const upP   = up;
    const downP = down ?? (up != null ? parseFloat((1 - up).toFixed(6)) : null);
    const { outcome, confident } = detectOutcome(upP, downP);
    if (confident) return outcome;
  }
  return null;
}
