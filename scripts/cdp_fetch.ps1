#Requires -Version 5.1
<#
.SYNOPSIS
    Reusable CDP web-content scraper (Lightpanda in a dedicated tab).
    Navigates a URL, waits for the load event via CDP (with bot-detection),
    then EXTRACTS each item card structurally via a per-site CSS selector and
    reports the top N with name + link + description + stars + full URL.

    This replaces the old "dump every <a> and regex-filter by href pattern"
    approach: the scraper now targets the actual item elements (semantic
    targeting), so it grabs the relevant links and their associated text in one
    shot without guessing URL patterns.

.SYNOPSIS-OLD-REPLACED
    Old -LinkPattern / dump-all-anchors is gone. Per-site config is now
    -CardSelector (CSS selector for each item card).

.DESCRIPTION
    Boilerplate (CDP connect, tab mgmt, nav, event-driven readiness, cleanup) is
    site-agnostic; only -Url, -CardSelector and -Max change per site.

.NOTES
    PowerShell 5.1 on Windows: English-only strings, no BOM needed.
    Reliability: minimal CDP sends + try/finally cleanup so a failed run
    never leaves a leftover tab that overloads Lightpanda.
    Pass -Verbose to keep full diagnostic output (connect, attach attempts,
    event/progress output, Runtime.evaluate errors) for troubleshooting failures.
#>

param(
    [CmdletBinding()]
    [Parameter(Mandatory = $true)]
    [string] $Url,

    # CSS selector identifying EACH item card on the page (semantic target).
    # Not required when -Explore: the page structure is dumped so the selector
    # (and target URL) can be picked from the output.
    [string] $CardSelector,

    [int] $Max = 5,

    # Explore mode: do NOT require -CardSelector. Dump the current page's
    # structure (URL query, site-relative links, tag histogram, candidate
    # selectors, form controls) so the target URL + selector can be inferred.
    [switch] $Explore,

    [string] $Title = 'Top results',

    # Dump every extracted card as "name => path" for inspection (no guessing).
    [switch] $ShowAll,

    # Max seconds to wait for a confirmed load event (Option B waits a bit
    # longer and tolerates Cloudflare challenges that reload after solving).
    [int] $WaitSeconds = 120
)

# ---- load the CDP plumbing module (Connect, Send, Wait, Eval, etc.) ----
. (Join-Path $PSScriptRoot 'cdp_core.ps1')

# ---- close all existing tabs ----
for ($round = 1; $round -le 3; $round++) {
    Send 200 Target.getTargets @{}
    $gt = Wait 200 12
    if ($gt -like '*TIMEOUT*') { continue }
    $tabs = (ConvertFrom-Json $gt).result.targetInfo
    $n = 0
    foreach ($t in $tabs) { if ($t.type -ne 'page') { continue }; Send (300 + $n) Target.closeTarget @{ targetId = $t.targetId }; $n++ }
    if ($n -eq 0) { break }
    Start-Sleep -Seconds 2
}

# ---- derive host from URL ----
# Accept schemeless hosts ("fab.com/...", "github.com/trending"): prepend
# https:// so [uri] parses scheme+authority correctly for $base.
if ($Url -notmatch '^[a-z][a-z0-9+.-]*://') { $Url = 'https://' + $Url }
$uri = [uri]$Url
$base = $uri.Scheme + '://' + $uri.Authority + '/'

$tid = $null
try {
    $tid = CreateTab
    $sid = Attach $tid
    Log "(+) tabId = $tid | sessionId = $sid"

    Log "(+) Navigating to: $Url"

    # Enable the Page domain first so Lightpanda pushes standard Page.* events
    # (it does NOT support Page.addEventListeners; classic Page.enable is the way).
    Send 3 Page.enable @{}
    $null = Wait 3 10
    Log "(+) Page domain enabled"

    Send 4 Page.navigate @{ url = $Url }
    $null = Wait 4 20
    $frameId = "session-level"
    Log "(+) Using session-level Runtime.evaluate"

    # ---- event-driven navigation completion (Option B: robust) ----
    # Wait for the load event, but verify the page is NOT a Cloudflare / bot
    # challenge. If a gate is detected we keep waiting (the page reloads once
    # the challenge is solved) and report progress in real time. Every event is
    # surfaced so it can be tuned later.
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $events = @{}
    $loadCount = 0
    $phase = "loading"
    $lastFrameUrl = $null

    while ((Get-Date) -lt $deadline) {
        $raw = ReceiveRaw 3

        if ($raw -eq "[TIMEOUT]") {
            # idle with no events yet: keep reporting progress so output stays live
            # $now = Get-Date
            # if ($now -gt $lastActivity.AddSeconds(15)) {
            #     Report ("  ... " + $phase + " | " + [math]::Round(($now - $start).TotalSeconds, 0) + "s elapsed, still waiting...") DarkYellow
            #     $lastActivity = $now
            # }
            $phase = "settling"
            break
        }
        try { $o = ConvertFrom-Json $raw } catch { continue }

        # navigation / enable responses (carry .id)
        if ($o.id) {
            if ($o.method -eq "Page.navigate" -and $o.result -and $o.result.frameId) {
                Log "(+) Page.navigate -> frame $($o.result.frameId) ($Url)"
            }
            continue
        }

        $m = $o.method
        if (-not $m) { continue }

        $events[$m] = ($events[$m] + 1)
        $ts = if ($o.params.timestamp) { [math]::Round([double]$o.params.timestamp / 1000000, 3) } else { "?" }
        Report ("  > " + $m + " (timestamp=" + $ts + ")") Gray

        if ($m -eq "Page.frameNavigated") {
            $lastFrameUrl = $o.params.frame.url
            Log "(+) frameNavigated: " + $lastFrameUrl
            $title = SendEvalNow "document.title" 1
            $body = SendEvalNow "(function(){var b=document.body;return b?(b.innerText||b.textContent||'').replace(/\s+/g,' ').replace(/\n+/g,' ').trim():''})()" 1
            if ($title -and $title -match 'Just a moment|Attention Required|Cloudflare' -or ($body -and $body -match 'Just a moment|Attention Required|Cloudflare')) {
                Report "!! BOT DETECTION: frameNavigated to a Cloudflare challenge (title=`"$title`"). Gate not cleared - waiting for page reload..." Yellow
            }
        } elseif ($m -eq "Page.domContentEventFired") {
            Log "(+) DOMContentLoaded"
        } elseif ($m -eq "Page.loadEventFired") {
            $loadCount++
            Log "(+) LOAD event #$loadCount"
            # verify the page is NOT a Cloudflare / bot challenge
            $title = SendEvalNow "document.title" 1
            $body = SendEvalNow "(function(){var b=document.body;return b?(b.innerText||b.textContent||'').replace(/\s+/g,' ').replace(/\n+/g,' ').trim():''})()" 1
            if ($title -and $title -match 'Just a moment|Attention Required|Cloudflare' -or ($body -and $body -match 'Just a moment|Attention Required|Cloudflare')) {
                Report "!! BOT DETECTION: page is a Cloudflare challenge (title=`"$title`"). Gate not cleared - waiting for page reload..." Yellow
            } else {
                $phase = "settling"
                break
            }
        } elseif ($m -eq "Page.frameStoppedLoading") {
            Log "(+) frameStoppedLoading"
        } elseif ($m -eq "Runtime.executionContextsCleared") {
            Log "(+) executionContextsCleared"
        } else {
            Log "(+) " + $m
        }
    }

    if ($phase -ne "settling") {
        Write-Host "!! no navigation/load confirmed within " + $WaitSeconds + "s - aborting" -ForegroundColor Red
        if ($events.Count -gt 0) {
            Write-Host "  (events seen: " + ($events | ForEach-Object { $_.Name + "=" + $_.Value } -join ', ') + ")"
        }
        exit 1
    }
    if ($loadCount -gt 0) { Report ("(+) load event #$loadCount; entering settle phase") Green }
    else { Report "(+) navigation confirmed; entering settle phase (waiting for content)" Green }

    # ---- let client-side (SPA) rendering settle before dumping ----
    # loadEventFired fires when the HTML shell loads, but sites like GitHub
    # populate the list AFTER load (via client-side routing). Poll the anchor
    # count until it stabilizes (>=2 consecutive equal, non-zero reads) or a
    # timeout, so we never dump a half-rendered page. fab.com (content ready at
    # load) converges immediately; GitHub waits for its post-load render.
    $settleDeadline = (Get-Date).AddSeconds(10)
    $prevCount = -1
    $stable = 0
    $zeroStreak = 0
    while ((Get-Date) -lt $settleDeadline) {
        $cnt = Eval "(function(){return document.querySelectorAll('a').length;})()"
        if ([string]::IsNullOrWhiteSpace($cnt)) { Start-Sleep -Milliseconds 400; continue }
        $c = [int]$cnt
        if ($c -gt 0) {
            $zeroStreak = 0
            if ($c -eq $prevCount) {
                $stable++
                if ($stable -ge 2) { break }
            } else {
                $stable = 0
                $prevCount = $c
            }
        } else {
            $zeroStreak++
            if ($zeroStreak -ge 6) { break }
        }
        Start-Sleep -Milliseconds 400
    }
    Report ("(+) settled: " + $prevCount + " anchors detected") Gray

    # ---- EXPLORATION MODE: dump page structure so target URL + selector can be picked ----
    # The browser tool cannot return URLs; here we surface the current URL's
    # query, site-relative links, tag histogram, candidate-selector hit counts,
    # and form controls, then stop. Re-run with the target URL + a -CardSelector
    # (or Explore again from a child link).
    if ($Explore) {
        $explorePath = Join-Path $PSScriptRoot 'explore.js'
        if (-not (Test-Path $explorePath)) { Write-Host "!! explore.js not found at " + $explorePath -ForegroundColor Red; exit 1 }
        $exploreSrc = Get-Content -Raw -Path $explorePath
        # Preheat the socket with a trivial eval first: the FIRST Runtime.evaluate
        # right after navigation sometimes hangs on Lightpanda (socket race); a
        # constant eval stabilizes it. Then run explore.js.
        Write-Verbose "(+) EXPLORING page; running explore.js"
        $raw = Eval $exploreSrc 15
        if ([string]::IsNullOrWhiteSpace($raw)) { Write-Host "!! explore eval returned empty - aborting" -ForegroundColor Red; exit 1 }
        try { $exp = ConvertFrom-Json $raw } catch { Write-Host "!! parse explore result failed - raw: [$raw]" -ForegroundColor Red; exit 1 }

        Write-Host "`n=== EXPLORATION ===" -ForegroundColor Cyan
        Write-Host ("  url: " + $exp.url) -ForegroundColor Yellow
        Write-Host ("  --- links (" + $exp.links.Count + ") ---") -ForegroundColor Cyan
        foreach ($l in $exp.links) { Write-Host ("  " + $l.href + "  =>  " + $l.text) }
        Write-Host "  --- tag histogram ---" -ForegroundColor Cyan
        foreach ($t in ($exp.tags.PSObject.Properties | Sort-Object { $_.Value } -Descending)) {
            Write-Host ("  " + $t.Name + " = " + $t.Value)
        }
        Write-Host "  --- candidate selectors ---" -ForegroundColor Cyan
        foreach ($s in $exp.selectors) { Write-Host ("  [" + $s.count + "] " + $s.selector) }
        if ($exp.controls -and $exp.controls.Count -gt 0) {
            Write-Host "  --- form controls ---" -ForegroundColor Cyan
            foreach ($c in $exp.controls) {
                if ($c.options) { Write-Host ("  select#" + $c.id + " [" + $c.name + "] options: " + ($c.options -join ', ')) }
                else { Write-Host ("  " + $c.tag + "#" + $c.id + " [" + $c.name + "] type=" + $c.type + " checked=" + $c.checked) }
            }
        }
        Write-Host "`n  (re-run with the target URL + a -CardSelector, or Explore a child link)" -ForegroundColor Gray
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($CardSelector)) {
        Write-Host "!! -CardSelector is required (or re-run with -Explore to dump the page first)" -ForegroundColor Red
        exit 1
    }

    # ---- extract item cards structurally (semantic targeting) ----
    # Target each item card via -CardSelector and pull its link + description +
    # metadata directly. Chunked for Lightpanda (large return values hang).
    # Per card we grab:
    #   path  - the item link (a link inside the first heading, else the first
    #           relative <a> that is not a login/sponsor/nav action)
    #   name  - that link's text
    #   desc  - the card's description (first <p>)
    #   meta  - the card's metadata line (stars / forks / language)
    # ---- extract items via -CardSelector (simple: selector -> elements ----
    # each matched element's own href (if any) + textContent is the item.
    $selectorAfterEscape = $CardSelector.Replace('`', '\`')
    $CARDCHUNK = 6
    $cardTotal = Eval @"
(function(){
    var c = document.querySelectorAll(``$selectorAfterEscape``);
    return c ? c.length : 0;
})()
"@ 8
    if ([string]::IsNullOrWhiteSpace($cardTotal)) { Write-Host "!! could not count cards for '" + $CardSelector + "' - aborting" -ForegroundColor Red; exit 1 }
    $cardTotal = [int]$cardTotal
    Report ("(+) " + $cardTotal + " item cards found for '" + $CardSelector + "' - extracting") Gray
    $all = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $cardTotal; $i += $CARDCHUNK) {
        $j = [Math]::Min($i + $CARDCHUNK, $cardTotal)
        $expr = @"
(function(){
    function norm(s){ if(!s) return ''; var r=''; for(var k=0;k<s.length;k++){var c=s.charCodeAt(k); if(c===32||c===9||c===10||c===13){ if(r.length>0 && r.charCodeAt(r.length-1)!==32) r+=' '; } else r+=String.fromCharCode(c); } return r.trim(); }
    var cards = document.querySelectorAll(``$selectorAfterEscape``);
    var r=[];
    for (var m=$i; m<$j && m<cards.length; m++){
        var a = cards[m];
        var href = a.getAttribute('href') || a.href || '';
        var isLink = a.tagName && a.tagName.toUpperCase()==='A' && href.indexOf('/')>=0 && href.indexOf('//')<0 && href.indexOf('http')<0;
        r.push({ name: norm(a.textContent), path: isLink ? href : '' });
    }
    return JSON.stringify(r);
})();
"@
        Send 106 Runtime.evaluate @{ expression = $expr; returnByValue = $true }
        $raw = Wait 106 8
        if ($raw -like '*TIMEOUT*' -or -not $raw) {
            Write-Host "!! card chunk starting at $i timed out - aborting" -ForegroundColor Red
            exit 1
        }
        try {
            $env = ConvertFrom-Json $raw
            $slice = $env.result.result.value
            if ($slice -is [string]) { $slice = ConvertFrom-Json $slice }
            foreach ($item in $slice) { $all.Add($item) }
        } catch { Write-Host "!! parse error at card chunk $i - raw: [$raw]" -ForegroundColor Red; exit 1 }
    }

    if ($all.Count -eq 0) {
        Write-Host "!! no cards extracted for selector '" + $CardSelector + "' - aborting" -ForegroundColor Red
        exit 1
    }

    $items = @($all | Select-Object -First $Max | ForEach-Object {
        [PSCustomObject]@{ name = $_.name; path = $_.path; fullUrl = $base + $_.path.TrimStart('/') }
    })

    Write-Host "`n=== $Title ($($items.Count)) ===" -ForegroundColor Cyan
    for ($i = 0; $i -lt $items.Count; $i++) {
        $it = $items[$i]
        Write-Host ("  {0}. {1}  ->  {2}" -f ($i + 1), $it.name, $it.fullUrl)
    }
    Write-Host "`n=== JSON ===" -ForegroundColor Cyan
    Write-Host ($items | ConvertTo-Json -Depth 5)
    Write-Host "OK" -ForegroundColor Green
    exit 0
}
finally {
    Cleanup
}
