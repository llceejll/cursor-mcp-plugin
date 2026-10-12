# Example — Multi-step research with `browserless_agent`

Demonstrates a kept-alive agent loop: navigate → snapshot → act → re-snapshot → close. The first call has to opt in with `keepSessionAlive: true`; later calls continue it with `sessionId`.

## Prompt

> Use `browserless_agent` to research the top 3 self-hosted vector databases. On the first call set `keepSessionAlive: true`. On every later call pass the `sessionId` from the previous result, and do not start a new browser. When the table is done, `close` the session (or send `keepSessionAlive: false`).
>
> Steps:
>
> 1. `goto` `https://github.com/search?q=vector+database+self-hosted&type=repositories&s=stars&o=desc`.
> 2. `snapshot` the page.
> 3. From the snapshot, identify the first 3 repository links and `goto` the first one.
> 4. On each repo page: `snapshot`, then extract the **language**, **license**, **star count**, and the first paragraph of the README.
> 5. After the third repo, `close` the session.
> 6. Return a comparison table (Name, Stars, Language, License, One-line summary).

## Why this works

- MCP server v1.33.0 and later closes the browser after each call unless the first call sets `keepSessionAlive: true`. Later calls continue that browser by passing the returned `sessionId` (the flag does not need to be repeated). Cookies, redirects, and rate-limit state then persist across `goto` calls. Omitting the id starts a new browser; it does not resume one that already closed.
- `snapshot` returns interactive elements with `ref=` selectors, so the model never has to guess CSS selectors from training data.
- `close`, or `keepSessionAlive: false` on a continued call, releases the browser slot. A kept session that is never closed sits idle until the 15-minute timeout.

## Tips

- **Always snapshot after a navigation.** A `goto` invalidates the prior snapshot.
- **Batch actions that share page state** with the `commands` array. A `goto` can be followed by `snapshot` or `text` in the same batch. Do not reuse selectors from before that navigation; take a fresh snapshot first.
- **Cookie banners are usually shadow DOM.** Look for `deep-ref=` selectors in the snapshot — pass them verbatim, including the leading `< `.

## Expected behavior

Multi-step prompts like this typically run in 30–90 seconds and consume more units than a one-shot scrape. While the kept session is open, a failed step can `snapshot` again and retry in the same browser. If the first call omitted `keepSessionAlive`, that browser is already closed and the run has to start over.
