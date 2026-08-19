const HTML = "text/html";
const MARKDOWN = "text/markdown";

function parseQuality(value) {
  if (value === undefined) return 1;
  if (!/^(?:0(?:\.\d{0,3})?|1(?:\.0{0,3})?)$/.test(value)) return 0;

  return Number(value);
}

function parseAccept(header) {
  if (!header || !header.trim()) return [];

  return header.split(",").map((entry, order) => {
    const [rawMediaRange, ...rawParameters] = entry.trim().split(";");
    const mediaRange = rawMediaRange.trim().toLowerCase();
    const [type, subtype, extra] = mediaRange.split("/");
    const parameters = Object.fromEntries(
      rawParameters.map((parameter) => {
        const [name, ...value] = parameter.trim().split("=");
        return [name.toLowerCase(), value.join("=").trim().replace(/^"|"$/g, "")];
      }),
    );

    if (!type || !subtype || extra !== undefined) {
      return { mediaRange, quality: 0, specificity: -1, order };
    }

    const specificity = type === "*" ? 0 : subtype === "*" ? 1 : 2;
    return { mediaRange, quality: parseQuality(parameters.q), specificity, order };
  });
}

function qualityFor(entries, mediaType) {
  const [wantedType, wantedSubtype] = mediaType.split("/");
  const matches = entries.filter(({ mediaRange }) => {
    const [type, subtype] = mediaRange.split("/");
    return (type === "*" || type === wantedType) && (subtype === "*" || subtype === wantedSubtype);
  });

  if (matches.length === 0) return { quality: 0, explicit: false };

  matches.sort((left, right) => right.specificity - left.specificity || left.order - right.order);
  const specificity = matches[0].specificity;
  const mostSpecific = matches.filter((entry) => entry.specificity === specificity);
  mostSpecific.sort((left, right) => right.quality - left.quality || left.order - right.order);
  return {
    quality: mostSpecific[0].quality,
    explicit: mostSpecific[0].mediaRange === mediaType,
  };
}

export function selectRepresentation(header) {
  const entries = parseAccept(header);
  if (entries.length === 0) return "html";

  const html = qualityFor(entries, HTML);
  const markdown = qualityFor(entries, MARKDOWN);

  if (html.quality === 0 && markdown.quality === 0) return null;
  if (markdown.explicit && markdown.quality > 0 && markdown.quality >= html.quality) return "markdown";

  return html.quality > 0 ? "html" : null;
}

function representationPaths(pathname) {
  if (pathname.endsWith(".md")) {
    const basename = pathname.slice(0, -3);
    if (basename === "/index") return { html: "/", markdown: pathname, direct: "markdown" };
    if (basename.endsWith("/index")) {
      return { html: `${basename.slice(0, -5)}`, markdown: pathname, direct: "markdown" };
    }

    return { html: `${basename}.html`, markdown: pathname, direct: "markdown" };
  }

  if (pathname === "/") return { html: pathname, markdown: "/index.md" };
  if (pathname.endsWith("/")) {
    return { html: pathname, markdown: `${pathname}index.md` };
  }
  if (pathname.endsWith(".html")) {
    return { html: pathname, markdown: `${pathname.slice(0, -5)}.md` };
  }

  return null;
}

function linkValue(requestUrl, paths, selected) {
  const alternate = selected === "html" ? paths.markdown : paths.html;
  const type = selected === "html" ? MARKDOWN : HTML;
  return `<${new URL(alternate, requestUrl).href}>; rel="alternate"; type="${type}"`;
}

function addVary(headers, name) {
  const names = (headers.get("Vary") || "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);

  if (!names.some((value) => value.toLowerCase() === name.toLowerCase())) names.push(name);
  headers.set("Vary", names.join(", "));
}

async function fetchAsset(context, pathname) {
  const url = new URL(context.request.url);
  url.pathname = pathname;
  url.search = "";
  return context.env.ASSETS.fetch(new Request(url, context.request));
}

export async function onRequest(context) {
  if (context.request.method !== "GET" && context.request.method !== "HEAD") {
    return context.next();
  }

  const requestUrl = new URL(context.request.url);
  const extensionlessDocument =
    (requestUrl.pathname.startsWith("/docs/") || /^\/versions\/[^/]+\/docs\//.test(requestUrl.pathname)) &&
    !requestUrl.pathname.endsWith("/") &&
    !requestUrl.pathname.split("/").at(-1).includes(".");
  if (extensionlessDocument) {
    requestUrl.pathname = `${requestUrl.pathname}.html`;
    return Response.redirect(requestUrl, 308);
  }

  const paths = representationPaths(requestUrl.pathname);
  if (!paths) return context.next();

  const selected = paths.direct || selectRepresentation(context.request.headers.get("Accept"));
  if (!selected) {
    const headers = new Headers({
      Link: [
        `<${new URL(paths.html, requestUrl).href}>; rel="alternate"; type="${HTML}"`,
        `<${new URL(paths.markdown, requestUrl).href}>; rel="alternate"; type="${MARKDOWN}"`,
      ].join(", "),
      Vary: "Accept",
    });
    return new Response(null, { status: 406, headers });
  }

  const selectedPath = paths[selected];
  const assetPath = selected === "html" && selectedPath.endsWith(".html")
    ? selectedPath.slice(0, -5)
    : selectedPath;
  const response = await fetchAsset(context, assetPath);
  const headers = new Headers(response.headers);
  headers.append("Link", linkValue(requestUrl, paths, selected));
  addVary(headers, "Accept");
  if (response.ok) {
    headers.set("Content-Type", `${selected === "markdown" ? MARKDOWN : HTML}; charset=utf-8`);
  }

  return new Response(context.request.method === "HEAD" ? null : response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}
