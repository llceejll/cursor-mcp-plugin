# Authentication

The Browserless MCP server supports two authentication methods. The plugin uses **OAuth**; the API token remains available for manual installs and scripts.

## OAuth (plugin install)

The plugin declares no credentials at all:

```json
{
  "mcpServers": {
    "browserless": {
      "type": "http",
      "url": "https://mcp.browserless.io/mcp"
    }
  }
}
```

The JSON-RPC endpoint stays `https://mcp.browserless.io/mcp`. `POST` to the host root (`https://mcp.browserless.io/`) returns 404, so do not move the server URL there. OAuth discovery is a different path, and it is served from the host root.

Use either of these protected-resource documents. Both return 200 with the same body (`resource` `https://mcp.browserless.io/mcp`, authorization server `https://mcp.browserless.io`, scope `email`):

- `https://mcp.browserless.io/.well-known/oauth-protected-resource`
- `https://mcp.browserless.io/.well-known/oauth-protected-resource/mcp`

Authorization-server metadata is `https://mcp.browserless.io/.well-known/oauth-authorization-server`. Registration, authorize, and token URLs are `/oauth/register`, `/oauth/authorize`, and `/oauth/token` on that same host. The copies nested under `/mcp` return 404.

An unauthenticated `POST` to `/mcp` answers 401 with `resource_metadata="https://mcp.browserless.io/mcp/.well-known/oauth-protected-resource"`. That URL returns 404: mcp-proxy 6.5.1 appends `/.well-known` after `/mcp` instead of inserting it between the host and the path. `@modelcontextprotocol/sdk` 1.32.1 catches that 404 and continues. It treats `https://mcp.browserless.io` as the authorization server and loads `/.well-known/oauth-authorization-server`, which publishes `/oauth/register`, `/oauth/authorize`, and `/oauth/token`. Cursor can open **Authenticate** on that fallback. The failed fetch drops the protected-resource `resource` value (`https://mcp.browserless.io/mcp`), so a client that pinned the advertised URL sends the token request without that indicator. Clients that abort on the 404 still stop. Use the host-root documents above when checking by hand.

The hosted server keeps mcp-proxy at 6.5.1 on purpose. mcp-proxy 6.7.x builds the root URL itself, but it also installs `@modelcontextprotocol/server`, which breaks OpenAI's hosted importer. [`patches/browserless-mcp-oauth-resource-metadata.patch`](../patches/browserless-mcp-oauth-resource-metadata.patch) rewrites the 6.5.1 header in place so it advertises `https://mcp.browserless.io/.well-known/oauth-protected-resource/mcp` (already 200). This plugin cannot deploy that change onto `mcp.browserless.io`.

Check the chain without a token:

```bash
node scripts/verify-mcp.mjs --discover
```

Cursor registers itself from that metadata and shows an **Authenticate** button. Clicking it opens the Browserless consent screen; approve, and Cursor stores the resulting tokens itself.

**No token is ever committed to this repository, pasted into a config file, or written to disk in plaintext.** Tokens refresh automatically and can be revoked from your Browserless account.

Re-authenticate at any time from **Settings → Plugins → Browserless**.

## API token (manual install)

If you configure the server by hand rather than installing the plugin, authenticate with a Bearer token:

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

Generate a token at [account.browserless.io](https://account.browserless.io); sign up at [browserless.io/signup/email](https://www.browserless.io/signup/email). Note that the token sits in `mcp.json` in plaintext — prefer the plugin install if you would rather Cursor manage the credential.

The server also accepts `?token=` as a query parameter, which is convenient for scripts but exposes the token in URLs and logs.

## Rotating credentials

- **OAuth** — revoke the authorization in your Browserless account, then re-authenticate in Cursor.
- **API token** — generate a new token at [account.browserless.io](https://account.browserless.io), replace the value after `Bearer ` in `~/.cursor/mcp.json`, restart Cursor, then revoke the old token.
