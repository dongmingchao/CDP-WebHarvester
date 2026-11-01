#Requires -Version 5.1
param([string] $Url = 'fab.com')
. (Join-Path $PSScriptRoot 'cdp_core.ps1')

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

$tid = $null
try {
    $tid = CreateTab
    Write-Output "(+) tabId =[ $tid ]"
    $sid = Attach $tid
    # Write-Host "(+) tabId = $tid"

    SendAndForgot Page.enable $sid
    # SendAndForgot Network.enable $sid
    Send 4 Page.navigate @{ url = $Url } $sid

    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        $raw = ReceiveRaw 3
        Write-Host "(+) ReceiveRaw: $raw"
        if ($raw -eq '[TIMEOUT]') { break }
        try { $o = ConvertFrom-Json $raw } catch { continue }
        if ($o.id -eq 4) {
            if ($o.error) {
                Write-Host "Page.navigate CDP error: $($o.error.message)"
            } elseif ($o.result.errorText) {
                Write-Host "Navigation error: $($o.result.errorText)"
            }
            continue
        }
        if ($o.method -eq 'Network.loadingFailed') {
            $p = $o.params
            Write-Host "Request failed: $($p.errorText); requestId=$($p.requestId); type=$($p.type)"
            if ($p.errorText -match 'SSL|CERT|TLS') {
                Write-Host "TLS/SSL failure detected"
            }
        }
        # if ($o.method -eq 'Page.frameNavigated') { break }
    }
    $explorePath = Join-Path $PSScriptRoot 'explore.js'
    
    $tiny = Get-Content -Raw -Path $explorePath
    # Write-Host "(+) start stage: $tiny"
    $a = Eval $tiny 20
    if ([string]::IsNullOrWhiteSpace($a)) {
        Write-Host "(!!) TEST A hung"
    } else { Write-Host "(+) TEST OK: [$a]" }
    Write-Host "(+) DONE"
    exit 0
} finally { Cleanup }
