// Subpath-proxy Worker template for culture.dev/<subpath>/* sites.
//
// Two placeholders — SUBPATH and UPSTREAM (both double-underscored in
// this file to make sed substitution unambiguous). See
// references/subpath-site-pattern.md for the render-and-deploy recipe.
//
// Do NOT put literal example sed commands in this header — this file
// is itself processed by sed, so any example substitution patterns
// get rewritten in the output and become nonsense to a reader of the
// rendered worker.
//
// Derived from the live `agex-proxy` Worker fetched via the CF API —
// behavior matched line-for-line (path guard, upstream strip, manual
// redirect follow, same-origin Location rewrite).

const UPSTREAM = "__UPSTREAM__";
// Parse once so the same-origin check below is tolerant of trailing
// slashes / paths in the rendered UPSTREAM string — we only care
// about the scheme+host+port triple, not the full URL.
const UPSTREAM_ORIGIN = new URL(UPSTREAM).origin;

export default {
  async fetch(request) {
    const incomingUrl = new URL(request.url);

    // Only handle /__SUBPATH__ and /__SUBPATH__/*
    if (
      incomingUrl.pathname !== "/__SUBPATH__" &&
      !incomingUrl.pathname.startsWith("/__SUBPATH__/")
    ) {
      return fetch(request);
    }

    // Strip /__SUBPATH__ before hitting upstream — upstream serves at root.
    const upstreamPath = incomingUrl.pathname.replace(/^\/__SUBPATH__/, "") || "/";
    const upstreamUrl = new URL(upstreamPath + incomingUrl.search, UPSTREAM);

    const headers = new Headers(request.headers);
    headers.delete("host");

    const upstreamRequest = new Request(upstreamUrl.toString(), {
      method: request.method,
      headers,
      body: request.method === "GET" || request.method === "HEAD" ? undefined : request.body,
      redirect: "manual",
    });

    const response = await fetch(upstreamRequest);

    // Rewrite upstream same-origin redirect Location back under /__SUBPATH__/*.
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      if (location) {
        const locationUrl = new URL(location, upstreamUrl);
        if (locationUrl.origin === UPSTREAM_ORIGIN) {
          const rewritten = new URL(request.url);
          rewritten.pathname = "/__SUBPATH__" + locationUrl.pathname;
          rewritten.search = locationUrl.search;
          rewritten.hash = locationUrl.hash;

          const outHeaders = new Headers(response.headers);
          outHeaders.set("location", rewritten.toString());

          return new Response(response.body, {
            status: response.status,
            statusText: response.statusText,
            headers: outHeaders,
          });
        }
      }
    }

    return response;
  },
};
