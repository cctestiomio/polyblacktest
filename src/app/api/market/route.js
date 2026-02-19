export const runtime = "edge";

export async function GET(request) {
  const { searchParams } = new URL(request.url);
  const slug = searchParams.get("slug");
  if (!slug) return Response.json({ error: "no slug" }, { status: 400 });

  try {
    const res = await fetch(
      `https://gamma-api.polymarket.com/markets?slug=${encodeURIComponent(slug)}`,
      { headers: { Accept: "application/json" } }
    );
    const data = await res.json();
    const market = Array.isArray(data) ? data[0] : data;
    if (!market) return Response.json({ error: "not found" }, { status: 404 });

    // Parse clobTokenIds (may be JSON-encoded string)
    let tokenIds = market.clobTokenIds ?? [];
    if (typeof tokenIds === "string") {
      try { tokenIds = JSON.parse(tokenIds); } catch { tokenIds = []; }
    }

    let outcomes = market.outcomes ?? [];
    if (typeof outcomes === "string") {
      try { outcomes = JSON.parse(outcomes); } catch { outcomes = []; }
    }

    // Build tokens array — also grab winner flag from tokens if present
    const rawTokens = market.tokens ?? [];
    const tokens = tokenIds.map((id, i) => {
      const raw = rawTokens.find(t => (t.token_id ?? t.tokenId) === String(id)) ?? {};
      return {
        token_id: String(id),
        outcome:  outcomes[i] ?? raw.outcome ?? (i === 0 ? "Up" : "Down"),
        winner:   raw.winner ?? false,
      };
    });

    // Determine winner from tokens array
    let winner = null;
    for (const t of tokens) {
      if (t.winner === true) { winner = t.outcome; break; }
    }

    return Response.json({
      slug:     market.slug,
      question: market.question,
      endDate:  market.endDate,
      closed:   market.closed ?? false,
      winner,   // "Up" | "Down" | null
      tokens,
      outcomes,
    });
  } catch (e) {
    return Response.json({ error: String(e) }, { status: 500 });
  }
}
