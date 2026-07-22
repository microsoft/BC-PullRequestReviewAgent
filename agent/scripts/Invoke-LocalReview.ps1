<#
.SYNOPSIS
    One-shot local (offline) AL code review for CLI/benchmark consumers.

.DESCRIPTION
    Self-contained entry point that wraps the three review building blocks so a
    consumer can run the *exact* production review over a local worktree with a
    single call, without reimplementing the reusable workflow's fetch/filter
    orchestration:

      1. Get-BCQualityConfig.ps1   - resolve the BCQuality repo + ref (honours
                                     the BCQUALITY_* env overrides). The ref is
                                     pinned by this engine version, so the review
                                     knowledge stays aligned with the engine tag.
      2. git init/fetch/checkout   - clone the resolved BCQuality ref (branch,
                                     tag, or SHA) into a local root.
      3. Invoke-BCQualityFilter.ps1 - prune the clone to the enabled layers.
      4. Invoke-CopilotPRReview.ps1 - run the review in REVIEW_SOURCE=local mode
                                     against the worktree diff, emitting
                                     al-code-review-findings.json into -OutputDir.

    This is the same sequence the reusable review workflow performs inline; it
    is factored here so both the workflow and non-GitHub consumers share one
    code path.

.PARAMETER Workspace
    Path to the AL repository worktree to review. Its diff against -BaseRef is
    what gets reviewed.

.PARAMETER BaseRef
    Git ref the worktree diff is computed against (e.g. a base commit SHA).

.PARAMETER OutputDir
    Directory the review writes al-code-review-findings.json (and other review
    output) into. Created if missing.

.PARAMETER Model
    Copilot model passed to the reviewer (e.g. claude-sonnet-4.6).

.PARAMETER BCQualityRepo
    Optional override for the BCQuality repository (maps to BCQUALITY_REPO).

.PARAMETER BCQualityRef
    Optional override for the BCQuality ref (maps to BCQUALITY_REF).

.PARAMETER ConfigPath
    Optional path to a bcquality.config.yaml; defaults to the engine baseline.

.PARAMETER BaseBranch
    Base branch name recorded in the review context. Defaults to 'main'.

.PARAMETER Repository
    Repository slug recorded in the review context. Defaults to 'local/review'.

.OUTPUTS
    Writes the resolved BCQuality SHA to stdout on the final line.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Workspace,
    [Parameter(Mandatory)][string] $BaseRef,
    [Parameter(Mandatory)][string] $OutputDir,
    [string] $Model,
    [string] $BCQualityRepo,
    [string] $BCQualityRef,
    [string] $ConfigPath,
    [string] $BaseBranch = 'main',
    [string] $Repository = 'local/review'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot

# BCQUALITY_* env overrides are how Get-BCQualityConfig accepts operator changes;
# surface the script parameters through the same channel so callers need not set
# environment themselves.
if (-not [string]::IsNullOrWhiteSpace($BCQualityRepo)) { $env:BCQUALITY_REPO = $BCQualityRepo }
if (-not [string]::IsNullOrWhiteSpace($BCQualityRef)) { $env:BCQUALITY_REF = $BCQualityRef }

# 1. Resolve config (repo + ref pinned by this engine version).
$cfg = & (Join-Path $scriptDir 'Get-BCQualityConfig.ps1') -ConfigPath $ConfigPath
$repo = $cfg.bcquality.repo
$ref = $cfg.bcquality.ref

$bcqualityRoot = Join-Path $OutputDir 'bcquality'
New-Item -ItemType Directory -Force -Path $bcqualityRoot | Out-Null

# 2. Fetch the resolved ref (init + fetch + checkout so ref may be branch/tag/SHA;
#    `git clone --branch` does not accept raw commit SHAs).
Write-Host "Fetching BCQuality from $repo@$ref into $bcqualityRoot"
git -C $bcqualityRoot init -q
git -C $bcqualityRoot remote add origin $repo
git -C $bcqualityRoot fetch --depth=1 origin "$ref"
if ($LASTEXITCODE -ne 0) { throw "git fetch of BCQuality ref '$ref' failed (exit $LASTEXITCODE)" }
git -C $bcqualityRoot checkout -q FETCH_HEAD
if ($LASTEXITCODE -ne 0) { throw "git checkout of BCQuality ref '$ref' failed (exit $LASTEXITCODE)" }
$resolvedSha = (& git -C $bcqualityRoot rev-parse HEAD).Trim()
Write-Host "BCQuality resolved SHA: $resolvedSha"

# 3. Filter the clone to the enabled layers.
& (Join-Path $scriptDir 'Invoke-BCQualityFilter.ps1') -BCQualityRoot $bcqualityRoot -Config $cfg | Out-Null

$reviewOutputDir = Join-Path $OutputDir 'review-output'
New-Item -ItemType Directory -Force -Path $reviewOutputDir | Out-Null

# 4. Run the reviewer in local mode against the worktree diff.
$env:REVIEW_SOURCE = 'local'
$env:REVIEW_PHASE = 'all'
$env:BASE_REF = $BaseRef
$env:BASE_BRANCH = $BaseBranch
$env:REVIEW_WORKSPACE = $Workspace
$env:REVIEW_TARGET_WORKSPACE = $Workspace
$env:REVIEW_OUTPUT_DIR = $reviewOutputDir
$env:BCQUALITY_ROOT = $bcqualityRoot
$env:BCQUALITY_SHA = $resolvedSha
$env:GITHUB_REPOSITORY = $Repository
if (-not [string]::IsNullOrWhiteSpace($Model)) { $env:COPILOT_MODEL = $Model }

& (Join-Path $scriptDir 'Invoke-CopilotPRReview.ps1')
if ($LASTEXITCODE -ne 0) { throw "Invoke-CopilotPRReview.ps1 failed (exit $LASTEXITCODE)" }

Write-Output $resolvedSha
