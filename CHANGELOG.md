# Changelog

All notable changes to this plugin will be documented here.

## Unreleased

- Documented the `browserless_agent` session contract from MCP server v1.33.0: calls are one-shot unless the first call sets `keepSessionAlive: true`, and later calls continue that browser by passing the returned `sessionId`. Updated `docs/tools.md`, `examples/agent-research.md`, and the README prompts that assumed sessions stayed open by default.
- Aligned the tool-set version in `docs/tools.md` with the 1.30.0 reconciliation already recorded in this changelog (it still said 1.28.1).
- Documented the current `browserless_performance` `device` and `config` parameters, marked `browserless_crawl` as a Cloud-plan beta, moved crawl `formats` under `scrapeOptions`, and listed the `scrape-url` and `extract-content` prompts.
- Kept `rawText` in the smart-scraper format list. It is still a server format; the public REST table omits it.
- Named the `browserless_account` actions (`billing`, `keys`) and the `browserless_usage` timeframes (`hour`, `day`, `week`). Clarified that the 14-tool list is the hosted inventory; `browserless_live_url` and the Stripe Link tools exist in browserless-mcp 1.37.1 but are not part of that hosted list.
- Documented OAuth discovery on the host root. The MCP endpoint stays `https://mcp.browserless.io/mcp` (`POST` to the host root 404s). Protected-resource metadata is at `/.well-known/oauth-protected-resource` and `/.well-known/oauth-protected-resource/mcp`. The `resource_metadata` URL advertised on 401 (`/mcp/.well-known/oauth-protected-resource`) returns 404, so clients must not stop there. `scripts/verify-mcp.mjs --discover` checks the root chain without a token.
- Added `patches/browserless-mcp-oauth-resource-metadata.patch`. It rewrites pinned mcp-proxy 6.5.1 so the 401 header uses the host-root metadata URL, without upgrading mcp-proxy (6.7.x breaks the OpenAI hosted importer). The hosted fleet does not include this patch yet.

## 1.0.0 — initial release

- Added the `.cursor-plugin/plugin.json` manifest so the repository installs as a Cursor plugin.
- Added the `browserless` MCP server pointing at `https://mcp.browserless.io/mcp` over streamable HTTP.
- Authenticates with OAuth: Cursor discovers the server's OAuth metadata, registers dynamically, and manages tokens itself. The plugin declares no credentials, and the API token remains documented for manual installs.
- Added `assets/logo.svg`: the Browserless mark on a padded dark tile.
- Added `scripts/verify-mcp.mjs` to check connectivity, tool discovery, and tool execution against the hosted server.
- Documented the two MCP resources the server exposes: `browserless://status` and `browserless://api-docs`.
- Corrected the documented tool set against `browserless-mcp` 1.30.0: 14 tools, not 9. `browserless_download` is no longer served; `browserless_skill`, `browserless_account`, `browserless_usage`, `browserless_logs`, `browserless_sessions`, and `browserless_profiles` were undocumented.
