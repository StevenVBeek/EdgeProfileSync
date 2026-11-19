#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeDiscovery {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ModuleRoot = Join-Path $script:RepoRoot 'EdgeProfileSync'
    $script:PublicNames = @(Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Public') -Filter '*.ps1' | ForEach-Object BaseName | Sort-Object)
    $script:HasScriptAnalyzer = [bool](Get-Module -ListAvailable -Name PSScriptAnalyzer)
}

BeforeAll {
    $script:OriginalHome = $env:EDGEPROFILESYNC_HOME
    $env:EDGEPROFILESYNC_HOME = Join-Path $TestDrive 'localdata'

    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ModuleRoot = Join-Path $script:RepoRoot 'EdgeProfileSync'
    $script:ManifestPath = Join-Path $script:ModuleRoot 'EdgeProfileSync.psd1'
    $script:Module = Import-Module $script:ManifestPath -Force -PassThru -ErrorAction Stop
}

AfterAll {
    $env:EDGEPROFILESYNC_HOME = $script:OriginalHome
    Remove-Module EdgeProfileSync -Force -ErrorAction SilentlyContinue
}

Describe 'Module manifest' {
    It 'is a valid module manifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'requires PowerShell 7.4 (Core edition only)' {
        $manifest = Import-PowerShellDataFile -LiteralPath $script:ManifestPath
        [version]$manifest.PowerShellVersion | Should -BeGreaterOrEqual ([version]'7.4')
        $manifest.CompatiblePSEditions | Should -Be @('Core')
    }

    It 'exports exactly the functions in Public\*.ps1' {
        $manifest = Import-PowerShellDataFile -LiteralPath $script:ManifestPath
        $public = @(Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Public') -Filter '*.ps1' | ForEach-Object BaseName | Sort-Object)
        @($manifest.FunctionsToExport | Sort-Object) | Should -Be $public
    }

    It 'actually exports exactly the public functions after import' {
        $public = @(Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Public') -Filter '*.ps1' | ForEach-Object BaseName | Sort-Object)
        @($script:Module.ExportedFunctions.Keys | Sort-Object) | Should -Be $public
    }

    It 'has a CHANGELOG entry for the module version' {
        $version = (Import-PowerShellDataFile -LiteralPath $script:ManifestPath).ModuleVersion
        Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'CHANGELOG.md') | Should -Match ([regex]::Escape("[$version]"))
    }
}

Describe 'Comment-based help of <_>' -ForEach $script:PublicNames {
    BeforeAll {
        $script:Help = Get-Help -Name $_ -Full -ErrorAction Stop
        $script:Command = Get-Command -Name $_ -Module EdgeProfileSync
    }

    It 'has a synopsis' {
        $synopsis = [string]$script:Help.Synopsis
        $synopsis | Should -Not -BeNullOrEmpty
        # Without comment-based help, PowerShell generates the synopsis from the syntax.
        $synopsis.Trim() | Should -Not -BeLike "$($script:Command.Name) *"
        $synopsis.Trim() | Should -Not -Be $script:Command.Name
    }

    It 'has a description' {
        ($script:Help.Description | Out-String).Trim() | Should -Not -BeNullOrEmpty
    }

    It 'has at least one example' {
        @($script:Help.Examples.Example).Count | Should -BeGreaterThan 0
        ($script:Help.Examples.Example[0].Code | Out-String).Trim() | Should -Not -BeNullOrEmpty
    }
}

Describe 'Source files' {
    It 'every module script parses without errors' {
        $failures = foreach ($file in Get-ChildItem -Path $script:ModuleRoot -Filter '*.ps*1' -Recurse) {
            $tokens = $null; $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            foreach ($e in @($errors)) { "$($file.Name):$($e.Extent.StartLineNumber) $($e.Message)" }
        }
        @($failures) | Should -BeNullOrEmpty
    }

    It 'contains no company or customer names (owner rule)' {
        # Patterns are assembled so this file does not match itself.
        $patterns = @(('\b' + 'D' + 'SC' + '\b'), ('\bDigital' + '\s+' + 'Survival\b'))
        $files = Get-ChildItem -Path $script:RepoRoot -Recurse -File -Force |
            Where-Object { $_.FullName -notmatch '[\\/]\.git([\\/]|$)' } |
            Where-Object { $_.Extension -notin '.zip', '.png', '.ico', '.dll', '.exe' }
        $hits = foreach ($file in $files) {
            foreach ($pattern in $patterns) {
                Select-String -LiteralPath $file.FullName -Pattern $pattern -AllMatches -ErrorAction SilentlyContinue |
                    ForEach-Object { "$($_.Path):$($_.LineNumber): $($_.Line.Trim())" }
            }
        }
        @($hits) | Should -BeNullOrEmpty
    }

}

Describe 'PSScriptAnalyzer' {
    It 'reports no Error-severity findings' -Skip:(-not $script:HasScriptAnalyzer) {
        Import-Module PSScriptAnalyzer -ErrorAction Stop
        $findings = @(Invoke-ScriptAnalyzer -Path $script:ModuleRoot -Recurse -Severity Error)
        $findings | ForEach-Object { "$($_.ScriptName):$($_.Line) $($_.RuleName) $($_.Message)" } | Should -BeNullOrEmpty
    }
}
