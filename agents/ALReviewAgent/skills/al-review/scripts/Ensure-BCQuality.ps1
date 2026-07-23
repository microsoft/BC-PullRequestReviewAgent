<#
.SYNOPSIS
    Ensures the BCQuality knowledge base is cloned/fresh, resolves the local
    reviewer engine (shipped alongside this skill), and prints both paths as
    JSON so the calling agent can invoke the reviewer.

.DESCRIPTION
    Bootstrap step for the al-review skill when it ships INSIDE the
    BC-ALAgents engine repo. Because the engine is co-located with this
    skill, there is nothing to clone for the reviewer itself - only the
    external BCQuality knowledge base is fetched into a local cache and
    fast-forwarded when older than -MaxAgeDays (default 7).

    Output on stdout is a single JSON object:
      { "bcquality": "<path>", "reviewer_script": "<path>" }
    All other output goes to stderr so the JSON stays clean for callers.

.PARAMETER CacheDir
    Root cache directory for the BCQuality checkout. Defaults to
    ~/.copilot/cache/bc-review.

.PARAMETER MaxAgeDays
    If the local BCQuality clone's HEAD commit is older than this many days,
    auto fast-forward. Set to 0 to always update. Set to -1 to never update.

.PARAMETER Force
    Force a fetch + fast-forward regardless of age.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $CacheDir = (Join-Path $env:USERPROFILE '.copilot/cache/bc-review'),
    [int]    $MaxAgeDays = 7,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Log { param([string]$Msg) [Console]::Error.WriteLine("[al-review] $Msg") }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git is required but was not found on PATH."
}

# --- Resolve the local reviewer engine (co-located in this repo) -----------
# Layout: <agent-root>/skills/al-review/scripts/Ensure-BCQuality.ps1
#         <agent-root>/scripts/Invoke-LocalReview.ps1
$agentRoot    = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$reviewerPath = Join-Path $agentRoot 'scripts/Invoke-LocalReview.ps1'
if (-not (Test-Path $reviewerPath)) {
    throw "Reviewer script not found at $reviewerPath. Is this skill running from inside the BC-ALAgents ALReviewAgent tree?"
}

# --- Ensure BCQuality knowledge base is present + fresh ---------------------
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
$bcqPath = Join-Path $CacheDir 'BCQuality'
$bcqUrl  = 'https://github.com/microsoft/BCQuality.git'

if (-not (Test-Path (Join-Path $bcqPath '.git'))) {
    Log "Cloning BCQuality into $bcqPath"
    & git clone --depth 1 $bcqUrl $bcqPath 2>&1 | ForEach-Object { Log $_ }
    if ($LASTEXITCODE -ne 0) { throw "git clone of $bcqUrl failed" }
}
elseif ($MaxAgeDays -lt 0 -and -not $Force) {
    Log "BCQuality: update skipped (MaxAgeDays=$MaxAgeDays)."
}
else {
    $headEpoch = & git -C $bcqPath log -1 --format=%ct 2>$null
    $ageDays = if ($headEpoch) {
        [int](([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$headEpoch) / 86400)
    } else { 9999 }

    if ($Force -or $ageDays -ge $MaxAgeDays) {
        Log "BCQuality: HEAD is $ageDays day(s) old, updating."
        # Refetch + reset is robust for a shallow read-only cache mirror
        # (a plain ff-only pull fails on divergent shallow history).
        & git -C $bcqPath fetch --depth 1 origin HEAD 2>&1 | ForEach-Object { Log $_ }
        if ($LASTEXITCODE -eq 0) {
            & git -C $bcqPath reset --hard FETCH_HEAD 2>&1 | ForEach-Object { Log $_ } | Out-Null
        }
        else {
            Log "BCQuality: fetch failed, using existing clone."
        }
    }
    else {
        Log "BCQuality: up to date ($ageDays day(s) old)."
    }
}

[pscustomobject]@{
    bcquality       = $bcqPath
    reviewer_script = $reviewerPath
} | ConvertTo-Json -Compress
