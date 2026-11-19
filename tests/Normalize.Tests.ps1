BeforeAll {
    $env:EDGEPROFILESYNC_HOME = Join-Path $TestDrive 'home'
    Import-Module (Join-Path $PSScriptRoot '..\EdgeProfileSync\EdgeProfileSync.psd1') -Force
}

Describe 'Get-EdgePreferencesFingerprint' {
    BeforeAll {
        function New-Prefs([string]$Path, [hashtable]$Data) {
            $Data | ConvertTo-Json -Depth 50 -Compress | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
        }
        $script:base = @{
            browser  = @{ show_home_button = $true; window_placement = @{ left = 0; right = 800 } }
            homepage = 'https://example.org'
            profile  = @{
                exit_type             = 'Normal'
                last_engagement_time  = '1'
                content_settings      = @{ exceptions = @{
                        site_engagement = @{ 'https://a.example:443,*' = @{ last_modified = '1'; setting = @{ rawScore = 1.5 } } }
                        notifications   = @{ 'https://b.example:443,*' = @{ last_modified = '1'; setting = 1 } }
                    }
                }
            }
            language_usage_count = @{ en = 3 }
            sessions = @{ event_log = @(@{ time = '1' }) }
        }
    }

    It 'ignores telemetry and bookkeeping changes' {
        InModuleScope EdgeProfileSync -Parameters @{ Base = $script:base; Dir = $TestDrive } {
            param($Base, $Dir)
            $a = Join-Path $Dir 'a.json'; $b = Join-Path $Dir 'b.json'
            $Base | ConvertTo-Json -Depth 50 | Set-Content $a -Encoding utf8NoBOM
            $changed = $Base | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable
            $changed.browser.window_placement.right = 1200
            $changed.profile.exit_type = 'Crashed'
            $changed.profile.last_engagement_time = '2'
            $changed.profile.content_settings.exceptions.site_engagement['https://a.example:443,*'].setting.rawScore = 9
            $changed.profile.content_settings.exceptions.notifications['https://b.example:443,*'].last_modified = '2'
            $changed.language_usage_count.en = 4
            $changed.sessions.event_log += @{ time = '2' }
            $changed | ConvertTo-Json -Depth 50 | Set-Content $b -Encoding utf8NoBOM
            Get-EdgePreferencesFingerprint -Path $b | Should -Be (Get-EdgePreferencesFingerprint -Path $a)
        }
    }

    It 'detects real setting changes' -TestCases @(
        @{ Change = { param($p) $p.homepage = 'https://other.example' } }
        @{ Change = { param($p) $p.browser.show_home_button = $false } }
        @{ Change = { param($p) $p.profile.content_settings.exceptions.notifications['https://b.example:443,*'].setting = 2 } }
    ) {
        InModuleScope EdgeProfileSync -Parameters @{ Base = $script:base; Dir = $TestDrive; Change = $Change } {
            param($Base, $Dir, $Change)
            $a = Join-Path $Dir 'a2.json'; $b = Join-Path $Dir 'b2.json'
            $Base | ConvertTo-Json -Depth 50 | Set-Content $a -Encoding utf8NoBOM
            $changed = $Base | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable
            & $Change $changed
            $changed | ConvertTo-Json -Depth 50 | Set-Content $b -Encoding utf8NoBOM
            Get-EdgePreferencesFingerprint -Path $b | Should -Not -Be (Get-EdgePreferencesFingerprint -Path $a)
        }
    }

    It 'returns $null for a missing file and falls back to the raw hash for invalid JSON' {
        InModuleScope EdgeProfileSync -Parameters @{ Dir = $TestDrive } {
            param($Dir)
            Get-EdgePreferencesFingerprint -Path (Join-Path $Dir 'missing.json') | Should -BeNullOrEmpty
            $bad = Join-Path $Dir 'bad.json'
            Set-Content $bad '{ not json' -Encoding utf8NoBOM
            Get-EdgePreferencesFingerprint -Path $bad | Should -Be (Get-EdgeItemFingerprint -Path $bad)
        }
    }
}
