import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { onRequest, selectRepresentation } from "../functions/documentation.js";

test("selects HTML for absent and wildcard-only Accept headers", () => {
  assert.equal(selectRepresentation(null), "html");
  assert.equal(selectRepresentation("*/*"), "html");
  assert.equal(selectRepresentation("text/*"), "html");
});

test("selects explicit Markdown according to quality and ties", () => {
  assert.equal(selectRepresentation("text/markdown"), "markdown");
  assert.equal(selectRepresentation("text/html, text/markdown"), "markdown");
  assert.equal(selectRepresentation("text/html;q=0.8, text/markdown;q=0.9"), "markdown");
  assert.equal(selectRepresentation("text/html;q=0.9, text/markdown;q=0.8"), "html");
  assert.equal(selectRepresentation("text/markdown;q=0.2, text/markdown;q=0.8"), "markdown");
});

test("honors specific exclusions over wildcards", () => {
  assert.equal(selectRepresentation("text/*;q=1, text/markdown;q=0"), "html");
  assert.equal(selectRepresentation("*/*;q=1, text/html;q=0, text/markdown;q=0"), null);
  assert.equal(selectRepresentation("application/json"), null);
  assert.equal(selectRepresentation("text/markdown;q=bogus"), null);
});

function contextFor(path, { accept, method = "GET", assets = new Map() } = {}) {
  const headers = accept === undefined ? undefined : { Accept: accept };
  const request = new Request(`https://preview.example${path}`, { method, headers });
  return {
    request,
    env: {
      ASSETS: {
        fetch: async (assetRequest) => {
          const assetPath = new URL(assetRequest.url).pathname;
          const value = assets.get(assetPath);
          return value === undefined
            ? new Response("missing", { status: 404, headers: { "Content-Type": "text/plain" } })
            : new Response(assetRequest.method === "HEAD" ? null : value, {
                headers: { "Content-Type": "application/octet-stream", ETag: '"asset"' },
              });
        },
      },
    },
    next: async () => new Response("passed through", { status: 209 }),
  };
}

test("serves adjacent Markdown and reciprocal headers", async () => {
  const response = await onRequest(
    contextFor("/docs/getting_started.html?source=test", {
      accept: "text/markdown",
      assets: new Map([["/docs/getting_started.md", "# Getting started"]]),
    }),
  );

  assert.equal(response.status, 200);
  assert.equal(await response.text(), "# Getting started");
  assert.equal(response.headers.get("Content-Type"), "text/markdown; charset=utf-8");
  assert.equal(
    response.headers.get("Link"),
    '<https://preview.example/docs/getting_started.html>; rel="alternate"; type="text/html"',
  );
  assert.equal(response.headers.get("Vary"), "Accept");
  assert.equal(response.headers.get("ETag"), '"asset"');
});

test("direct Markdown is stable regardless of Accept", async () => {
  const response = await onRequest(
    contextFor("/docs/index.md", {
      accept: "text/html",
      assets: new Map([["/docs/index.md", "# Documentation"]]),
    }),
  );

  assert.equal(await response.text(), "# Documentation");
  assert.equal(response.headers.get("Content-Type"), "text/markdown; charset=utf-8");
  assert.equal(
    response.headers.get("Link"),
    '<https://preview.example/docs/>; rel="alternate"; type="text/html"',
  );
});

test("serves HTML by default with a Markdown alternate", async () => {
  const response = await onRequest(
    contextFor("/", { assets: new Map([["/", "<!doctype html>"]]) }),
  );

  assert.equal(await response.text(), "<!doctype html>");
  assert.equal(response.headers.get("Content-Type"), "text/html; charset=utf-8");
  assert.equal(
    response.headers.get("Link"),
    '<https://preview.example/index.md>; rel="alternate"; type="text/markdown"',
  );
});

test("loads HTML assets through Cloudflare's extensionless static route", async () => {
  const response = await onRequest(
    contextFor("/docs/getting_started.html", {
      assets: new Map([["/docs/getting_started", "<!doctype html>"]]),
    }),
  );

  assert.equal(response.status, 200);
  assert.equal(await response.text(), "<!doctype html>");
});

test("returns 406 with both available representations", async () => {
  const response = await onRequest(contextFor("/docs/", { accept: "application/json" }));

  assert.equal(response.status, 406);
  assert.equal(response.headers.get("Vary"), "Accept");
  assert.match(response.headers.get("Link"), /docs\/>; rel="alternate"; type="text\/html"/);
  assert.match(response.headers.get("Link"), /docs\/index\.md>; rel="alternate"; type="text\/markdown"/);
});

test("HEAD returns headers without a response body", async () => {
  const response = await onRequest(
    contextFor("/versions/1.0/docs/Agent.html", {
      accept: "text/markdown",
      method: "HEAD",
      assets: new Map([["/versions/1.0/docs/Agent.md", "ignored"]]),
    }),
  );

  assert.equal(response.status, 200);
  assert.equal(response.body, null);
  assert.equal(response.headers.get("Content-Type"), "text/markdown; charset=utf-8");
});

test("passes non-document routes and unsupported methods through", async () => {
  assert.equal((await onRequest(contextFor("/docs/search_index.js"))).status, 209);
  assert.equal((await onRequest(contextFor("/docs/", { method: "POST" }))).status, 209);
});

test("passes through asset 404 status", async () => {
  const response = await onRequest(contextFor("/docs/missing.html", { accept: "text/markdown" }));

  assert.equal(response.status, 404);
  assert.equal(response.headers.get("Content-Type"), "text/plain");
});

test("redirects Cloudflare extensionless document aliases to canonical HTML routes", async () => {
  for (const path of ["/docs/getting_started", "/versions/1.0/docs/LittleGhost/Agent"]) {
    const response = await onRequest(contextFor(`${path}?source=alias`));

    assert.equal(response.status, 308);
    assert.equal(response.headers.get("Location"), `https://preview.example${path}.html?source=alias`);
  }
});

test("preserves existing Link and Vary response metadata", async () => {
  const context = contextFor("/docs/");
  context.env.ASSETS.fetch = async () =>
    new Response("docs", {
      headers: {
        Link: '<https://cdn.example/style.css>; rel="preload"',
        Vary: "Origin",
      },
    });

  const response = await onRequest(context);
  assert.match(response.headers.get("Link"), /rel="preload"/);
  assert.match(response.headers.get("Link"), /rel="alternate"/);
  assert.equal(response.headers.get("Vary"), "Origin, Accept");
});

test("route configuration excludes static assets from function invocations", async () => {
  const routes = JSON.parse(await readFile(new URL("../functions/_routes.json", import.meta.url)));

  assert.deepEqual(routes.include.slice(0, 2), ["/", "/index.md"]);
  assert.ok(routes.exclude.includes("/assets/*"));
  assert.ok(routes.exclude.includes("/docs/js/*"));
  assert.ok(routes.exclude.includes("/versions/*/docs/js/*"));
});
