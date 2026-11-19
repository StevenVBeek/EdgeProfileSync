#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $script:OriginalHome = $env:EDGEPROFILESYNC_HOME
    $script:OriginalOneDrive = $env:OneDrive
    $script:OriginalOneDriveCommercial = $env:OneDriveCommercial
    $env:EDGEPROFILESYNC_HOME = Join-Path $TestDrive 'localdata'

    $manifest = Join-Path $PSScriptRoot '..\EdgeProfileSync\EdgeProfileSync.psd1'
    Import-Module $manifest -Force -ErrorAction Stop
}

AfterAll {
    $env:EDGEPROFILESYNC_HOME = $script:OriginalHome
    $env:OneDrive = $script:OriginalOneDrive
    $env:OneDriveCommercial = $script:OriginalOneDriveCommercial
    Remove-Module EdgeProfileSync -Force -ErrorAction SilentlyContinue
}

Describe 'Get-EdgeProfileSyncConfig' {
    BeforeEach {
        $env:EDGEPROFILESYNC_HOME = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:OneDriveCommercial = $null
        $env:OneDrive = $null
    }

    It 'stores its data under EDGEPROFILESYNC_HOME (never the real profile)' {
        (Get-EdgeProfileSyncConfig).ConfigPath | Should -Be (Join-Path $env:EDGEPROFILESYNC_HOME 'config.json')
    }

    It 'returns defaults when no config file exists' {
        $config = Get-EdgeProfileSyncConfig
        $config.Channels | Should -Be @('Stable')
        $expected = InModuleScope EdgeProfileSync { @(Get-EdgeDataCategory -DefaultOnly | ForEach-Object Name) }
        $config.Categories | Should -Be $expected
        $config.Categories | Should -Contain 'Bookmarks'
        $config.Categories | Should -Not -Contain 'Autofill'
        $config.IncludeProfiles.Count | Should -Be 0
        $config.ExcludeProfiles.Count | Should -Be 0
        $config.ArchiveRetention | Should -Be 10
        $config.CloseBackgroundEdge | Should -BeTrue
        $config.IncludeProtectedProfiles | Should -BeFalse
        $config.IntervalMinutes | Should -Be 30
        $config.SyncRoot | Should -BeNullOrEmpty
    }

    It 'defaults SyncRoot to OneDrive for Business before personal OneDrive' {
        $env:OneDrive = 'C:\Users\me\OneDrive'
        (Get-EdgeProfileSyncConfig).SyncRoot | Should -Be 'C:\Users\me\OneDrive\EdgeProfileSync'
        $env:OneDriveCommercial = 'C:\Users\me\OneDrive - Contoso'
        (Get-EdgeProfileSyncConfig).SyncRoot | Should -Be 'C:\Users\me\OneDrive - Contoso\EdgeProfileSync'
    }

    It 'merges the config file over the defaults' {
        $null = New-Item -ItemType Directory -Path $env:EDGEPROFILESYNC_HOME -Force
        '{"Channels":["Beta"],"intervalminutes":15,"Unknown":1}' |
            Set-Content -LiteralPath (Join-Path $env:EDGEPROFILESYNC_HOME 'config.json')
        $config = Get-EdgeProfileSyncConfig
        $config.Channels | Should -Be @('Beta')
        $config.IntervalMinutes | Should -Be 15
        $config.ArchiveRetention | Should -Be 10
        $config.PSObject.Properties.Name | Should -Not -Contain 'Unknown'
    }

    It 'falls back to defaults with a warning when the file is corrupt' {
        $null = New-Item -ItemType Directory -Path $env:EDGEPROFILESYNC_HOME -Force
        'this is { not json' | Set-Content -LiteralPath (Join-Path $env:EDGEPROFILESYNC_HOME 'config.json')
        $config = Get-EdgeProfileSyncConfig -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings | Should -Not -BeNullOrEmpty
        $config.IntervalMinutes | Should -Be 30
    }
}

Describe 'Set-EdgeProfileSyncConfig' {
    BeforeEach {
        $env:EDGEPROFILESYNC_HOME = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:OneDriveCommercial = $null
        $env:OneDrive = $null
    }

    It 'writes values that Get-EdgeProfileSyncConfig reads back' {
        $root = Join-Path $TestDrive 'sync-a'
        Set-EdgeProfileSyncConfig -SyncRoot $root -Channels Stable, Beta -IncludeProfiles 'Personal' -ExcludeProfiles 'Work*' `
            -ArchiveRetention 3 -CloseBackgroundEdge $false -IntervalMinutes 60
        $config = Get-EdgeProfileSyncConfig
        $config.SyncRoot | Should -Be $root
        $config.Channels | Should -Be @('Stable', 'Beta')
        $config.IncludeProfiles | Should -Be @('Personal')
        $config.ExcludeProfiles | Should -Be @('Work*')
        $config.ArchiveRetention | Should -Be 3
        $config.CloseBackgroundEdge | Should -BeFalse
        $config.IntervalMinutes | Should -Be 60
    }

    It 'round-trips IncludeProtectedProfiles (default off)' {
        (Get-EdgeProfileSyncConfig).IncludeProtectedProfiles | Should -BeFalse
        Set-EdgeProfileSyncConfig -IncludeProtectedProfiles $true
        (Get-EdgeProfileSyncConfig).IncludeProtectedProfiles | Should -BeTrue
        $json = Get-Content -Raw -LiteralPath (Join-Path $env:EDGEPROFILESYNC_HOME 'config.json') | ConvertFrom-Json -AsHashtable
        $json['IncludeProtectedProfiles'] | Should -BeTrue
        Set-EdgeProfileSyncConfig -IncludeProtectedProfiles $false
        (Get-EdgeProfileSyncConfig).IncludeProtectedProfiles | Should -BeFalse
        # Hand-edited string values are tolerated, like CloseBackgroundEdge / RemoveDeletedProfiles.
        '{"IncludeProtectedProfiles":"true"}' | Set-Content -LiteralPath (Join-Path $env:EDGEPROFILESYNC_HOME 'config.json')
        (Get-EdgeProfileSyncConfig).IncludeProtectedProfiles | Should -BeTrue
    }

    It 'only changes the parameters that are passed' {
        Set-EdgeProfileSyncConfig -IntervalMinutes 45
        Set-EdgeProfileSyncConfig -ArchiveRetention 5
        $config = Get-EdgeProfileSyncConfig
        $config.IntervalMinutes | Should -Be 45
        $config.ArchiveRetention | Should -Be 5
    }

    It 'only stores explicitly set values in the file' {
        Set-EdgeProfileSyncConfig -IntervalMinutes 45
        $json = Get-Content -Raw -LiteralPath (Join-Path $env:EDGEPROFILESYNC_HOME 'config.json') | ConvertFrom-Json -AsHashtable
        @($json.Keys) | Should -Be @('IntervalMinutes')
    }

    It 'creates a missing SyncRoot and stores the full path' {
        $root = Join-Path $TestDrive 'new\nested\sync'
        Set-EdgeProfileSyncConfig -SyncRoot $root
        Test-Path -LiteralPath $root -PathType Container | Should -BeTrue
        (Get-EdgeProfileSyncConfig).SyncRoot | Should -Be $root
    }

    It 'resolves a relative SyncRoot against the current location' {
        Push-Location $TestDrive
        try {
            Set-EdgeProfileSyncConfig -SyncRoot 'relative-sync'
        }
        finally {
            Pop-Location
        }
        (Get-EdgeProfileSyncConfig).SyncRoot | Should -Be (Join-Path $TestDrive 'relative-sync')
    }

    It 'rejects a SyncRoot that is a file' {
        $file = Join-Path $TestDrive 'iam-a-file.txt'
        Set-Content -LiteralPath $file -Value 'x'
        { Set-EdgeProfileSyncConfig -SyncRoot $file } | Should -Throw '*not a folder*'
    }

    It 'rejects a SyncRoot that cannot be created' {
        { Set-EdgeProfileSyncConfig -SyncRoot 'Q:\no\such\drive\EdgeProfileSync' -ErrorAction Stop } | Should -Throw '*cannot be created*'
    }

    It 'rejects unknown channels' {
        { Set-EdgeProfileSyncConfig -Channels Nightly } | Should -Throw
    }

    It 'rejects unknown categories' {
        { Set-EdgeProfileSyncConfig -Categories Bookmarks, Passwords } | Should -Throw '*Unknown category*Passwords*'
        Test-Path -LiteralPath (Join-Path $env:EDGEPROFILESYNC_HOME 'config.json') | Should -BeFalse
    }

    It 'normalises category casing and removes duplicates' {
        Set-EdgeProfileSyncConfig -Categories bookmarks, HISTORY, Bookmarks
        (Get-EdgeProfileSyncConfig).Categories | Should -Be @('Bookmarks', 'History')
    }

    It 'accepts an empty IncludeProfiles list to reset it' {
        Set-EdgeProfileSyncConfig -IncludeProfiles 'Personal'
        Set-EdgeProfileSyncConfig -IncludeProfiles @()
        (Get-EdgeProfileSyncConfig).IncludeProfiles.Count | Should -Be 0
    }

    It 'rejects an out-of-range interval' {
        { Set-EdgeProfileSyncConfig -IntervalMinutes 1 } | Should -Throw
    }

    It 'returns the configuration only with -PassThru' {
        Set-EdgeProfileSyncConfig -IntervalMinutes 20 | Should -BeNullOrEmpty
        (Set-EdgeProfileSyncConfig -IntervalMinutes 25 -PassThru).IntervalMinutes | Should -Be 25
    }

    It 'changes nothing with -WhatIf' {
        $root = Join-Path $TestDrive 'whatif-sync'
        Set-EdgeProfileSyncConfig -SyncRoot $root -IntervalMinutes 50 -WhatIf
        Test-Path -LiteralPath $root | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $env:EDGEPROFILESYNC_HOME 'config.json') | Should -BeFalse
    }
}
