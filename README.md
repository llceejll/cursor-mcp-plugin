# Browserless MCP for Cursor

Headless browser automation for AI agents — scrape, crawl, search, screenshot, and run multi-step research from Cursor.

This repository is the Cursor plugin for the **Browserless MCP server** hosted at [`https://mcp.browserless.io/mcp`](https://mcp.browserless.io/mcp). The server speaks the [Model Context Protocol](https://modelcontextprotocol.io) over streamable HTTP, authenticated with a Bearer token.

---

## Install

### From the Cursor Marketplace (recommended)

1. Open **Cursor Settings → Plugins**.
2. Search for **Browserless**.
3. Click **Install**, then **Authenticate**.
4. Sign in with your Browserless account and approve access.

Or run `/add-plugin browserless` in chat.

Authentication uses OAuth — there is no token to copy, paste, or rotate by hand. Cursor stores the credentials itself; nothing is written into this repository or into `mcp.json`.

No account yet? Sign up at [browserless.io/signup/email](https://www.browserless.io/signup/email).

### Manual install (fallback)

If you are on a Cursor build older than 3.13 or prefer to manage MCP config yourself, add this to `~/.cursor/mcp.json` (global) or `<project>/.cursor/mcp.json` (per-project), using an API token from [account.browserless.io](https://account.browserless.io):

```json
{
  "mcpServers": {
    "browserless": {
      "type": "http",
      "url": "https://mcp.browserless.io/mcp",
      "headers": {
        "Authorization": "Bearer YOUR_BROWSERLESS_TOKEN"
      }
    }
  }
}
```

Restart Cursor, then check **Settings → MCP** — `browserless` should appear with all 14 tools enumerated.

See [docs/install-cursor.md](docs/install-cursor.md) for deeplink installs, project-scoped config, and troubleshooting, and [docs/auth.md](docs/auth.md) for token management.

---

## Tools

The hosted server exposes 14 tools and 2 read-only resources (`browserless://status` and `browserless://api-docs`). Full parameters in [docs/tools.md](docs/tools.md).

**Scrape & extract**

| Tool | What it does |
|---|---|
| `browserless_smartscraper` | Fetch a single URL as `markdown`, `html`, `links`, `screenshot`, or `pdf`. Auto-handles JS and anti-bot. |
| `browserless_crawl` | Recursively crawl and scrape every discovered page. Path filters, sitemap modes, depth control. |
| `browserless_map` | Discover all URLs on a site via sitemap + link extraction, ranked by relevance. |
| `browserless_export` | Return a page's native content (HTML/PDF/image), or bundle page + assets as a ZIP. |
| `browserless_function` | Run arbitrary Puppeteer JS in the cloud. Returns `{ data, type }` with real MIME support. |

**Search**

| Tool | What it does |
|---|---|
| `browserless_search` | Web / news / image search, geo-targetable and time-filterable, with optional per-result scraping. |

**Agent**

| Tool | What it does |
|---|---|
| `browserless_agent` | Stateful browser session — snapshot, click, type, evaluate, scroll, wait. Multi-step automation where the model decides what to do next. |
| `browserless_skill` | Load site-specific recipes and in-house skills on demand (shadow DOM, cookie consent, captchas, file transfers, and more). |

**Audit**

| Tool | What it does |
|---|---|
| `browserless_performance` | Lighthouse audit — accessibility, best-practices, performance, PWA, SEO. Supports custom budgets. |

**Account & diagnostics** — all read-only, scoped to the configured token

| Tool | What it does |
|---|---|
| `browserless_account` | Plan, unit balance, billing period, API key names. Never returns token values. |
| `browserless_usage` | Request and unit consumption over a timeframe. |
| `browserless_logs` | Per-request history for diagnosing failures on the Browserless side. |
| `browserless_sessions` | Running browsers, persistent sessions, recorded replays, credential integrations. |
| `browserless_profiles` | Saved logged-in browser states available to replay. Names and counts only, not cookie values. |

---

## What this plugin can access

Browserless drives real browser sessions, so some tools touch authenticated state. Everything below is scoped to the account behind your credentials.

- **The account tools are read-only.** `browserless_account`, `browserless_usage`, `browserless_logs`, `browserless_sessions`, and `browserless_profiles` only read. `browserless_account` does not return API token values, and `browserless_profiles` returns profile names with cookie and origin counts rather than the cookie values themselves.
- **Session replays.** `browserless_sessions` can list recorded sessions and return one as a self-contained playable recording. A replay reflects what happened in that browser session, so treat recordings of authenticated flows the way you would any other session recording.
- **Saved logins.** `browserless_profiles` lists saved logged-in browser states, which other tools can reuse by passing a profile name. `browserless_sessions` can list configured 1Password credential integrations.
- **Assisted sign-in.** `browserless_skill` provides an `autonomous-login` skill the agent loads when a task requires signing in to a site.

Credentials are managed by Browserless and by Cursor's OAuth store. **This plugin declares no credentials, ships none, and stores none** — it contains only the server URL and metadata.

---

## Example prompts

Drop these straight into Cursor chat once installed:

### 1. Scrape a pricing page

> Use the browserless smart scraper to fetch `https://stripe.com/pricing` as markdown, then summarize each plan in one bullet.

### 2. Multi-step research with the agent

> Use the browserless agent to research the top 3 self-hosted vector databases on GitHub. Set `keepSessionAlive: true` on the first call, then pass the returned `sessionId` on every later call. For each repo, snapshot the README and extract the license, language, and star count. Compare them in a table, then close the session.

### 3. Map and audit a site

> Use `browserless_map` to discover all URLs on `https://example.com`. Then run `browserless_performance` on the top 5 pages by URL depth and report Lighthouse scores.

More examples in [examples/](examples/).

---

## Why this server?

- **Agent loop** (`browserless_agent`) — snapshot/observe/act primitives for multi-step browsing. On MCP server v1.33.0 and later the browser is one-shot unless the first call sets `keepSessionAlive: true` and later calls pass the returned `sessionId`.
- **100+ BrowserQL mutations** under the hood — anti-bot, residential proxy, captcha solving, session replay.
- **Geo-targetable** — country / state / city-level proxying across 10,000+ cities.
- **Built for production** — same backend that powers Browserless's enterprise self-hosted deployments.

---

## Plugin layout

```
.cursor-plugin/plugin.json   Plugin manifest
mcp.json                     MCP server definition
assets/logo.svg              Marketplace logo
docs/                        Install, auth, and tool reference
examples/                    Worked example prompts
scripts/verify-mcp.mjs       Connectivity and tool-discovery check
scripts/build-deeplinks.mjs  Regenerates the manual-install deeplinks
```

To verify the hosted server from the command line:

```bash
BROWSERLESS_TOKEN=your_token node scripts/verify-mcp.mjs
```

---

## Resources

- Hosted server: [`https://mcp.browserless.io/mcp`](https://mcp.browserless.io/mcp)
- Get a token: [browserless.io/signup/email](https://www.browserless.io/signup/email)
- Browserless docs: [docs.browserless.io](https://docs.browserless.io)
- Cursor plugin reference: [cursor.com/docs/reference/plugins](https://cursor.com/docs/reference/plugins)
- MCP spec: [modelcontextprotocol.io](https://modelcontextprotocol.io)

---

## License

MIT — see [LICENSE](LICENSE).

The Browserless server itself is licensed separately under SSPL-1.0.
