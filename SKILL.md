---
name: web-trending-cdp
description: Fetch trending web content via CDP with a reusable scraper.
version: 0.3.0
author: 弘, Hermes Agent
license: MIT
platforms: [windows]
metadata:
  hermes:
    tags: [web, cdp, scraping, trending, automation]
    related_skills: []
---

# Web Trending (CDP) Skill

Fetch "today's / trending / hottest" items from a website (e.g. "看看今天 GitHub Trending", "看看 Steam 现在最火的游戏") when the browser tool can only snapshot/click/navigate but cannot return URLs. Method: drive the site through CDP in a dedicated Lightpanda tab, wait for the load event (with bot-detection), then EXTRACT each item card structurally via a per-site CSS selector and report the top N with name + link + description + stars + full URL.

The reusable scraper is `scripts/cdp_fetch.ps1` in this skill's directory (resolve the path via `skill_view`). Only -Url, -CardSelector, and -Max change per site; all CDP boilerplate lives in the shared module `scripts/cdp_core.ps1` (dot-sourced by `cdp_fetch.ps1`).

## When to Use

- User asks for today's / trending / hottest / most-popular items from a site (GitHub Trending, Steam store, product feeds, release lists, etc.).
- The list URLs are hidden behind JavaScript rendering and the browser tool cannot extract them.
- The site renders items as discrete cards you can target with a CSS selector (the scraper grabs the link + description + metadata directly from each card). Works for GitHub Trending, Steam, fab.com.
- fab.com free/newest listing (e.g. https://www.fab.com/search?ui_filter_price=1&is_free=1&sort_by=-firstPublishedAt) is a canonical supported target: use -CardSelector 'a[href^="/listings/"]' (there is NO stable per-card CSS class; every listing anchor is the semantic target). Do NOT treat fab.com as "too site-specific" and reach for ad-hoc scripts instead — the general scraper is the intended tool.
- Don't use for: static pages the browser tool can read directly, sites requiring auth the user did not ask about, OR sites that render lists as JS cards whose links are tracking links (/ck/a) or absent (see Pitfalls).
- For a decision table of which site shapes work vs. need a different approach, see `references/site-patterns.md`.

## Browser tool vs CDP (this environment)

Prefer the CDP scraper over the browser tool for this class of task. In this environment the browser tool auto-closes the page after each assistant reply, so multi-step `browser_console`/`browser_click` chains break mid-session and require re-navigating; the live DOM also sometimes returns empty (body null, zero articles) before rendering. If you must use the browser tool: read the full DOM from the snapshot cache file `~\hermes\cache\web\browser-snapshot-<id>.txt` (the `browser_snapshot` tool saves the truncated output there) via `read_file`, and re-navigate before any continued extraction.

## Prerequisites

- CDP endpoint must be live at `ws://127.0.0.1:9222` (Lightpanda attached). If the script fails to connect, reconnect the browser.
- The site must be reachable without auth.

## How to Run

Canonical invocation through the `terminal` tool (resolve the script path first via `skill_view`):

```
terminal(command="powershell -ExecutionPolicy Bypass -File \"<skill_dir>/scripts/cdp_fetch.ps1\" -Url \"<url>\" -CardSelector \"<css-selector>\" -Max 5", timeout=180)
```

## Procedure

1. Load this skill and read `scripts/cdp_fetch.ps1` to confirm the parameters (now `-Url`, `-CardSelector`, `-Max`).
2. Determine the site URL and the CSS selector for EACH item card (semantic target). Prefer the site's own list URL (many sites expose a direct URL for "trending/hottest/free+newest" without UI clicking). To find the selector, inspect the page's DOM in the browser tool (e.g. DevTools Elements) or, when the browser tool can't reveal it, run once with `-ShowAll` — the output lists every card as `name => path`, so you can eyeball the card structure.
3. Run with `-Url`, `-CardSelector`, `-Max`.
4. Verify: exit code 0 and a JSON block with the expected count. If exit != 0 or the JSON is empty, STOP — do not retry blindly (a failed run leaves no leftover tab thanks to try/finally cleanup, but repeated failures can still overload Lightpanda).

## Quick Reference

- Steam store hottest: `-CardSelector "app-card"`
    - Output format: `{ name: "...", path: "/app/12345678" }`
    - Full URL: `https://store.steampowered.com/app/12345678`
- GitHub Trending: `-CardSelector "article h2 a"`
    - Output format: `{ name: "...", path: "/user/repo" }`
    - Full URL: `https://github.com/user/repo` (host parsed from `-Url`)
- fab.com free+newest: `-CardSelector "a[href^=\"/listings/\"]"`
    - fab.com renders each listing card with a class that mixes stable "fabkit-*" prefixes with a random trailing hash, so there is NO stable per-card selector. Instead target every listing anchor directly: `-CardSelector "a[href^=\"/listings/\"]"`. The scraper's extraction now also handles cards that ARE `<a>` elements (not just containers wrapping links).
    - Output format: `{ name: "...", path: "/listings/uuid" }`
    - Full URL: `https://www.fab.com/listings/uuid` (host parsed from `-Url`)
- Pick the selector: it's the CSS selector for EACH item card (the tag + class/id around a single item). Find it in the page DOM (browser DevTools) or eyeball the `-ShowAll` card list.
- Change count: `-Max 10`.
- Keep full diagnostic output (CDP connect, attach attempts, event/progress output, Runtime.evaluate errors) for troubleshooting a failing run: add -Verbose. This is the PowerShell common parameter (gated off `$VerbosePreference` via `[CmdletBinding()]`); the normal output is unchanged without it.
- Full URLs are built from the host parsed out of `-Url`; never hardcode a domain.

## Pitfalls

- Fixed sleep after navigation is unreliable — the page renders at variable times. The scraper polls `location.href` until the host appears before dumping; do not add a fixed `Start-Sleep` before extraction.
- Lightpanda overloads from leftover tabs. The scraper closes all existing tabs first and guarantees cleanup in `finally`; never run the same script twice in a row to "retry" — investigate the failure first.
- Lightpanda's V8 rejects certain regex literals inside the dump JS (e.g. `/^https?:\\/\\/[^\\/]+/` throws "Invalid regular expression flags"); strip the host via indexOf/split, keep the JS dump regex-free, and do the item pattern match in PowerShell's `-match`. fab.com hrefs are already relative (`/listings/...`).
- `-CardSelector` is mandatory (replacing the old `-LinkPattern`): the scraper targets each card structurally, so there is no URL-pattern regex to guess or anchor. Pick the selector for EACH item card from the page DOM (`-ShowAll` dumps `name => path` per card to eyeball the structure).
- The scraper targets each item card via `-CardSelector` and pulls its link + description + metadata directly. The link is taken from the `<a>` inside the card's first heading, else the first relative `<a>` that is not a login/signup/sponsor/nav action. Sites that render lists as JS cards whose links are tracking links (/ck/a) or absent (e.g. Bing /trending, Bing /news) will yield no usable link — the method does not fit this site; read card text or use a different source. See `references/site-patterns.md`.
- PowerShell 5.1 on Windows: the script uses English-only strings (no BOM). The `norm()` JS that trims/whitespace-collapses card text uses numeric char codes (32/9/10/13) — when patching the `$expr` `@"..."@` here-string, NEVER let a literal carriage return sneak in mid-token (e.g. `if(ch=='\r'){` split into `if(ch=='\r` + CR + `'){`) — that silently breaks the JS and yields zero cards. Verify edits by running the script.
- `Runtime.evaluate` with `returnByValue` nests the result at `result.result.value` (two levels), NOT `result.value`. Reading one level shallow returns empty and looks like "the page never rendered" — the page is fine, only the response parsing was wrong.
- `-Verbose` is a reserved PowerShell common parameter; you cannot declare your own `[switch] $Verbose`. Use `[CmdletBinding()]` on the param block and gate diagnostics off the global `$VerbosePreference`. A stray `:` after a bare variable in a double-quoted string (e.g. `"$p: text"`) is parsed as a drive reference and throws a ParserError — use `${p}` or drop the colon.
- Do NOT use `Page.addScriptToEvaluateOnNewDocument` to collect data from the current page: it only fires on *subsequent* navigations, so on an already-loaded page it runs nothing and the read-back comes back empty — which masquerades as "the page never rendered". Run the extraction script directly via `Runtime.evaluate`, then read the result back.
- Lightpanda HANGS on `Runtime.evaluate` when `returnByValue` serializes a LARGE result (~4KB+ -> times out at 15s; small results work fine). The scraper extracts cards in SLICES (chunks of 6) and concatenates each slice's `result.result.value` — never evaluate the whole list in one call. For a single large card (big description), extract its fields in small pieces rather than one big stringify.
- `-Url` accepts a schemeless host ("fab.com/...", "github.com/trending"); the script prepends `https://` before `[uri]` parsing so `$base` (scheme+authority) is built correctly. Without this, `fullUrl` comes out as ":///...".
- Navigation-completion is now detected via CDP events, not polling (this beats the old fixed sleep / `document !== 'undefined'` poll that failed at variable render times). The shipped script: enables `Page.enable`, then reads the event stream; EITHER `Page.frameNavigated` (reliable, fires on every main-doc nav) OR `Page.loadEventFired` (load done) counts as the readiness trigger, then it enters a settle phase that polls the anchor count until stable (>=2 equal non-zero reads) so it never dumps a half-rendered page. On fab.com the sequence is `executionContextsCleared → frameNavigated → domContentEventFired → loadEventFired → frameStoppedLoading`. Note: `loadEventFired` alone is unreliable on heavy/always-live pages (it may never fire within `-WaitSeconds`), so the shipped script uses frameNavigated OR loadEventFired as the trigger.
    - Option B (default, robust): on `frameNavigated`/`loadEventFired` it verifies the page is NOT a Cloudflare / bot challenge (title/body matching `Just a moment` / `Attention Required` / `Cloudflare`). If a challenge is detected it keeps waiting — the page reloads once the gate clears — and prints a real-time `!! BOT DETECTION ...` report instead of grabbing a challenge page. Progress (each event, plus a heartbeat when idle) is emitted continuously; every event type is surfaced so it can be tuned later. Max wait is `-WaitSeconds` (default 120).
    - This Lightpanda has quirks: `Page.addEventListeners` is NOT supported (returns `-32601 not found`) and `Page.lifecycleEvent` may never fire — use the classic `Page.enable` + event-stream pattern, never the subscribe form. See `references/cdp-events.md`.
- Terminal console output of Chinese is GBK-encoded (MSYS/bash), so Chinese text appears garbled in `terminal` output. The data is intact; it is a display-only issue. To read Chinese correctly, redirect the scraper output to a file in `$TMPDIR`, then decode it with `scripts/fetch_utf8.ps1` (runs the scraper and writes a UTF-8 file you can read plainly). Never re-run the scraper just to "read" the garbled output — capture once and decode the file.

## Verification

- `terminal` returns exit code 0 and prints `OK`.
- The JSON block contains exactly -Max items, each with `name` and `path`.
- Spot-check one URL in the browser tool: it should land on the expected item page.