# Browserless MCP — Tool Reference

The hosted server at `https://mcp.browserless.io/mcp` exposes **14 tools** and **2 resources**. The tool set below matches `browserless-mcp` 1.30.0 and the current hosted inventory (14 tools). Session lifetime for `browserless_agent` follows the v1.33.0 contract.

> The authoritative schemas live on the running server — Cursor pulls them via the standard MCP `tools/list` call. Regenerate this list at any time with:
>
> ```bash
> BROWSERLESS_TOKEN=your_token node scripts/verify-mcp.mjs
> ```

| Tool | Group |
|---|---|
| `browserless_smartscraper` | Scrape & extract |
| `browserless_crawl` | Scrape & extract |
| `browserless_map` | Scrape & extract |
| `browserless_export` | Scrape & extract |
| `browserless_function` | Scrape & extract |
| `browserless_search` | Search |
| `browserless_agent` | Agent |
| `browserless_skill` | Agent |
| `browserless_performance` | Audit |
| `browserless_account` | Account & diagnostics |
| `browserless_usage` | Account & diagnostics |
| `browserless_logs` | Account & diagnostics |
| `browserless_sessions` | Account & diagnostics |
| `browserless_profiles` | Account & diagnostics |

---

## Scrape & extract

### `browserless_smartscraper`

Scrape a **single** page. `formats` is one or more of `markdown` (default), `html`, `links`, `screenshot`, and `pdf`. Handles JavaScript-heavy pages and anti-bot measures automatically.

**Key params:** `url` (required), `formats`, `onlyMainContent`, `includeTags` / `excludeTags`, `headers`, `waitFor`, `profile`, `timeout`.

> Use `browserless_smartscraper` on `https://stripe.com/pricing` with `formats: ["markdown"]` and `onlyMainContent: true`.

### `browserless_crawl`

Crawl a site from a seed URL and scrape every discovered page, following links to a configurable depth. Crawl is in beta and only available on Cloud plans.

**Key params:** `url` (required), `limit`, `maxDepth`, `includePaths` / `excludePaths`, `allowSubdomains`, `allowExternalLinks`, `sitemap`, `delay`, `scrapeOptions`, `waitForCompletion`.

> Crawl `https://docs.browserless.io` with `maxDepth: 3`, `limit: 50`, and `scrapeOptions: { formats: ["markdown"] }`.

### `browserless_map`

Discover the URLs on a site via sitemap and link extraction. Use `search` to order results by relevance.

**Key params:** `url` (required), `search`, `limit`, `sitemap`, `includeSubdomains`, `ignoreQueryParameters`.

> Map `https://docs.browserless.io` with `search: "BrowserQL"` and return the top 30 URLs.

### `browserless_export`

Fetch a URL and return its native content (HTML, PDF, image) with auto-detected Content-Type. Set `includeResources: true` to bundle the page plus its CSS/JS/images into a ZIP for offline use.

**Key params:** `url` (required), `includeResources`, `gotoOptions`, `bestAttempt`, `waitForTimeout`, `profile`.

### `browserless_function`

Run custom Puppeteer JavaScript on the Browserless cloud. Your function receives a `page` object and optional `context`, and returns `{ data, type }` where `type` sets the response Content-Type. Real MIME types (`image/png`, `application/pdf`) come back as proper content blocks rather than base64 text.

**Key params:** `code` (required), `context`, `profile`, `timeout`.

---

## Search

### `browserless_search`

Web, news, or image search via SearXNG, with optional per-result scraping. Geo-targetable and time-filterable.

**Key params:** `query` (required), `sources`, `categories`, `country`, `lang`, `location`, `tbs`, `limit`, `scrapeOptions`.

> Search for "self-hosted vector database" with `categories: ["github"]`, then scrape each result as markdown.

---

## Agent

### `browserless_agent`

A reasoning-driven browser session following a ReAct loop: **Reason → Act → Observe**. On MCP server v1.33.0 and later the browser is one-shot unless you opt in. Earlier versions kept the session alive by default.

1. Check for a site recipe via `browserless_skill { site: "<host>" }`
2. `goto` to navigate
3. `snapshot` to observe (returns interactive elements tagged `ref=` for regular CSS, `deep-ref=` for shadow DOM)
4. Act — `click` / `type` / `select` / `evaluate`
5. Re-snapshot if the page changed, then end the session when done

**Selectors come from the snapshot, never from training data.** Use `commands: [...]` to batch sequential actions against the same page state. A `goto` in the same batch can be followed by `snapshot` or `text`; do not reuse selectors from an old snapshot after a navigation.

**Session lifetime (v1.33.0+).** After a successful command batch and download drain, the browser closes and frees its concurrency slot. That is the default when both `sessionId` and `keepSessionAlive` are omitted.

| First call | Later calls | Result |
|---|---|---|
| Omit both | — | One-shot. The browser is gone when the call returns. Passing an id afterward cannot restore it. |
| `keepSessionAlive: true` | Echo the returned `sessionId` | Same browser, cookies, and history. Repeating the flag is unnecessary; the id keeps it alive. |
| `keepSessionAlive: true`, or a returned `sessionId` | `keepSessionAlive: false`, or a `close` command | Force-close, including a session you had kept open. |

`keepSessionAlive` is ignored for profile creation (`createProfile`) and attached sessions (`attachSessionId`). A kept session still ends after 15 minutes idle. If download collection fails, the server keeps the session so you can retry `getDownloads` with the `sessionId` from the error, then close it.

**Key params:** `method`, `params`, `commands`, `sessionId`, `keepSessionAlive`, `profile`, `createProfile`, `proxy`, `record`, `allowedDomains`, `humanlike`, `os`.

### `browserless_skill`

Loads Browserless agent skills on demand, or discovers site-specific recipes tuned for a given host.

- `{ site: "<host>" }` — list recipes for that host, returned as pointers
- `{ id: "<id>" }` — load a skill body, either an in-house skill or a `host/slug` site recipe

In-house skills cover `shadow-dom`, `cookie-consent`, `modals`, `snapshot-misses`, `dynamic-content`, `screenshots`, `vision-fallback`, `tabs`, `autonomous-login`, `captchas`, and `file-transfers`.

---

## Audit

### `browserless_performance`

Run a Lighthouse audit. Returns scores and metrics for accessibility, best-practices, performance, PWA, and SEO. Supports [performance budgets](https://developer.chrome.com/docs/lighthouse/performance/performance-budgets). `device` is `mobile` (the default) or `desktop`. `config` is a Lighthouse config object; `categories` and `device` override the matching keys inside it.

**Key params:** `url` (required), `categories`, `device`, `config`, `budgets`, `timeout`.

> Audits typically take 30s–120s.

---

## Account & diagnostics

These five tools are **read-only** and scoped to the account behind the configured token.

### `browserless_account`

Plan, unit balance, billing period, and the *names* of the account's API keys. Never returns API token values.

**Key params:** `action` (required).

### `browserless_usage`

Request and unit consumption: successes, errors, timeouts, queueing, peak concurrency, captchas, proxy bytes, units.

**Key params:** `timeframe`, `apiKeyIds`.

### `browserless_logs`

Browserless's record of recent requests — what was attempted, whether it failed, why it stopped, how long it took, what it cost. The retention window depends on the account plan.

**Key params:** `startTime` / `endTime`, `requestId`, `url`, `outcome`, `endpoint`, `reason`, `levels`, `cursor`.

### `browserless_sessions`

Inspect running browsers, persistent sessions on dedicated workers, recorded replays, and 1Password credential integrations. Read-only — it never stops a session.

**Key params:** `action` (required — one of `active`, `persistent`, `replays`, `replay`, `integrations`), `sessionId`, `search`.

> `action: "replay"` downloads a recording and returns a self-contained playable rrweb page. Replays capture what happened in the browser, so treat them like any other session recording.

### `browserless_profiles`

List authentication profiles saved for the current token. A profile is a saved logged-in browser state (cookies + storage) replayed by passing its name as `profile` to other tools. Returns profile names plus cookie/origin counts and last-used time — **not** the cookie values themselves.

**Key params:** `limit`, `offset`.

---

## Resources

Alongside its tools, the server exposes two read-only MCP resources. Tools are actions the model calls; resources are content it can read into context. Cursor lists them separately from tools.

| URI | Name | MIME type |
|---|---|---|
| `browserless://status` | Browserless Service Status | `application/json` |
| `browserless://api-docs` | Browserless API Documentation | `text/markdown` |

## Prompts

The server also exposes two prompt templates:

| Name | What it does |
|---|---|
| `scrape-url` | Scrape a page and summarize it |
| `extract-content` | Extract specific information from a page using custom instructions |

Regenerate the tool and resource lists:

```bash
BROWSERLESS_TOKEN=your_token node scripts/verify-mcp.mjs
```
