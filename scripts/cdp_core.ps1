<#
.SYNOPSIS
    Reusable CDP plumbing for the web-trending-cdp skill.

    Provides the site-agnostic boilerplate: connect to the Lightpanda CDP
    endpoint, the Send/Wait/SendEvalNow helpers, CreateTab/Attach,
    Eval/ExecuteOnFrame, AddScriptOnLoad, and Cleanup. Dot-source this file
    from cdp_fetch.ps1 (the per-site entry point); do NOT run it directly.

.NOTES
    PowerShell 5.1 on Windows: English-only strings, no BOM needed.
    Shared socket state ($ws, $buf, $ms) is module-level; the caller owns
    the try/finally cleanup so a failed run never leaves a leftover tab.
    Pass -Verbose to keep full diagnostic output (connect, attach attempts,
    event/progress output, Runtime.evaluate errors) for troubleshooting.
#>

# ---- diagnostic logging: only emitted when -Verbose is set ----
function Log($msg) {
    if ($VerbosePreference -eq 'Continue') { Write-Host $msg -ForegroundColor DarkGray }
}

# ---- progress / event reporting: ALWAYS emitted (real-time feedback) ----
function Report($msg, $color = 'Gray') {
    Write-Host $msg -ForegroundColor $color
}

$ErrorActionPreference = 'Stop'
$script:ForgotRequestId = 400

# ---- CDP plumbing ----
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$null = $ws.ConnectAsync([uri]"ws://127.0.0.1:9222", [Threading.CancellationToken]::None).GetAwaiter().GetResult()
$buf = [byte[]](1..65536 | ForEach-Object { 0 })
$script:ReceiveTask = $null
$script:ReceiveMessageStream = New-Object System.IO.MemoryStream
Log "(+) CDP connected to ws://127.0.0.1:9222"

function Send([int]$id, $method, $params, $sessionId = $null) {
    $o = [ordered]@{ id = $id; method = $method }
    if ($null -ne $params) { $o['params'] = $params }
    if ($sessionId) { $o['sessionId'] = $sessionId }
    $j = $o | ConvertTo-Json -Depth 20 -Compress
    Write-Verbose "(+) Send: $j"
    $b = [text.Encoding]::UTF8.GetBytes($j)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $null = $ws.SendAsync([ArraySegment[byte]]$b, [System.Net.WebSockets.WebSocketMessageType]::Text, $true,
                [Threading.CancellationToken]::None).GetAwaiter().GetResult()
            return
        } catch { Start-Sleep -Milliseconds 300 }
    }
}

# Keep the underlying receive alive when a caller's wait period expires.
# Cancelling ReceiveAsync can abort ClientWebSocket and make it unusable.
function ReceiveRaw($timeout) {
    $deadline = [DateTime]::UtcNow.AddSeconds($timeout)
    while ($true) {
        if ($null -eq $script:ReceiveTask) {
            $script:ReceiveTask = $ws.ReceiveAsync(
                [ArraySegment[byte]]$buf,
                [Threading.CancellationToken]::None
            )
        }

        $remaining = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        Write-Verbose "(+) ReceiveRaw: waiting for $remaining ms"
        if (-not $script:ReceiveTask.Wait($remaining)) { return '[TIMEOUT]' }

        $result = $script:ReceiveTask.GetAwaiter().GetResult()
        $script:ReceiveTask = $null
        if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
            throw "CDP WebSocket closed by peer: $($result.CloseStatus) $($result.CloseStatusDescription)"
        }
        $script:ReceiveMessageStream.Write($buf, 0, $result.Count)
        if (-not $result.EndOfMessage) { continue }

        $text = [text.Encoding]::UTF8.GetString($script:ReceiveMessageStream.ToArray())
        $script:ReceiveMessageStream.SetLength(0)
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        $idx = $text.IndexOf('{')
        if ($idx -lt 0) { continue }
        return ($text.Substring($idx) -replace 'System\.Threading\.Tasks\.VoidTaskResult\s*$', '')
    }
}

function Wait($id, $timeout) {
    while ($true) {
        $t = ReceiveRaw $timeout
        if ($t -eq '[TIMEOUT]') { return "[TIMEOUT ${timeout}s]" }
        try { $o = ConvertFrom-Json $t } catch { continue }
        Write-Verbose "(+) Wait: $t"
        if ($o.method) { continue }
        if ($o.id -eq $id) { return $t }
    }
}

function SendAndForgot($method, $sessionId = $null, $timeout = 1) {
    $script:ForgotRequestId += 1
    Send $script:ForgotRequestId $method @{} $sessionId
    $response = Wait $script:ForgotRequestId $timeout
    if ($response -like '*TIMEOUT*') { throw "$method timed out waiting for CDP response" }
    $result = ConvertFrom-Json $response
    if ($result.error) { throw "$method failed: $($result.error.message)" }
}

# Send a Runtime.evaluate and read ONLY its response from the socket
# (skipping events), so it can run INSIDE the event loop which shares the
# same socket. Returns the evaluated value or $null on timeout/error.
function SendEvalNow($expr, $to) {
    Send 202 Runtime.evaluate @{ expression = $expr; returnByValue = $true }
    while ($true) {
        $t = ReceiveRaw $to
        if ($t -eq '[TIMEOUT]') { return $null }
        try { $o = ConvertFrom-Json $t } catch { continue }
        if ($o.method) { continue }
        if ($o.id -eq 202) {
            if ($o.error) { return $null }
            return $o.result.result.value
        }
    }
}
function CreateTab() {
    for ($retry = 1; $retry -le 4; $retry++) {
        Send 100 Target.createTarget @{ url = "about:blank" }
        $resp = Wait 100 20
        $tid = (ConvertFrom-Json $resp).result.targetId
        Write-Host "(+) CreateTab try $retry -> tabId=$tid"
        if ([string]::IsNullOrWhiteSpace($tid)) { Start-Sleep -Seconds 2; continue }
        return $tid
    }
    throw "createTarget failed"
}
function Attach($tid) {
    # First try direct attach (retry: Lightpanda socket is flaky)
    for ($attempt = 1; $attempt -le 8; $attempt++) {
        Send 101 Target.attachToTarget @{ targetId = $tid; flatten = $true }
        $r = Wait 101 15
        if ($r -like '*TIMEOUT*') { Log "(+) attach try ${attempt} TIMEOUT"; Start-Sleep -Milliseconds 400; continue }
        $o = $null
        try { $o = ConvertFrom-Json $r } catch {}
        if ($o -and $o.result.sessionId) { Log "(+) attach ok (try $attempt) -> sessionId=$($o.result.sessionId)"; return $o.result.sessionId }
        Start-Sleep -Milliseconds 600
    }
    throw "Failed to attach to tab $tid after 8 attempts"
}
function Eval($expr, $timeout = 30) {
    # Try Runtime.evaluate first (returnByValue mode)
    Send 102 Runtime.evaluate @{ expression = $expr; returnByValue = $true }
    $r = Wait 102 $timeout
    Write-Verbose "(+) Eval: $expr -> $r"
    if ($r -like '*TIMEOUT*') { Write-Host "!! Eval TIMEOUT after ${timeout}s" -ForegroundColor Yellow; return $null }
    $o = ConvertFrom-Json $r
    if ($o.error) { Write-Host "!! Runtime.evaluate error: $($o.error.message)" -ForegroundColor Red; return $null }
    # Runtime.evaluate (returnByValue) nests the value at result.result.value
    return $o.result.result.value
}

# Function to execute script on a specific frame
function ExecuteOnFrame($frameId, $expr, $timeout = 15) {
    # Lightpanda lacks Page.executeScript; use Runtime.evaluate (frameId scopes it)
    $params = @{ expression = $expr; returnByValue = $true }
    if ($frameId -ne 'session-level') { $params['frameId'] = $frameId }
    Send 102 Runtime.evaluate $params
    $r = Wait 102 $timeout
    if ($r -like '*TIMEOUT*') { return $null }
    $o = ConvertFrom-Json $r
    if ($o.error) { Log "!! Runtime.evaluate error: $($o.error.message)" -ForegroundColor Red; return $null }
    return $o.result.result.value
}

function AddScriptOnLoad($expr) {
    Send 102 Page.addScriptToEvaluateOnNewDocument @{ source = $expr }
    Wait 102 10
}

function Cleanup() {
    try { if ($tid) { Send 5 Target.closeTarget @{ targetId = $tid } } } catch {}
    Start-Sleep -Milliseconds 500
    try { $ws.Dispose() } catch {}
}
