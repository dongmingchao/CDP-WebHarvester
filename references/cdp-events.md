# CDP Navigation-Completion Events (Lightpanda)

Instead of polling `document !== 'undefined'` up to 90s for page-ready, Lightpanda's CDP emits standard `Page.*` events during navigation that let you detect completion precisely. The shipped `cdp_fetch.ps1` now uses this event-driven approach (Option B) as its default: it waits for `Page.loadEventFired`, verifies the page is not a Cloudflare/bot challenge, and reports progress in real time.

## The reliable pattern: `Page.enable` + event stream

Lightpanda in this environment does NOT support `Page.addEventListeners` (returns `-32601 'Page.addEventListeners' wasn't found`) and may never fire `Page.lifecycleEvent`. So use the classic classic-CDP form:

1. `Target.createTarget` (about:blank) → `Target.attachToTarget` with `flatten=true`.
2. Read the attach RESPONSE (not the event) for `sessionId`. When reading, the response body is JSON but Lightpanda appends `System.Threading.Tasks.VoidTaskResult` after it — strip everything from the first `{` and drop that trailing token before `ConvertFrom-Json`.
3. `Page.enable @{}` (this is what enables `Page.*` events in classic CDP).
4. `Page.navigate @{ url }`.
5. Read the raw event stream; an event frame is JSON with a `.method` field and NO `.id`.

Collect these events:

| Event | Meaning |
| --- | --- |
| `Page.frameNavigated` | Reached a new URL (`params.type`, `params.frame.url`). Fires on main-frame navigation. |
| `Page.domContentEventFired` | DOMContentLoaded — faster than load. |
| `Page.loadEventFired` | load event — page load done. |
| `Page.frameStoppedLoading` | Frame stopped loading. |

On fab.com the sequence is: `executionContextsCleared → frameNavigated → domContentEventFired → loadEventFired → frameStoppedLoading`.

`loadEventFired` fires even on a Cloudflare challenge page, so if the site sits behind WAF/cloudflare, verify the frame is the real content page (not a challenge) after the event, or wait for the *last* `loadEventFired`.

## Choosing the readiness trigger

When several events could mean "done", use `Page.loadEventFired` as the gate — NOT `Page.frameStoppedLoading` and NOT `Page.navigatedWithinDocument`.

- `loadEventFired` is a page-level milestone: fires once when the document's resources are all loaded, on both SPA and static pages. Stable, universal, and earlier than the alternatives here.
- `frameStoppedLoading` is a frame-level signal: fires per-frame (and for sub-resource loads), so on multi-frame pages it is not a single "done". On fab.com it actually fires AFTER `loadEventFired`, immediately before the SPA's `navigatedWithinDocument` — so it is neither earlier nor a better "content ready" signal.
- `navigatedWithinDocument` is an SPA client-navigation signal: it fires 0 times (non-SPA) or N times (sort/filter/lazy-load each fire), and its position relative to `loadEventFired` is unordered. The same fab.com page shows two different orderings across runs:
  - `... → navigatedWithinDocument → domContentEventFired → loadEventFired`
  - `... → domContentEventFired → loadEventFired → frameStoppedLoading → navigatedWithinDocument`
  Using it as the gate would fire on the wrong step depending on the run.

The list content on an SPA (like fab.com) is rendered by the follow-up `navigatedWithinDocument`, not by whichever event triggers the read. So correctness is NOT which event you pick — it is the read-back after the trigger: dump anchors, then read `window.evalResult`, and if that fails fall back to diagnostics (`location.href`, anchor count) and abort rather than grabbing an empty page. That read-back is what prevents missing content regardless of event choice.

If a site reliably renders its list only after a final SPA navigation, make the trigger robust by gating on `loadEventFired` (the stable "resources loaded" signal) and waiting a short extra interval if one more `navigatedWithinDocument` arrives (that is the actual render). Do not switch the primary gate to `navigatedWithinDocument` — its 0-or-N, unordered firing makes it the wrong default.

## What does NOT work here

- `Page.addEventListeners` → `-32601 not found`. Do not use the subscribe form.
- `Page.lifecycleEvent` → not observed firing in the probe run; do not depend on it (its `networkIdle`/`loadFired` variants would otherwise be the nicest signal).
- `Page.getFrameTree` → Lightpanda returns an empty page frame.

## Reading event frames (PowerShell 5.1)

```powershell
# wait for a RESPONSE matching id, skipping event frames
function WaitResp($id, $to) {
    $cts = [System.Threading.CancellationTokenSource]::new([timespan]::FromSeconds($to))
    while ($true) {
        try { $r = $ws.ReceiveAsync([ArraySegment[byte]]$buf, $cts.Token).GetAwaiter().GetResult() }
        catch { return $null }
        $ms.SetLength(0); $ms.Write($buf, 0, $r.Count)
        $t = [text.Encoding]::UTF8.GetString($ms.ToArray())
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        $idx = $t.IndexOf('{')
        if ($idx -lt 0) { continue }
        $t = $t.Substring($idx)
        $t = $t -replace 'System\.Threading\.Tasks\.VoidTaskResult\s*$', ''
        try { $o = ConvertFrom-Json $t } catch { continue }
        if ($o.method) { continue }      # event frame — skip
        if ($o.id -eq $id) { return $t }
    }
}
```

`Runtime.evaluate` with `returnByValue` nests at `result.result.value` (two levels), NOT `result.value`.
