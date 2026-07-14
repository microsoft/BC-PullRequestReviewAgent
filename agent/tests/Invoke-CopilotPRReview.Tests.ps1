BeforeAll {
    $scriptPath = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts') 'Invoke-CopilotPRReview.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        throw ($parseErrors | ForEach-Object Message | Out-String)
    }

    $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | ForEach-Object {
        Invoke-Expression $_.Extent.Text
    }

    $DomainMap = @{
        'al-security-review'    = 'Security'
        'al-performance-review' = 'Performance'
        'agent'                 = 'Agent'
    }
    $SeverityOrder = @{ Critical = 0; High = 1; Medium = 2; Low = 3 }
    $BCQualitySeverityMap = @{ blocker = 'Critical'; major = 'High'; minor = 'Medium'; info = 'Low' }
    $MinimumSeverity = 'Low'
    $AgentMinimumSeverity = 'Low'
    $MaxFindings = 25
    $script:LastParsingErrors = [System.Collections.Generic.List[string]]::new()

    $AgentVersion = '1'
    $AgentLabel = 'copilot-pr-review'
    $ReviewIteration = 2
    $AgentCommentDocUrl = 'https://example.test/review'
    $BCQualitySha = ''
    $script:BCQualityWebRepoUrl = 'https://github.com/microsoft/BCQuality'
}

Describe 'Resolve-FindingDomain' {
    It 'prefers the explicit lowercase domain over the legacy map' {
        $finding = [pscustomobject]@{
            domain = 'Breaking Changes'
            'from-sub-skill' = 'al-security-review'
        }
        Resolve-FindingDomain -Finding $finding | Should -Be 'Breaking Changes'
    }

    It 'accepts the capitalized Domain property' {
        Resolve-FindingDomain -Finding ([pscustomobject]@{ Domain = 'Web Services' }) |
            Should -Be 'Web Services'
    }

    It 'uses from-sub-skill and from_sub_skill legacy fallbacks' {
        Resolve-FindingDomain -Finding ([pscustomobject]@{ 'from-sub-skill' = 'al-security-review' }) |
            Should -Be 'Security'
        Resolve-FindingDomain -Finding ([pscustomobject]@{ from_sub_skill = 'al-performance-review' }) |
            Should -Be 'Performance'
    }

    It 'falls back safely for missing and unusable labels' -ForEach @(
        @{ Explicit = $null }
        @{ Explicit = '' }
        @{ Explicit = '   ' }
    ) {
        $finding = [pscustomobject]@{ domain = $Explicit; 'from-sub-skill' = 'unknown-review' }
        Resolve-FindingDomain -Finding $finding | Should -Be 'Other'
    }
}

Describe 'Agent domain normalization' {
    It 'preserves an explicit leaf domain for an agent finding' {
        $json = @{
            outcome = 'completed'
            findings = @(@{
                id = 'agent:security'
                domain = 'Security'
                'from-sub-skill' = 'al-security-review'
                severity = 'major'
                message = 'Issue'
                location = @{ file = 'src/a.al'; line = 1 }
                references = @()
            })
        } | ConvertTo-Json -Depth 8

        $finding = (Parse-BCQualityReport -Output $json).Findings[0]
        $finding.isAgentFinding | Should -BeTrue
        $finding.domain | Should -Be 'Security'
    }

    It 'uses Agent only for an unlabeled legacy agent finding without a mapped domain' {
        $json = @{
            outcome = 'completed'
            findings = @(@{
                id = 'legacy'
                knowledge_backed = $false
                severity = 'major'
                message = 'Issue'
                location = @{ file = 'src/a.al'; line = 1 }
                references = @()
            })
        } | ConvertTo-Json -Depth 8

        (Parse-BCQualityReport -Output $json).Findings[0].domain | Should -Be 'Agent'
    }
}

Describe 'Domain metadata' {
    It 'round-trips a multi-word domain through collision-safe metadata' {
        $metadata = Get-AgentDomainMetadata -Domain 'Breaking Changes'
        Get-CommentDomainMetadataKey -Body $metadata |
            Should -Be (ConvertTo-DomainMetadataKey -Domain 'Breaking Changes')
    }

    It 'reads legacy single-token metadata' {
        Get-CommentDomainMetadataKey -Body '<!-- agent_domain: security -->' |
            Should -Be (ConvertTo-DomainMetadataKey -Domain 'Security')
    }

    It 'does not collide special-character or hyphen-equivalent labels' {
        $labels = @('C#', 'C++', '!!!', '???', 'A-B', 'A B', 'A_B', 'Æ', 'AE')
        $keys = @($labels | ForEach-Object { ConvertTo-DomainMetadataKey -Domain $_ })
        ($keys | Select-Object -Unique).Count | Should -Be $labels.Count
    }

    It 'uses metadata to deduplicate only the matching domain across iterations' {
        Mock Get-ReviewComments {
            @([pscustomobject]@{
                body = Get-AgentDomainMetadata -Domain 'Breaking Changes'
                path = 'src/a.al'
                line = 10
                side = 'RIGHT'
            })
        }

        (Get-ExistingCommentKeys -Domain 'Breaking Changes').Keys.Contains('src/a.al:10:RIGHT') |
            Should -BeTrue
        (Get-ExistingCommentKeys -Domain 'Breaking-Changes').Keys.Count |
            Should -Be 0
    }
}

Describe 'Domain grouping and caps' {
    It 'caps distinct special-character domains independently' {
        $MaxFindings = 1
        try {
            $json = @{
                outcome = 'completed'
                findings = @(
                    @{
                        id = 'csharp-1'; domain = 'C#'; severity = 'major'; message = 'First'
                        location = @{ file = 'src/a.al'; line = 1 }; references = @()
                    },
                    @{
                        id = 'csharp-2'; domain = 'C#'; severity = 'minor'; message = 'Second'
                        location = @{ file = 'src/a.al'; line = 2 }; references = @()
                    },
                    @{
                        id = 'cplusplus'; domain = 'C++'; severity = 'minor'; message = 'Third'
                        location = @{ file = 'src/a.al'; line = 3 }; references = @()
                    }
                )
            } | ConvertTo-Json -Depth 8

            $findings = (Parse-BCQualityReport -Output $json).Findings
            $findings.Count | Should -Be 2
            @($findings.domain | Sort-Object) | Should -Be @('C#', 'C++')
            ($findings | Where-Object domain -eq 'C#').severity | Should -Be 'High'
        }
        finally {
            $MaxFindings = 25
        }
    }
}

Describe 'Domain rendering safety' {
    It 'escapes domain labels in LaTeX comment preheaders' {
        $finding = [pscustomobject]@{
            domain = 'API | 100%_safe & C#'
            severity = 'High'
            issue = 'Use the safe API.'
            recommendation = ''
            suggestedCode = ''
            references = @()
            isAgentFinding = $false
        }
        $body = Build-CommentBody -Finding $finding

        $body | Should -Match '100\\%\\_safe'
        $body | Should -Match '\\&'
        $body | Should -Match 'C\\#'
        $body | Should -Not -Match '<!-- agent_domain:'
    }

    It 'escapes markdown table separators, formatting, and HTML' {
        $summary = @{
            'API | 100%_safe & <test>' = @{
                findings = 1; knowledgeBacked = 1; agentFindings = 0; inline = 1; fallback = 0
            }
        }
        $body = Build-SummaryBody -Outcome completed -OutcomeReason '' -DomainSummary $summary `
            -Suppressed @() -SkippedSubSkills @() -FilterReport $null

        $body | Should -Match 'API \\\| 100%\\_safe &amp; &lt;test&gt;'
    }
}
