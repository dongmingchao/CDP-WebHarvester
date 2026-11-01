#Requires -Version 5.1
<#
.SYNOPSIS
    Run the CDP trending scraper and write its GBK console output to a UTF-8
    file so Chinese text can be read plainly (terminal display is GBK-encoded).
    Usage:
      powershell -ExecutionPolicy Bypass -File <skill>/scripts/fetch_utf8.ps1 -Url "<url>"
    Output: <skill>/scripts/fetch_utf8_result.txt (UTF-8)
#>

param(
    [Parameter(Mandatory = $true)]
    [string] $Url
)

$ErrorActionPreference = 'Stop'
$SkillDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RawOut   = Join-Path $SkillDir 'fetch_utf8_raw.txt'
$CleanOut = Join-Path $SkillDir 'fetch_utf8_result.txt'

# Run the scraper; capture GBK console output
& "$SkillDir\cdp_fetch.ps1" -Url $Url -LinkPattern 'none' -ShowAll *> $RawOut

# Decode GBK -> UTF-8 (terminal display is GBK; data is intact)
$raw = [System.IO.File]::ReadAllText($RawOut, [System.Text.Encoding]::GetEncoding('GBK'))
[System.IO.File]::WriteAllText($CleanOut, $raw, [System.Text.Encoding]::UTF8)
Write-Output ("WROTE " + $CleanOut)
