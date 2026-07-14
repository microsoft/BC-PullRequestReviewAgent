# BC PR Reviewer Agent

An open-source, forkable engine that runs a tool-enabled GitHub Copilot CLI
review over the diff of a Business Central (AL) pull request and posts
structured findings as inline PR comments.

The engine is **mechanism only**. All review *knowledge* — the skills that
decide what to look for and how to report it — lives in
[microsoft/BCQuality](https://github.com/microsoft/BCQuality). Each consuming
repository owns its **policy** (which BCQuality repo/ref/layers/skills to use,
severity thresholds) via a small `bcquality.config.yaml`.

```
Consumer repo (policy)  ──uses──▶  this engine (mechanism)  ──clone+filter──▶  BCQuality (knowledge)
```

## Repository layout

| Path | Purpose |
| --- | --- |
| `agent/scripts/Invoke-CopilotPRReview.ps1` | Orchestrator: checks out the PR head, builds the BCQuality `task-context`, runs the Copilot CLI, parses the findings, renders and posts inline comments + a summary. |
| `agent/scripts/Get-BCQualityConfig.ps1` | Loads `bcquality.config.yaml` and applies environment-variable overrides. |
| `agent/scripts/Invoke-BCQualityFilter.ps1` | Prunes a BCQuality clone on disk per the resolved allow/deny/layers policy. |
| `agent/bcquality.config.yaml` | Default policy baseline. Consumers point at their own copy instead. |
| `.github/workflows/review.yml` | Reusable (`workflow_call`) workflow that wires the whole thing together. |
| `Online Evals/` | Pull-based scoring pipeline for evaluating review quality. |

## Consuming the engine

Add a thin caller workflow to your repository. The recommended pattern uses an
unprivileged `pull_request` intake workflow that saves PR metadata, then a
`workflow_run` workflow that calls this reusable workflow on the trusted base:

```yaml
# .github/workflows/pr-review-runner.yml
name: PR Review Runner
on:
  workflow_run:
    workflows: [PR Review Intake]
    types: [completed]

permissions:
  contents: read
  pull-requests: write
  issues: write
  copilot-requests: write

jobs:
  review:
    if: github.event.workflow_run.conclusion == 'success'
    uses: microsoft/BC-ALReviewAgent/.github/workflows/review.yml@<pinned-sha>
    with:
      target_repo: ${{ github.repository }}
      engine_ref: <pinned-sha>          # keep in sync with the uses: SHA
      config_path: .github/bcquality.config.yaml
```

The engine resolves the PR coordinates from the caller's `workflow_run` payload
automatically. To review a specific PR (e.g. from `workflow_dispatch`), pass
`pr_number`, `head_sha`, and `base_ref` explicitly to bypass resolution.

### Versioning

Engine tags use `X.Y.Z`. `X.Y` comes from the repo-root [`VERSION`](VERSION)
file and identifies the orchestrator contract/implementation; `Z` is the
monotonically increasing BCQuality content minor from
`bcquality.version` in [`agent/bcquality.config.yaml`](agent/bcquality.config.yaml).
After a merge to `main`, `.github/workflows/version.yml` creates an immutable
`X.Y.Z` tag only when that version does not already exist, then force-moves the
floating `latest` tag to the merge commit. A merge that changes neither
`VERSION` nor `bcquality.version` does not publish a new tag or move `latest`.

Consumers may pin an immutable tag for reproducibility or follow `@latest`.
Keep the reusable workflow ref and its `engine_ref` input aligned so both jobs
check out the same engine version.

### Inputs (selected)

| Input | Default | Meaning |
| --- | --- | --- |
| `target_repo` | caller repo | `owner/repo` to review and comment on. |
| `engine_ref` | `main` | Ref of this engine repo to check out for scripts. Pin it. |
| `config_path` | *(empty)* | Path to the consumer's `bcquality.config.yaml`, relative to the target repo root. Empty uses the engine default. |
| `pr_number` / `head_sha` / `base_ref` | *(empty)* | Explicit PR coordinates; bypasses `workflow_run` resolution. |
| `minimum_severity` | `Medium` | Lowest severity to report (`Critical`/`High`/`Medium`/`Low`). |

BCQuality policy (`bcquality_repo`, `bcquality_ref`, `enabled_layers`,
`disabled_skills`, `knowledge_allow`, `knowledge_deny`) and reviewer behaviour
(`copilot_model`, `max_findings_per_domain`, `fail_on_parse_error`, …) can also
be overridden per-input. See `.github/workflows/review.yml` for the full list.

### Domain labels

BCQuality owns each finding's human-readable `domain` label. The orchestrator
prefers a non-empty `findings[].domain` value (and accepts PowerShell's
capitalized `Domain` spelling), then renders and groups that label without
maintaining a duplicate domain taxonomy. For compatibility with older
BCQuality refs, findings without an emitted label fall back to the legacy
`from-sub-skill`/`from_sub_skill` map in `Invoke-CopilotPRReview.ps1`, and
unknown sub-skills fall back to **Other**. Agent findings retain an explicitly
emitted domain; only unlabeled legacy agent findings use the **Agent** fallback.

The shared DO schema keeps `domain` optional for legacy producers, but current
BCQuality review leaves emit a trimmed, single-line, control-free, non-empty
short display label on every finding, including leaf agent findings.
`al-code-review` preserves that optional value verbatim during rollup and does
not derive or overwrite it from `from-sub-skill`; its own cross-cutting findings
use exactly **Agent**.
Accordingly, this consumer never replaces a present non-empty label. It consults
the legacy map, then **Other**, only when the producer label is absent or empty.
After outer whitespace is trimmed, domain identity is otherwise lossless:
internal whitespace, punctuation, case, and Unicode representation remain
significant. New comment metadata encodes those exact UTF-8 bytes; only legacy
single-token metadata and headings use a separate lowercase compatibility path.

### BCQuality dependency and rollout

The reusable workflow accepts three levels of BCQuality configuration:

1. A caller-provided `config_path`, resolved from the target repository.
2. Individual workflow inputs such as `bcquality_repo` and `bcquality_ref`,
   which override the selected config through environment variables.
3. When neither is supplied, the engine-owned
   [`agent/bcquality.config.yaml`](agent/bcquality.config.yaml), whose
   `bcquality.ref` is the reproducible source-of-truth pin.

A BCQuality dependency update changes both `bcquality.ref` to a reviewed commit
and `bcquality.version` to that content release. The latter changes `Z` in the
engine's `X.Y.Z` tag, causing the version workflow to publish the newly vouched
combination and move `latest`.

For additive producer/consumer contract changes, roll out producer-first:

1. Merge and release the BCQuality producer change.
2. Merge and release the backward-compatible engine consumer change.
3. Update `agent/bcquality.config.yaml` to the BCQuality release commit that
   contains the producer change, update `bcquality.version` with it, and verify
   the workflow's resolved `bcquality_sha` plus representative rendered output.

Do not pin the engine to an unmerged BCQuality pull-request commit.

## Security model

* The **review** job is read-only. It runs the tool-enabled Copilot CLI over
  untrusted PR-diff content and therefore never holds a write token.
* The **publish** job holds `issues`/`pull-requests: write` but never runs the
  model; it only posts findings saved as an artifact by the review job.
* Both jobs check out with `persist-credentials: false` so a successful
  prompt-injection cannot exfiltrate a git token from `.git/config`.
* BCQuality is cloned and filtered **before** the model runs. Point
  `bcquality.repo` only at a trusted source and pin `bcquality.ref` to a
  reviewed commit — a compromised fork can embed prompt-injection payloads.

## Running locally / in a benchmark

The orchestrator is entirely environment-variable driven and supports a
single-process mode (`REVIEW_PHASE=all`) that generates and posts in one pass —
used for local development and offline evaluation (e.g. BC-Bench). Provide a
BCQuality checkout via `BCQUALITY_ROOT`, the repo under review via
`REVIEW_WORKSPACE`, and point `BCQUALITY_CONFIG_PATH` at a policy config; then
invoke `agent/scripts/Invoke-CopilotPRReview.ps1`.