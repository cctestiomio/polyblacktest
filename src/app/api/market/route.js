export const runtime = "edge";
export async function GET(request) {
  const { searchParams } = new URL(request.url);
  const slug = searchParams.get("slug");
  if (!slug) return Response.json({ error: "no slug" }, { status: 400 });

  try {
    const url = `https://gamma-api.polymarket.com/markets?slug=${slug}`;
    const res = await fetch(url, { headers: { Accept: "application/json" } });
    const data = await res.json();
    const market = Array.isArray(data) ? data[0] : data;
    if (!market) return Response.json({ error: "not found" }, { status: 404 });

    // Normalise token list
    const tokens = market.tokens ?? market.clobTokenIds ?? [];
    return Response.json({
      slug: market.slug,
      conditionId: market.conditionId,
      question: market.question,
      endDate: market.endDate,
      closed: market.closed,
      tokens,
      outcomes: market.outcomes,
    });
  } catch (e) {
    return Response.json({ error: String(e) }, { status: 500 });
  }
}
