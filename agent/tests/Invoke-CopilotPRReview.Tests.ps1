[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments',
    '',
    Justification = 'The imported functions resolve these test fixtures through PowerShell dynamic scope.'
)]
param()

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
        $functionDefinition = [scriptblock]::Create($_.Extent.Text)
        . $functionDefinition
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
    $NonAsciiDomain = "S$([char]0x00E9)curit$([char]0x00E9)"
    $ComposedDomain = "Caf$([char]0x00E9)"
    $DecomposedDomain = "Cafe$([char]0x0301)"
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

    It 'uses the legacy map when an explicit label is whitespace' {
        $finding = [pscustomobject]@{
            domain = "`t "
            'from-sub-skill' = 'al-security-review'
        }
        Resolve-FindingDomain -Finding $finding | Should -Be 'Security'
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

    It 'preserves the exact Agent label on a cross-cutting producer finding' {
        $json = @{
            outcome = 'completed'
            findings = @(@{
                id = 'agent:cross-cutting'
                domain = 'Agent'
                'from-sub-skill' = 'agent'
                severity = 'major'
                message = 'Issue'
                location = @{ file = 'src/a.al'; line = 1 }
                references = @()
            })
        } | ConvertTo-Json -Depth 8

        $finding = (Parse-BCQualityReport -Output $json).Findings[0]
        $finding.isAgentFinding | Should -BeTrue
        $finding.domain | Should -BeExactly 'Agent'
    }
}

Describe 'Domain metadata' {
    It 'round-trips a multi-word domain through collision-safe metadata' {
        $metadata = Get-AgentDomainMetadata -Domain 'Breaking Changes'
        $parsed = Resolve-CommentDomainIdentity -Body $metadata

        $parsed.Kind | Should -BeExactly 'ExactKey'
        Get-CommentDomainMetadataKey -Body $metadata |
            Should -Be (ConvertTo-DomainMetadataKey -Domain 'Breaking Changes')
    }

    It 'reads legacy single-token metadata' {
        $metadata = '<!-- agent_domain: security -->'
        (Resolve-CommentDomainIdentity -Body $metadata).Kind | Should -BeExactly 'LegacyLabel'
        Get-CommentDomainMetadataKey -Body $metadata |
            Should -Be (ConvertTo-DomainMetadataKey -Domain 'security')
    }

    It 'does not collide special-character or hyphen-equivalent labels' {
        $labels = @(
            'Breaking Changes',
            'API & Web Services',
            'API/Web Services',
            'API',
            'api',
            'API Web Services',
            'API  Web Services',
            'C#',
            'C++',
            '!!!',
            '???',
            'A-B',
            'A B',
            'A_B',
            $NonAsciiDomain,
            $ComposedDomain,
            $DecomposedDomain,
            'Security',
            'security'
        )
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

    It 'matches legacy single-token metadata case-insensitively' {
        Mock Get-ReviewComments {
            @([pscustomobject]@{
                body = '<!-- agent_domain: security -->'
                path = 'src/a.al'
                line = 11
                side = 'RIGHT'
            })
        }

        (Get-ExistingCommentKeys -Domain 'Security').Keys.Contains('src/a.al:11:RIGHT') |
            Should -BeTrue
    }
}

Describe 'Domain grouping and caps' {
    It 'caps exact display-label identities independently' {
        $MaxFindings = 1
        try {
            $json = @{
                outcome = 'completed'
                findings = @(
                    @{
                        id = 'amp-1'; domain = 'API & Web Services'; severity = 'major'; message = 'First'
                        location = @{ file = 'src/a.al'; line = 1 }; references = @()
                    },
                    @{
                        id = 'amp-2'; domain = 'API & Web Services'; severity = 'minor'; message = 'Second'
                        location = @{ file = 'src/a.al'; line = 2 }; references = @()
                    },
                    @{
                        id = 'slash'; domain = 'API/Web Services'; severity = 'minor'; message = 'Third'
                        location = @{ file = 'src/a.al'; line = 3 }; references = @()
                    },
                    @{
                        id = 'upper'; domain = 'Security'; severity = 'minor'; message = 'Fourth'
                        location = @{ file = 'src/a.al'; line = 4 }; references = @()
                    },
                    @{
                        id = 'lower'; domain = 'security'; severity = 'minor'; message = 'Fifth'
                        location = @{ file = 'src/a.al'; line = 5 }; references = @()
                    },
                    @{
                        id = 'unicode'; domain = $NonAsciiDomain; severity = 'minor'; message = 'Sixth'
                        location = @{ file = 'src/a.al'; line = 6 }; references = @()
                    },
                    @{
                        id = 'api-upper'; domain = 'API'; severity = 'minor'; message = 'Seventh'
                        location = @{ file = 'src/a.al'; line = 7 }; references = @()
                    },
                    @{
                        id = 'api-lower'; domain = 'api'; severity = 'minor'; message = 'Eighth'
                        location = @{ file = 'src/a.al'; line = 8 }; references = @()
                    },
                    @{
                        id = 'space-one'; domain = 'API Web Services'; severity = 'minor'; message = 'Ninth'
                        location = @{ file = 'src/a.al'; line = 9 }; references = @()
                    },
                    @{
                        id = 'space-two'; domain = 'API  Web Services'; severity = 'minor'; message = 'Tenth'
                        location = @{ file = 'src/a.al'; line = 10 }; references = @()
                    },
                    @{
                        id = 'composed'; domain = $ComposedDomain; severity = 'minor'; message = 'Eleventh'
                        location = @{ file = 'src/a.al'; line = 11 }; references = @()
                    },
                    @{
                        id = 'decomposed'; domain = $DecomposedDomain; severity = 'minor'; message = 'Twelfth'
                        location = @{ file = 'src/a.al'; line = 12 }; references = @()
                    }
                )
            } | ConvertTo-Json -Depth 8

            $findings = (Parse-BCQualityReport -Output $json).Findings
            $findings.Count | Should -Be 11
            @(Get-OrdinalSortedDomainLabel -Labels $findings.domain) |
                Should -Contain 'API'
            @(Get-OrdinalSortedDomainLabel -Labels $findings.domain) |
                Should -Contain 'api'
            @(Get-OrdinalSortedDomainLabel -Labels $findings.domain) |
                Should -Contain 'API Web Services'
            @(Get-OrdinalSortedDomainLabel -Labels $findings.domain) |
                Should -Contain 'API  Web Services'
            @(Get-OrdinalSortedDomainLabel -Labels $findings.domain) |
                Should -Contain $ComposedDomain
            @(Get-OrdinalSortedDomainLabel -Labels $findings.domain) |
                Should -Contain $DecomposedDomain
            ($findings | Where-Object domain -CEQ 'API & Web Services').severity | Should -Be 'High'
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

    It 'preserves exact case in the empty-message fallback heading' {
        $finding = [pscustomobject]@{
            domain = 'API'
            severity = 'High'
            issue = ''
            recommendation = ''
            suggestedCode = ''
            references = @()
            isAgentFinding = $false
        }

        Build-CommentBody -Finding $finding | Should -Match '(?m)^### High API finding$'
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
