const DEFAULT_UPSTREAM_ORIGIN = "https://kimono-punch-diving.ngrok-free.dev";

function cleanOrigin(value) {
  return String(value || DEFAULT_UPSTREAM_ORIGIN).replace(/\/+$/, "");
}

function rewriteLocation(location, upstreamOrigin, workerOrigin) {
  if (!location) {
    return location;
  }
  if (location.startsWith(upstreamOrigin)) {
    return workerOrigin + location.slice(upstreamOrigin.length);
  }
  return location;
}

export default {
  async fetch(request, env) {
    const workerUrl = new URL(request.url);
    const upstreamOrigin = cleanOrigin(env.UPSTREAM_ORIGIN);
    const upstreamUrl = new URL(workerUrl.pathname + workerUrl.search, upstreamOrigin);

    const headers = new Headers(request.headers);
    headers.set("ngrok-skip-browser-warning", "true");

    const init = {
      method: request.method,
      headers,
      redirect: "manual",
    };

    if (request.method !== "GET" && request.method !== "HEAD") {
      init.body = request.body;
    }

    const upstreamResponse = await fetch(upstreamUrl, init);
    const responseHeaders = new Headers(upstreamResponse.headers);
    responseHeaders.set("Cache-Control", "no-store");

    const rewrittenLocation = rewriteLocation(
      responseHeaders.get("Location"),
      upstreamOrigin,
      workerUrl.origin,
    );
    if (rewrittenLocation) {
      responseHeaders.set("Location", rewrittenLocation);
    }

    return new Response(upstreamResponse.body, {
      status: upstreamResponse.status,
      statusText: upstreamResponse.statusText,
      headers: responseHeaders,
    });
  },
};
