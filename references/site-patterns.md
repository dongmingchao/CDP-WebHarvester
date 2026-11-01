# Site Patterns for the CDP Trending Scraper

The scraper (`scripts/cdp_fetch.ps1`) reads only `<a href>` anchors from `document.querySelectorAll('a')` and regex-filters them. Whether it works depends entirely on whether the site exposes item URLs inside real `<a href>` paths. Use this table to pick the right approach before running.

## Decision table

| Site shape | `<a href>` exposes item URL? | Result | Approach |
|---|---|---|---|
| Clean per-item paths (e.g. `/owner/repo`, `/app/12345`, `/listings/uuid`) | Yes | Scraper works | Pick a regex for the path shape, run with `-Max`. |
| Item links with a query string (e.g. `/search?q=x`) | Yes but not clean | Partial | Match the stable prefix before `?`; strip `?query`/`#frag` (already done in the dump). |
| Tracking links (`/ck/a`, `javascript:void(0)`) | No — href is a click tracker; real URL is in the visible text | Fails (`-ShowAll` shows only nav/footer/trackers) | Read card text instead of hrefs, or use an alternate source (RSS/API). |
| JS-rendered cards, no `<a>` at all | No `<a href>` present | Fails (`-ShowAll` shows nav/footer/`void(0)`) | Read card text, or use an alternate source. |

## How to detect the shape cheaply
1. Run once with `-ShowAll`.
2. If output contains real relative paths matching an item shape -> scraper fits; choose the regex.
3. If output contains only `/ck/a`, `javascript:void(0)`, nav/footer, or empty lines -> the site hides item URLs from `<a href>`; do not keep changing the regex. Switch to one of the card-based alternatives below.

## Card-based alternatives (untested by this skill — verify before relying on)
When the site hides URLs in `<a href>`, two directions: read the visible card text, or bypass the DOM entirely.
- Read card text: dump the page's DOM in a way that captures the item text (e.g. iterate the list container's child elements rather than `<a>`), then filter by the site's known item-title pattern. Requires a new dump expression in the scraper or a one-off `Runtime.evaluate`.
- Alternate source: many sites expose a machine-readable feed for the same data — an RSS/Atom feed, a JSON API, or a JSON embedded in the page (e.g. `window.__INITIAL_STATE__`, `application/ld+json`). `curl` or `Runtime.evaluate` on that feed often yields clean data without DOM fragility.

## Notes
- Region affects results regardless of shape: the scraper's host is whatever the browser's network IP resolves to. Bing in particular serves region-specific content; add `cc=CN&setlang=zh-CN` (or the target locale) to the `-Url` to control it. This is a network/geo property, not a skill bug.
