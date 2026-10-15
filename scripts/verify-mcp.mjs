#!/usr/bin/env node
// Verifies the hosted Browserless MCP server over streamable HTTP.
//
//   BROWSERLESS_TOKEN=... node scripts/verify-mcp.mjs
//   BROWSERLESS_TOKEN=... node scripts/verify-mcp.mjs --exec
//   BROWSERLESS_TOKEN=... node scripts/verify-mcp.mjs --json > tools.json
//   node scripts/verify-mcp.mjs --discover
//
// Performs the same handshake Cursor performs after the plugin is installed:
// initialize -> notifications/initialized -> tools/list, then prints the
// advertised tools. With --exec, also calls browserless_smartscraper against
// example.com to confirm a tool round-trips. Exits non-zero on any failure.
//
// --discover does not need a token. It follows the same recovery as
// @modelcontextprotocol/sdk 1.32.1: the 401 resource_metadata URL nests
// /.well-known under /mcp and 404s, and the client then uses the origin as
// the authorization server. The protected-resource documents that respond
// are on the origin root.

const URL = process.env.BROWSERLESS_MCP_URL ?? "https://mcp.browserless.io/mcp";
const TOKEN = process.env.BROWSERLESS_TOKEN;
const EXEC = process.argv.includes("--exec");
const JSON_OUT = process.argv.includes("--json");
const DISCOVER = process.argv.includes("--discover");

// RFC 9728 §3.1 inserts the well-known segment between the host and the path.
function protectedResourceMetadataUrl(resource) {
  const url = new globalThis.URL(resource);
  const path = url.pathname === "/" ? "" : url.pathname.replace(/\/$/, "");
  url.pathname = `/.well-known/oauth-protected-resource${path}`;
  url.search = "";
  url.hash = "";
  return url.toString();
}

function authorizationServerMetadataUrl(issuer) {
  const url = new globalThis.URL(issuer);
  const path = url.pathname === "/" ? "" : url.pathname.replace(/\/$/, "");
  url.pathname = `/.well-known/oauth-authorization-server${path}`;
  url.search = "";
  url.hash = "";
  return url.toString();
}

function rootProtectedResourceUrl(resource) {
  const url = new globalThis.URL(resource);
  url.pathname = "/.well-known/oauth-protected-resource";
  url.search = "";
  url.hash = "";
  return url.toString();
}

function originAuthorizationServerUrl(resource) {
  const url = new globalThis.URL(resource);
  url.pathname = "/.well-known/oauth-authorization-server";
  url.search = "";
  url.hash = "";
  return url.toString();
}

async function getStatus(target) {
  const res = await fetch(target, { method: "GET", redirect: "manual" });
  const text = await res.text();
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    body = text.slice(0, 200);
  }
  return { url: target, status: res.status, body };
}

async function discover() {
  const endpoint = new globalThis.URL(URL);
  const probe = await fetch(URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json, text/event-stream",
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2025-06-18",
        capabilities: {},
        clientInfo: { name: "browserless-plugin-verify", version: "1.0.0" },
      },
    }),
  });
  const www = probe.headers.get("www-authenticate") ?? "";
  const advertised = www.match(/resource_metadata="([^"]+)"/)?.[1] ?? null;
  const advertisedResult = advertised ? await getStatus(advertised) : null;
  const inserted = protectedResourceMetadataUrl(endpoint.toString());
  const root = rootProtectedResourceUrl(endpoint.toString());
  const insertedResult = await getStatus(inserted);
  const rootResult = root === inserted ? insertedResult : await getStatus(root);

  const metadata =
    insertedResult.status === 200 && insertedResult.body?.authorization_servers
      ? insertedResult.body
      : rootResult.status === 200 && rootResult.body?.authorization_servers
        ? rootResult.body
        : null;
  const issuer = metadata?.authorization_servers?.[0];
  const authorizationServer = issuer
    ? await getStatus(authorizationServerMetadataUrl(issuer))
    : null;
  const originAsUrl = originAuthorizationServerUrl(endpoint.toString());
  const originAuthorizationServer =
    authorizationServer?.url === originAsUrl
      ? authorizationServer
      : await getStatus(originAsUrl);
  const fallbackAuth =
    originAuthorizationServer?.status === 200 &&
    originAuthorizationServer.body?.authorization_endpoint &&
    originAuthorizationServer.body?.token_endpoint
      ? originAuthorizationServer.body
      : null;
  const resourceIndicator =
    (insertedResult.status === 200 && insertedResult.body?.resource) ||
    (rootResult.status === 200 && rootResult.body?.resource) ||
    null;
  const advertisedOk = advertisedResult?.status === 200;
  // SDK 1.32.1 catches a 404 from an explicit resource_metadata URL and
  // continues with the origin as the authorization server. That path omits
  // protected-resource metadata, so the resource indicator is not sent.
  const sdkCanStart = Boolean(fallbackAuth);

  const report = {
    mcpEndpoint: URL,
    mcpStatus: probe.status,
    advertisedResourceMetadata: advertisedResult,
    hostRootProtectedResource: rootResult,
    pathInsertedProtectedResource: insertedResult,
    authorizationServer,
    sdkFallback: {
      canStartOAuth: sdkCanStart,
      authorizationServer: originAuthorizationServer,
      resourceIndicator: advertisedOk ? resourceIndicator : null,
      resourceIndicatorFromPathInsertion: resourceIndicator,
    },
  };

  if (JSON_OUT) {
    console.log(JSON.stringify(report, null, 2));
  } else {
    console.log(`MCP endpoint ${URL} -> HTTP ${probe.status}`);
    if (advertisedResult) {
      console.log(
        `Advertised resource_metadata -> HTTP ${advertisedResult.status} ${advertisedResult.url}`
      );
    } else {
      console.log("Advertised resource_metadata -> (header missing)");
    }
    console.log(
      `Host-root protected resource -> HTTP ${rootResult.status} ${rootResult.url}`
    );
    if (inserted !== root) {
      console.log(
        `Path-inserted protected resource -> HTTP ${insertedResult.status} ${insertedResult.url}`
      );
    }
    if (originAuthorizationServer) {
      console.log(
        `Authorization server -> HTTP ${originAuthorizationServer.status} ${originAuthorizationServer.url}`
      );
    }
    if (sdkCanStart && advertisedResult && !advertisedOk) {
      console.log(
        `\nSDK fallback can start OAuth. A 404 on the advertised metadata URL is caught; authorization continues at ${fallbackAuth.authorization_endpoint}.`
      );
      if (resourceIndicator) {
        console.log(
          `Path-inserted metadata still carries resource ${resourceIndicator}. Clients that pin the advertised URL drop that indicator.`
        );
      }
    } else if (advertisedOk && sdkCanStart) {
      console.log(
        "\nAdvertised resource_metadata is reachable and the authorization server is up."
      );
    }
  }

  if (!sdkCanStart) {
    console.error("OAuth discovery failed: authorization server metadata is missing.");
    process.exit(1);
  }
}

if (DISCOVER) {
  await discover();
  if (!TOKEN) process.exit(0);
}

if (!TOKEN) {
  console.error("BROWSERLESS_TOKEN is not set.");
  process.exit(1);
}

let sessionId;

async function rpc(method, params, { notification = false } = {}) {
  const body = notification
    ? { jsonrpc: "2.0", method, params }
    : { jsonrpc: "2.0", id: Date.now(), method, params };

  const res = await fetch(URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json, text/event-stream",
      Authorization: `Bearer ${TOKEN}`,
      ...(sessionId ? { "mcp-session-id": sessionId } : {}),
    },
    body: JSON.stringify(body),
  });

  sessionId ??= res.headers.get("mcp-session-id") ?? undefined;

  if (!res.ok) {
    throw new Error(`${method} -> HTTP ${res.status}: ${await res.text()}`);
  }
  if (notification || res.status === 202) return undefined;

  const text = await res.text();
  const payload = res.headers.get("content-type")?.includes("text/event-stream")
    ? text
        .split("\n")
        .filter((line) => line.startsWith("data:"))
        .map((line) => JSON.parse(line.slice(5).trim()))
        .at(-1)
    : JSON.parse(text);

  if (payload?.error) {
    throw new Error(`${method} -> ${payload.error.message}`);
  }
  return payload?.result;
}

const init = await rpc("initialize", {
  protocolVersion: "2025-06-18",
  capabilities: {},
  clientInfo: { name: "browserless-plugin-verify", version: "1.0.0" },
});
const log = JSON_OUT ? () => {} : console.log;

log(
  `Connected to ${init.serverInfo?.name ?? "server"} ${init.serverInfo?.version ?? ""}`.trim()
);

await rpc("notifications/initialized", {}, { notification: true });

const { tools } = await rpc("tools/list", {});

if (JSON_OUT) {
  let resources = [];
  try {
    ({ resources = [] } = (await rpc("resources/list", {})) ?? {});
  } catch {}
  console.log(JSON.stringify({ serverInfo: init.serverInfo, tools, resources }, null, 2));
  process.exit(0);
}

log(`\n${tools.length} tools:`);
for (const tool of tools) log(`  - ${tool.name}`);

// Resources are optional in MCP; a server that does not implement them
// answers with a method-not-found error, which is not a failure here.
try {
  const { resources = [] } = (await rpc("resources/list", {})) ?? {};
  log(`\n${resources.length} resources:`);
  for (const r of resources) log(`  - ${r.uri}${r.name ? `  (${r.name})` : ""}`);
} catch {
  log("\nresources/list not supported by this server.");
}

if (!EXEC) process.exit(0);

const target = "browserless_smartscraper";
if (!tools.some((tool) => tool.name === target)) {
  console.error(`\n${target} not advertised; skipping execution check.`);
  process.exit(1);
}

console.log(`\nCalling ${target} on https://example.com ...`);
const call = await rpc("tools/call", {
  name: target,
  arguments: { url: "https://example.com", formats: ["markdown"] },
});

if (call?.isError) {
  console.error(`${target} returned an error:`);
  console.error(JSON.stringify(call.content, null, 2).slice(0, 800));
  process.exit(1);
}

const preview = (call?.content ?? [])
  .map((part) => part.text ?? `<${part.type}>`)
  .join("\n")
  .trim()
  .slice(0, 300);

console.log(`${target} OK. First 300 chars of result:\n`);
console.log(preview);
