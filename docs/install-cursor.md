# Install Browserless MCP in Cursor

## Marketplace install (recommended)

Requires Cursor 3.13 or later.

1. Open **Cursor Settings → Plugins**.
2. Search for **Browserless**.
3. Click **Install**.
4. Click **Authenticate**, sign in with your Browserless account, and approve access.

Or run `/add-plugin browserless` in chat.

The plugin authenticates with OAuth. Cursor registers itself and handles the token exchange — there is no credential to paste and nothing stored in plaintext. The MCP URL stays `https://mcp.browserless.io/mcp`; do not point it at the host root. The 401 `resource_metadata` URL under `/mcp` returns 404, and current MCP clients continue with the host-root authorization server (`https://mcp.browserless.io/.well-known/oauth-authorization-server`). Re-authenticate at any time from **Settings → Plugins → Browserless**. Details are in [docs/auth.md](auth.md).

## Manual install (fallback)

For Cursor builds older than 3.13, or if you prefer to manage MCP config directly, edit `~/.cursor/mcp.json` and paste:

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

Replace `YOUR_BROWSERLESS_TOKEN` with a token from [browserless.io/signup/email](https://www.browserless.io/signup/email). Restart Cursor, then `Settings → MCP` should show `browserless` with all 14 tools.

### One-click deeplink

Cursor's [deeplink format](https://cursor.com/docs/plugins/mcp/install-links) (`cursor://anysphere.cursor-deeplink/mcp/install?name=...&config=...`) pops an in-Cursor confirm dialog with the config pre-filled. Click this in any browser on a machine with Cursor installed:

- **[Install with Bearer token](cursor://anysphere.cursor-deeplink/mcp/install?name=browserless&config=eyJ0eXBlIjoiaHR0cCIsInVybCI6Imh0dHBzOi8vbWNwLmJyb3dzZXJsZXNzLmlvL21jcCIsImhlYWRlcnMiOnsiQXV0aG9yaXphdGlvbiI6IkJlYXJlciBZT1VSX0JST1dTRVJMRVNTX1RPS0VOIn19)** — token comes through as a placeholder; replace it before approving.

Cursor registers the `cursor://` URL handler the first time it launches. If clicking does nothing, open Cursor once and retry.

> Cursor does not publish an HTTPS fallback (e.g. `https://cursor.com/install-mcp`). The `cursor://` scheme is the only supported install link.

Regenerate the deeplink with `node scripts/build-deeplinks.mjs` if the server URL or default config changes.

### Project-scoped install

Place the same JSON at `<project-root>/.cursor/mcp.json` to scope the server to a single project. Project config takes precedence over the global config when both are present.

## Installing from source

To run this plugin from a local checkout — for development, or to test a change before it reaches the Marketplace — copy the repository into Cursor's local plugin directory:

```bash
git clone https://github.com/browserless/cursor-mcp-plugin.git ~/.cursor/plugins/local/browserless
```

Reload Cursor. The plugin appears under **Settings → Plugins** as a local plugin, with the same **Authenticate** button as a Marketplace install. Click it and sign in with your Browserless account.

## Verifying the install

1. Open Cursor → `Settings → MCP`.
2. Find `browserless` in the list. It should show **14 tools** — see [docs/tools.md](tools.md) for the full list.
3. In a chat, ask the model to use one — for example:

   > Use the browserless smart scraper to fetch example.com as markdown.

4. Cursor will prompt for permission to call the tool. Approve, and the result returns inline.

To check the hosted server independently of Cursor:

```bash
BROWSERLESS_TOKEN=your_token node scripts/verify-mcp.mjs
```

This runs the same `initialize` → `tools/list` handshake Cursor performs and prints the advertised tools.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Plugin does not appear in Settings → Plugins | Cursor older than 3.13 | Update Cursor, or use the manual install above. |
| `browserless` shows 0 tools | Not authenticated | Click **Authenticate** under **Settings → Plugins → Browserless**. For manual installs, re-check the `Authorization` header. |
| Authenticate never finishes, or OAuth discovery 404s | The 401 `resource_metadata` URL 404s. Current clients still reach the host-root authorization server; a client that aborts on the 404 does not | Finish **Authenticate** in the browser. Confirm the fallback with `node scripts/verify-mcp.mjs --discover`. The host-root documents are in [docs/auth.md](auth.md). |
| Tools enumerate but every call fails with 401 | Authorization revoked, or token expired | Re-authenticate in **Settings → Plugins → Browserless**, or generate a new token at [account.browserless.io](https://account.browserless.io). |
| Tools enumerate but calls hit `429` | Account quota exceeded | Check usage in your Browserless dashboard; upgrade plan or wait for quota reset. |

## Uninstall

**Settings → Plugins → Browserless → Uninstall**. For manual installs, remove the `browserless` block from `~/.cursor/mcp.json` (or the project-local file) and restart Cursor.
