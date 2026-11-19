#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Backup / restore / extension tests. Everything runs against a fake User Data folder under
# $TestDrive; Edge process and machine-id functions are mocked, registry is never touched.

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..\EdgeProfileSync'
    Import-Module (Join-Path $script:ModuleRoot 'EdgeProfileSync.psd1') -Force
    $script:OldHome = $env:EDGEPROFILESYNC_HOME

    function Write-TestJson([string]$Path, $Object) {
        $null = New-Item -ItemType Directory -Path (Split-Path $Path) -Force
        [IO.File]::WriteAllText($Path, ($Object | ConvertTo-Json -Depth 30))
    }

    # Extension ids (32 chars a-p, like real ids)
    $script:IdEdge = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $script:IdChrome = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $script:IdPolicy = 'cccccccccccccccccccccccccccccccc'
    $script:IdComponent = 'dddddddddddddddddddddddddddddddd'
    $script:IdUnpacked = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
    $script:IdDefault = 'ffffffffffffffffffffffffffffffff'
    $script:IdStub = 'gggggggggggggggggggggggggggggggg'
    $script:IdDisk = 'hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh'

    function New-FakeExtensionSettings([switch]$OnlyEdge) {
        $edgeUpd = 'https://edge.microsoft.com/extensionwebstorebase/v1/crx'
        $s = [ordered]@{
            $script:IdEdge = @{ location = 1; from_webstore = $false; path = "$($script:IdEdge)\1.2.3_0"
                manifest = @{ name = '__MSG_appName__'; default_locale = 'en'; version = '1.2.3'; update_url = $edgeUpd } }
        }
        if (-not $OnlyEdge) {
            $s[$script:IdChrome] = @{ location = 1; from_webstore = $true; manifest = @{ name = 'Chrome Ext'; version = '2.0'; update_url = 'https://clients2.google.com/service/update2/crx' } }
            $s[$script:IdPolicy] = @{ location = 7; manifest = @{ name = 'Policy Ext'; version = '3.0'; update_url = $edgeUpd } }
            $s[$script:IdComponent] = @{ location = 5; manifest = @{ name = 'Component Ext'; version = '1.0' } }
            $s[$script:IdUnpacked] = @{ location = 4; path = 'C:\dev\myext'; manifest = @{ name = 'Dev Ext'; version = '0.1' }; disable_reasons = @(1) }
            $s[$script:IdDefault] = @{ location = 6; was_installed_by_default = $true; manifest = @{ name = 'Default Ext'; version = '1.0' } }
            $s[$script:IdStub] = @{ active_permissions = @{}; account_extension_type = 0 }
            $s[$script:IdDisk] = @{ location = 1; path = "$($script:IdDisk)\4.5_0" }
        }
        $s
    }

    # Builds a fake Edge User Data folder with two profiles.
    function New-FakeUserData([string]$Root, [switch]$OnlyEdgeExtensions) {
        if (Test-Path $Root) { Remove-Item $Root -Recurse -Force }
        $null = New-Item -ItemType Directory -Path $Root -Force
        Write-TestJson (Join-Path $Root 'Local State') @{
            profile = @{
                info_cache     = @{
                    'Default'   = @{ name = 'Personal'; user_name = 'someone@example.com'; avatar_icon = 'chrome://theme/IDR_PROFILE_AVATAR_1'; active_time = 1767225600.5 }
                    'Profile 1' = @{ name = 'Work'; user_name = '' }
                }
                profiles_order = @('Default', 'Profile 1')
            }
            ''      = 'empty key'
        }
        foreach ($p in @(@{ Dir = 'Default'; Name = 'Personal' }, @{ Dir = 'Profile 1'; Name = 'Work' })) {
            $pp = Join-Path $Root $p.Dir
            Write-TestJson (Join-Path $pp 'Bookmarks') @{ roots = @{
                    bookmark_bar = @{ type = 'folder'; children = @(
                            @{ type = 'url'; name = "bm-$($p.Name)"; url = 'https://example.com/' }
                            @{ type = 'folder'; name = 'sub'; children = @(@{ type = 'url'; name = 'two'; url = 'https://example.org/' }) }) }
                    other        = @{ type = 'folder'; children = @() } } }
            Set-Content (Join-Path $pp 'EncryptedBookmarks2') 'enc' -NoNewline
            Write-TestJson (Join-Path $pp 'Preferences') @{ homepage = "https://$($p.Name).example" }
            Write-TestJson (Join-Path $pp 'Secure Preferences') @{ extensions = @{ settings = (New-FakeExtensionSettings -OnlyEdge:$OnlyEdgeExtensions) } }
            Set-Content (Join-Path $pp 'History') "history-$($p.Name)" -NoNewline
            Set-Content (Join-Path $pp 'Favicons') 'icons' -NoNewline
            $null = New-Item -ItemType Directory -Path (Join-Path $pp 'Collections') -Force
            Set-Content (Join-Path $pp 'Collections\collectionsSQLite') 'coll' -NoNewline
            $null = New-Item -ItemType Directory -Path (Join-Path $pp 'Cache\Cache_Data') -Force
            Set-Content (Join-Path $pp 'Cache\Cache_Data\data_0') ('x' * 1000) -NoNewline
            Set-Content (Join-Path $pp 'Login Data') 'secret' -NoNewline
            # extension files + data
            $edgeDir = Join-Path $pp "Extensions\$($script:IdEdge)\1.2.3_0"
            Write-TestJson (Join-Path $edgeDir 'manifest.json') @{ name = '__MSG_appName__'; version = '1.2.3' }
            Write-TestJson (Join-Path $edgeDir '_locales\en\messages.json') @{ appName = @{ message = 'Edge Store Ext' } }
            Write-TestJson (Join-Path $pp "Extensions\$($script:IdDisk)\4.5_0\manifest.json") @{ name = 'Disk Ext'; version = '4.5'; update_url = 'https://edge.microsoft.com/extensionwebstorebase/v1/crx' }
            foreach ($d in 'Local Extension Settings', 'Sync Extension Settings') {
                $null = New-Item -ItemType Directory -Path (Join-Path $pp "$d\$($script:IdEdge)") -Force
                Set-Content (Join-Path $pp "$d\$($script:IdEdge)\000003.log") "data-$($p.Name)" -NoNewline
            }
            $null = New-Item -ItemType Directory -Path (Join-Path $pp "Local Extension Settings\$($script:IdComponent)") -Force
            Set-Content (Join-Path $pp "Local Extension Settings\$($script:IdComponent)\000003.log") 'component' -NoNewline
        }
        $null = New-Item -ItemType Directory -Path (Join-Path $Root 'GrShaderCache') -Force
        Set-Content (Join-Path $Root 'GrShaderCache\data_1') 'shader' -NoNewline
        Set-Content (Join-Path $Root 'BrowserMetrics-spare.pma') 'pma' -NoNewline
    }

    function Get-ZipEntryName([string]$Path) {
        $z = [IO.Compression.ZipFile]::OpenRead($Path)
        try { @($z.Entries | ForEach-Object { $_.FullName -replace '\\', '/' }) } finally { $z.Dispose() }
    }
}

AfterAll {
    $env:EDGEPROFILESYNC_HOME = $script:OldHome
    Remove-Module EdgeProfileSync -Force -ErrorAction Ignore
}

Describe 'Get-EdgeExtensionInventory' {
    BeforeAll {
        $script:InvRoot = Join-Path $TestDrive 'inv'
        New-FakeUserData -Root $script:InvRoot
        $script:Inv = InModuleScope EdgeProfileSync -Parameters @{ P = (Join-Path $script:InvRoot 'Default') } {
            param($P) @(Get-EdgeExtensionInventory -ProfilePath $P)
        }
    }

    It 'skips component, default-installed and stub entries' {
        $script:Inv.Id | Should -Not -Contain $script:IdComponent
        $script:Inv.Id | Should -Not -Contain $script:IdDefault
        $script:Inv.Id | Should -Not -Contain $script:IdStub
        $script:Inv.Count | Should -Be 5
    }

    It 'classifies sources and store URLs' {
        $byId = @{}; $script:Inv | ForEach-Object { $byId[$_.Id] = $_ }
        $byId[$script:IdEdge].Source | Should -Be 'EdgeStore'
        $byId[$script:IdEdge].StoreUrl | Should -Be "https://microsoftedge.microsoft.com/addons/detail/$($script:IdEdge)"
        $byId[$script:IdChrome].Source | Should -Be 'ChromeStore'
        $byId[$script:IdChrome].StoreUrl | Should -Be "https://chromewebstore.google.com/detail/$($script:IdChrome)"
        $byId[$script:IdPolicy].Source | Should -Be 'Policy'
        $byId[$script:IdPolicy].StoreUrl | Should -BeNullOrEmpty
        $byId[$script:IdUnpacked].Source | Should -Be 'Unpacked'
        $byId[$script:IdUnpacked].Enabled | Should -BeFalse
    }

    It 'resolves __MSG_ names and reads manifest.json from disk when settings have none' {
        $edge = $script:Inv | Where-Object Id -eq $script:IdEdge
        $edge.Name | Should -Be 'Edge Store Ext'
        $edge.Version | Should -Be '1.2.3'
        $disk = $script:Inv | Where-Object Id -eq $script:IdDisk
        $disk.Name | Should -Be 'Disk Ext'
        $disk.Version | Should -Be '4.5'
        $disk.Source | Should -Be 'EdgeStore'
    }
}

Describe 'Backup and restore' {
    BeforeAll {
        $env:EDGEPROFILESYNC_HOME = Join-Path $TestDrive 'home'
        $script:UD = Join-Path $TestDrive 'UserData'
        $script:Dest = Join-Path $TestDrive 'backups'
        $script:MachineId = 'TESTPC-00000001'
        Mock -ModuleName EdgeProfileSync Get-EdgeSyncMachineId { $script:MachineId }
        Mock -ModuleName EdgeProfileSync Get-EdgeProcessState { [pscustomobject]@{ Running = $false; HasWindows = $false; ProcessCount = 0 } }
        Mock -ModuleName EdgeProfileSync Stop-EdgeProcess { throw 'Stop-EdgeProcess must not be called in tests' }
        Mock -ModuleName EdgeProfileSync Start-Process { }
        Mock -ModuleName EdgeProfileSync Get-EdgeExecutablePath { 'C:\fake\msedge.exe' }
        Mock -ModuleName EdgeProfileSync Write-Host { }
    }

    BeforeEach {
        $script:MachineId = 'TESTPC-00000001'
        New-FakeUserData -Root $script:UD
        if (Test-Path $script:Dest) { Remove-Item $script:Dest -Recurse -Force }
        if (Test-Path $env:EDGEPROFILESYNC_HOME) { Remove-Item $env:EDGEPROFILESYNC_HOME -Recurse -Force }
    }

    Context 'Get-EdgeProfile' {
        It 'lists profiles with the overview columns' {
            $p = @(Get-EdgeProfile -UserDataRoot $script:UD -IncludeSize -SyncRoot (Join-Path $TestDrive 'nosync'))
            $p.Count | Should -Be 2
            $def = $p | Where-Object Directory -eq 'Default'
            $def.Name | Should -Be 'Personal'
            $def.IsSignedIn | Should -BeTrue
            $def.Account | Should -Be 'someone@example.com'
            $def.LastActiveUtc | Should -BeOfType [datetime]
            $def.LastActive | Should -Be $def.LastActiveUtc.ToLocalTime()
            $def.InUse | Should -BeFalse
            $def.BookmarkCount | Should -Be 2
            $def.ExtensionCount | Should -Be 5
            $def.SizeMB | Should -BeOfType [double]
            $def.PendingExtensions | Should -Be 0
            $def.SyncState | Should -Be ''
            (Get-EdgeProfile -UserDataRoot $script:UD -SyncRoot (Join-Path $TestDrive 'nosync'))[0].SizeMB | Should -BeNullOrEmpty
        }

        It 'reports SyncState from the sync store' {
            $sr = Join-Path $TestDrive 'syncroot'
            Remove-Item $sr -Recurse -Force -ErrorAction Ignore
            $null = New-Item -ItemType Directory -Path (Join-Path $sr 'store\Stable\Personal') -Force
            $null = New-Item -ItemType Directory -Path (Join-Path $sr 'store\Stable\Work') -Force
            Set-Content (Join-Path $sr 'store\Stable\Work\deleted.json') '{}'
            $p = @(Get-EdgeProfile -UserDataRoot $script:UD -SyncRoot $sr)
            ($p | Where-Object Name -eq 'Personal').SyncState | Should -Be 'Synced'
            ($p | Where-Object Name -eq 'Work').SyncState | Should -Be 'Deleted elsewhere'
            Remove-Item (Join-Path $sr 'store\Stable\Personal') -Recurse -Force
            (Get-EdgeProfile -UserDataRoot $script:UD -SyncRoot $sr -Name Personal).SyncState | Should -Be 'LocalOnly'
        }

        It '-All lists orphan profile folders' {
            $orphan = Join-Path $script:UD 'Profile 9'
            $null = New-Item -ItemType Directory -Path $orphan -Force
            Set-Content (Join-Path $orphan 'Preferences') '{}'
            @(Get-EdgeProfile -UserDataRoot $script:UD).Count | Should -Be 2
            $o = @(Get-EdgeProfile -UserDataRoot $script:UD -All) | Where-Object Directory -eq 'Profile 9'
            $o.Name | Should -Be '(orphan)'
            $o.IsOrphan | Should -BeTrue
        }

        It 'filters by -Profile with wildcards' {
            @(Get-EdgeProfile -UserDataRoot $script:UD -Profile 'W*').Name | Should -Be @('Work')
        }
    }

    Context 'Backup-EdgeProfiles' {
        It 'creates a zip with manifest, categories and per-extension data but no caches or passwords' {
            $r = Backup-EdgeProfiles -UserDataRoot $script:UD -Destination $script:Dest -PassThru
            $r.Path | Should -Exist
            $r.Path | Should -Match 'EdgeStable-\d{8}-\d{6}\.zip$'
            $names = Get-ZipEntryName $r.Path
            $names | Should -Contain 'backup-manifest.json'
            $names | Should -Contain 'Stable/Personal/Bookmarks/Bookmarks'
            $names | Should -Contain 'Stable/Work/Settings/Preferences'
            $names | Should -Contain 'Stable/Work/SecurePreferences/Secure Preferences'
            $names | Should -Contain 'Stable/Work/History/History'
            $names | Should -Contain 'Stable/Work/Collections/Collections/collectionsSQLite'
            $names | Should -Contain 'Stable/Work/ExtensionList/extensions.json'
            $names | Should -Contain "Stable/Work/ExtensionData/$($script:IdEdge)/Local Extension Settings/000003.log"
            $names | Should -Contain "Stable/Work/ExtensionData/$($script:IdEdge)/Sync Extension Settings/000003.log"
            ($names -match $script:IdComponent) | Should -BeNullOrEmpty
            ($names -match 'Cache|Login Data|EncryptedBookmarks2|Extensions/') | Should -BeNullOrEmpty
        }

        It 'writes a manifest with machine id and profiles' {
            $r = Backup-EdgeProfiles -UserDataRoot $script:UD -Destination $script:Dest -PassThru
            $tmp = Join-Path $TestDrive 'mf'; Remove-Item $tmp -Recurse -Force -ErrorAction Ignore
            [IO.Compression.ZipFile]::ExtractToDirectory($r.Path, $tmp)
            $m = Get-Content (Join-Path $tmp 'backup-manifest.json') -Raw | ConvertFrom-Json -AsHashtable
            $m.MachineId | Should -Be 'TESTPC-00000001'
            $m.Channel | Should -Be 'Stable'
            $m.Profiles.Count | Should -Be 2
            ($m.Profiles | Where-Object Key -eq 'Work').Directory | Should -Be 'Profile 1'
            $m.Categories | Should -Contain 'ExtensionData'
        }

        It 'honours -Profile and -Category' {
            $r = Backup-EdgeProfiles -UserDataRoot $script:UD -Destination $script:Dest -Profile Work -Category Bookmarks -PassThru
            $names = Get-ZipEntryName $r.Path
            ($names | Where-Object { $_ -like 'Stable/*' }) | Should -Be @('Stable/Work/Bookmarks/Bookmarks')
        }

        It 'applies -Retention' {
            $null = New-Item -ItemType Directory -Path $script:Dest -Force
            foreach ($d in '20200101-000000', '20200102-000000', '20200103-000000') { Set-Content (Join-Path $script:Dest "EdgeStable-$d.zip") 'old' }
            Set-Content (Join-Path $script:Dest 'unrelated.zip') 'keep'
            $null = Backup-EdgeProfiles -UserDataRoot $script:UD -Destination $script:Dest -Category Bookmarks -Retention 2
            $left = @(Get-ChildItem $script:Dest -Filter 'EdgeStable-*.zip' | Sort-Object Name)
            $left.Count | Should -Be 2
            $left[0].Name | Should -Be 'EdgeStable-20200103-000000.zip'
            Join-Path $script:Dest 'unrelated.zip' | Should -Exist
        }

        It 'backs up while Edge runs, copying SQLite files as snapshots' {
            Mock -ModuleName EdgeProfileSync Get-EdgeProcessState { [pscustomobject]@{ Running = $true; HasWindows = $true; ProcessCount = 5 } }
            Mock -ModuleName EdgeProfileSync Copy-EdgeSqliteSnapshot { $null = New-Item -ItemType Directory -Path (Split-Path $Destination) -Force; Copy-Item -LiteralPath $Source -Destination $Destination -Force }
            $r = Backup-EdgeProfiles -UserDataRoot $script:UD -Destination $script:Dest -PassThru -WarningVariable w
            $w | Should -BeNullOrEmpty
            Get-ZipEntryName $r.Path | Should -Contain 'Stable/Work/History/History'
            Get-ZipEntryName $r.Path | Should -Contain 'Stable/Work/Collections/Collections/collectionsSQLite'
            Should -Invoke -ModuleName EdgeProfileSync Copy-EdgeSqliteSnapshot -ParameterFilter { $Source -like '*History' }
            Should -Invoke -ModuleName EdgeProfileSync Copy-EdgeSqliteSnapshot -ParameterFilter { $Source -like '*collectionsSQLite' }
            Should -Invoke -ModuleName EdgeProfileSync Copy-EdgeSqliteSnapshot -Times 0 -ParameterFilter { $Source -like '*Bookmarks' }
            Should -Invoke -ModuleName EdgeProfileSync Stop-EdgeProcess -Times 0
        }

        It '-Full copies User Data without caches' {
            $r = Backup-EdgeProfiles -UserDataRoot $script:UD -Destination $script:Dest -Full -PassThru
            $names = Get-ZipEntryName $r.Path
            $names | Should -Contain 'Stable/UserData/Local State'
            $names | Should -Contain 'Stable/UserData/Default/Login Data'
            ($names -match '/Cache/|GrShaderCache|\.pma$') | Should -BeNullOrEmpty
        }
    }

    Context 'Restore-EdgeProfiles' {
        It 'round-trips with Merge: restores files and moves replaced ones aside' {
            $r = Backup-EdgeProfiles -UserDataRoot $script:UD -Destination $script:Dest -PassThru
            $bm = Join-Path $script:UD 'Profile 1\Bookmarks'
            $original = Get-Content $bm -Raw
            Set-Content $bm 'changed' -NoNewline
            Set-Content (Join-Path $script:UD "Profile 1\Local Extension Settings\$($script:IdEdge)\000003.log") 'changed' -NoNewline

            $res = Restore-EdgeProfiles -Path $r.Path -UserDataRoot $script:UD -PassThru
            Get-Content $bm -Raw | Should -Be $original
            Join-Path $script:UD 'Profile 1\EncryptedBookmarks2' | Should -Not -Exist
            Get-Content (Join-Path $script:UD "Profile 1\Local Extension Settings\$($script:IdEdge)\000003.log") -Raw | Should -Be 'data-Work'
            $replaced = Get-ChildItem (Join-Path $script:UD 'EdgeProfileSync-replaced') -Recurse -File
            ($replaced | Where-Object Name -eq 'Bookmarks' | Get-Content -Raw) | Should -Contain 'changed'
            $replaced.Name | Should -Contain 'EncryptedBookmarks2'
            ($res | Where-Object { $_.Category -eq 'SecurePreferences' -and $_.Profile -eq 'Work' }).Action | Should -Be 'Restored'
            # same machine, all extensions present -> nothing pending (only policy ext would be excluded anyway)
            (Get-EdgeProfile -UserDataRoot $script:UD -Profile Work).PendingExtensions | Should -Be 0
        }

        It 'restores to another machine: skips machine-bound data and records pending extensions' {
            $r = Backup-EdgeProfiles -UserDataRoot $script:UD -Destination $script:Dest -PassThru
            $script:MachineId = 'OTHERPC-00000002'
            # Target machine: only the Edge-store extension installed, no extension data yet.
            $target = Join-Path $TestDrive 'Target'
            New-FakeUserData -Root $target -OnlyEdgeExtensions
            Remove-Item (Join-Path $target 'Profile 1\Local Extension Settings') -Recurse -Force
            $secBefore = Get-Content (Join-Path $target 'Profile 1\Secure Preferences') -Raw

            $res = Restore-EdgeProfiles -Path $r.Path -UserDataRoot $target -PassThru
            ($res | Where-Object { $_.Category -eq 'SecurePreferences' -and $_.Profile -eq 'Work' }).Action | Should -Be 'Skipped'
            Get-Content (Join-Path $target 'Profile 1\Secure Preferences') -Raw | Should -Be $secBefore
            Get-Content (Join-Path $target "Profile 1\Local Extension Settings\$($script:IdEdge)\000003.log") -Raw | Should -Be 'data-Work'

            $pending = @(InModuleScope EdgeProfileSync { Get-EdgePendingExtension -Channel Stable -ProfileKey 'Work' })
            $pending.Id | Should -Contain $script:IdChrome
            $pending.Id | Should -Contain $script:IdDisk
            $pending.Id | Should -Contain $script:IdUnpacked
            $pending.Id | Should -Not -Contain $script:IdPolicy
            $pending.Id | Should -Not -Contain $script:IdEdge
            (Get-EdgeProfile -UserDataRoot $target -Profile Work).PendingExtensions | Should -Be 3
        }

        It 'creates a missing profile and matches by key' {
            $r = Backup-EdgeProfiles -UserDataRoot $script:UD -Destination $script:Dest -Profile Work -PassThru
            $target = Join-Path $TestDrive 'Target2'
            New-FakeUserData -Root $target
            # rename local 'Work' so the backup profile has no match
            $ls = Get-Content (Join-Path $target 'Local State') -Raw | ConvertFrom-Json -AsHashtable
            $ls.profile.info_cache['Profile 1'].name = 'Other'
            Write-TestJson (Join-Path $target 'Local State') $ls

            $null = Restore-EdgeProfiles -Path $r.Path -UserDataRoot $target
            $p = @(Get-EdgeProfile -UserDataRoot $target)
            $p.Count | Should -Be 3
            $work = $p | Where-Object Name -eq 'Work'
            $work.Directory | Should -Be 'Profile 2'
            Join-Path $work.Path 'Bookmarks' | Should -Exist
        }

        It 'Rename restores into a fresh User Data with the original folder names' {
            $r = Backup-EdgeProfiles -UserDataRoot $script:UD -Destination $script:Dest -PassThru
            $null = Restore-EdgeProfiles -Path $r.Path -UserDataRoot $script:UD -ExistingDataAction Rename
            $old = @(Get-ChildItem $TestDrive -Directory -Filter 'UserData-*')
            $old.Count | Should -Be 1
            Join-Path $old[0].FullName 'Default\Login Data' | Should -Exist
            Join-Path $script:UD 'Default\Login Data' | Should -Not -Exist
            Join-Path $script:UD 'Profile 1\Bookmarks' | Should -Exist
            (Get-EdgeProfile -UserDataRoot $script:UD).Name | Should -Be @('Personal', 'Work')
            Remove-Item $old[0].FullName -Recurse -Force
        }

        It 'Remove -Force deletes the previous User Data after restoring' {
            $r = Backup-EdgeProfiles -UserDataRoot $script:UD -Destination $script:Dest -PassThru
            $null = Restore-EdgeProfiles -Path $r.Path -UserDataRoot $script:UD -ExistingDataAction Remove -Force
            @(Get-ChildItem $TestDrive -Directory -Filter 'UserData-*').Count | Should -Be 0
            Join-Path $script:UD 'Default\Bookmarks' | Should -Exist
        }

        It 'filters by -Profile and -Category' {
            $r = Backup-EdgeProfiles -UserDataRoot $script:UD -Destination $script:Dest -PassThru
            Set-Content (Join-Path $script:UD 'Default\Bookmarks') 'p' -NoNewline
            Set-Content (Join-Path $script:UD 'Profile 1\Bookmarks') 'w' -NoNewline
            Set-Content (Join-Path $script:UD 'Profile 1\History') 'h' -NoNewline
            $null = Restore-EdgeProfiles -Path $r.Path -UserDataRoot $script:UD -Profile Work -Category Bookmarks
            Get-Content (Join-Path $script:UD 'Default\Bookmarks') -Raw | Should -Be 'p'
            Get-Content (Join-Path $script:UD 'Profile 1\Bookmarks') -Raw | Should -Not -Be 'w'
            Get-Content (Join-Path $script:UD 'Profile 1\History') -Raw | Should -Be 'h'
        }

        It '-WhatIf changes nothing' {
            $r = Backup-EdgeProfiles -UserDataRoot $script:UD -Destination $script:Dest -PassThru
            Set-Content (Join-Path $script:UD 'Profile 1\Bookmarks') 'w' -NoNewline
            Restore-EdgeProfiles -Path $r.Path -UserDataRoot $script:UD -WhatIf
            Get-Content (Join-Path $script:UD 'Profile 1\Bookmarks') -Raw | Should -Be 'w'
            Join-Path $script:UD 'EdgeProfileSync-replaced' | Should -Not -Exist
        }

        It 'refuses Rename while Edge is running without -CloseEdge' {
            $r = Backup-EdgeProfiles -UserDataRoot $script:UD -Destination $script:Dest -PassThru
            Mock -ModuleName EdgeProfileSync Get-EdgeProcessState { [pscustomobject]@{ Running = $true; HasWindows = $true; ProcessCount = 5 } }
            { Restore-EdgeProfiles -Path $r.Path -UserDataRoot $script:UD -ExistingDataAction Rename } | Should -Throw '*running*'
            Join-Path $script:UD 'Default\Login Data' | Should -Exist
            Should -Invoke -ModuleName EdgeProfileSync Stop-EdgeProcess -Times 0
        }

        It 'Merge while Edge runs: restores profiles that are not loaded, skips loaded ones and profile creation' {
            $r = Backup-EdgeProfiles -UserDataRoot $script:UD -Destination $script:Dest -PassThru
            Mock -ModuleName EdgeProfileSync Get-EdgeProcessState { [pscustomobject]@{ Running = $true; HasWindows = $true; ProcessCount = 5 } }
            Mock -ModuleName EdgeProfileSync Test-EdgeProfileInUse { $Path -like '*\Default' }
            Set-Content (Join-Path $script:UD 'Default\Bookmarks') 'p' -NoNewline
            Set-Content (Join-Path $script:UD 'Profile 1\Bookmarks') 'w' -NoNewline
            $res = Restore-EdgeProfiles -Path $r.Path -UserDataRoot $script:UD -PassThru -WarningAction SilentlyContinue
            Get-Content (Join-Path $script:UD 'Default\Bookmarks') -Raw | Should -Be 'p'
            Get-Content (Join-Path $script:UD 'Profile 1\Bookmarks') -Raw | Should -Not -Be 'w'
            ($res | Where-Object Profile -eq 'Personal').Action | Should -Be 'Skipped'
            Should -Invoke -ModuleName EdgeProfileSync Stop-EdgeProcess -Times 0

            # A profile that would have to be created is skipped.
            $target = Join-Path $TestDrive 'RunningTarget'
            New-FakeUserData -Root $target
            $ls = Get-Content (Join-Path $target 'Local State') -Raw | ConvertFrom-Json -AsHashtable
            $ls.profile.info_cache['Profile 1'].name = 'Other'
            Write-TestJson (Join-Path $target 'Local State') $ls
            $res2 = @(Restore-EdgeProfiles -Path $r.Path -UserDataRoot $target -Profile Work -PassThru -WarningAction SilentlyContinue)
            $res2[0].Action | Should -Be 'Skipped'
            @(Get-EdgeProfile -UserDataRoot $target).Count | Should -Be 2
        }

        It 'restores a -Full backup' {
            $r = Backup-EdgeProfiles -UserDataRoot $script:UD -Destination $script:Dest -Full -PassThru
            $null = Restore-EdgeProfiles -Path $r.Path -UserDataRoot $script:UD -ExistingDataAction Remove -Force
            Join-Path $script:UD 'Default\Login Data' | Should -Exist
            Join-Path $script:UD 'Local State' | Should -Exist
            Join-Path $script:UD 'Default\Cache' | Should -Not -Exist
        }

        It 'restores a legacy 1.x zip (whole User Data)' {
            $src = Join-Path $TestDrive 'legacySrc'
            New-FakeUserData -Root (Join-Path $src 'User Data')
            $zip = Join-Path $TestDrive 'EdgeStable-UserData01January2021-user.zip'
            Remove-Item $zip -ErrorAction Ignore
            [IO.Compression.ZipFile]::CreateFromDirectory($src, $zip)
            Set-Content (Join-Path $script:UD 'Default\Bookmarks') 'p' -NoNewline

            $null = Restore-EdgeProfiles -ZIPSource $zip -UserDataRoot $script:UD -ExistingDataAction Remove -Force
            Get-Content (Join-Path $script:UD 'Default\Bookmarks') -Raw | Should -Not -Be 'p'
            Join-Path $script:UD 'Default\Login Data' | Should -Exist
        }
    }

    Context 'Remove-EdgeProfile' {
        BeforeAll {
            InModuleScope EdgeProfileSync {
                if (-not (Get-Command Set-EdgeSyncTombstone -ErrorAction Ignore)) {
                    function script:Set-EdgeSyncTombstone { param($SyncRoot, $Channel, $ProfileKey, $Name) }
                }
            }
            Mock -ModuleName EdgeProfileSync Set-EdgeSyncTombstone { }
            # Tests always pass -Permanent: never use the real Recycle Bin.
            Mock -ModuleName EdgeProfileSync Remove-EdgeLocalProfile -ParameterFilter { -not $Permanent } { throw 'tests must use -Permanent' }
        }

        It 'backs up, removes the profile and writes a tombstone' {
            $sr = Join-Path $TestDrive 'rmsync'
            $null = New-Item -ItemType Directory -Path (Join-Path $sr 'store') -Force
            $res = @(Remove-EdgeProfile -Name Work -UserDataRoot $script:UD -BackupDestination $script:Dest -SyncRoot $sr -Permanent -Force -PassThru)
            $res.Count | Should -Be 1
            $res[0].Action | Should -Be 'Removed'
            $res[0].Tombstone | Should -BeTrue
            $res[0].BackupPath | Should -Exist
            Get-ZipEntryName $res[0].BackupPath | Should -Contain 'Stable/Work/Bookmarks/Bookmarks'
            (Get-ZipEntryName $res[0].BackupPath | Where-Object { $_ -like 'Stable/Personal/*' }) | Should -BeNullOrEmpty
            Join-Path $script:UD 'Profile 1' | Should -Not -Exist
            @(Get-EdgeProfile -UserDataRoot $script:UD).Name | Should -Be @('Personal')
            Should -Invoke -ModuleName EdgeProfileSync Set-EdgeSyncTombstone -Times 1 -Exactly -ParameterFilter { $ProfileKey -eq 'Work' -and $Channel -eq 'Stable' }
        }

        It 'accepts pipeline input from Get-EdgeProfile, honours -LocalOnly and -SkipBackup' {
            $sr = Join-Path $TestDrive 'rmsync'
            $null = New-Item -ItemType Directory -Path (Join-Path $sr 'store') -Force
            $res = @(Get-EdgeProfile -UserDataRoot $script:UD | Where-Object Name -eq 'Work' |
                    Remove-EdgeProfile -UserDataRoot $script:UD -SyncRoot $sr -SkipBackup -LocalOnly -Permanent -Force -PassThru)
            $res[0].Action | Should -Be 'Removed'
            $res[0].BackupPath | Should -BeNullOrEmpty
            Join-Path $script:UD 'Profile 1' | Should -Not -Exist
            Should -Invoke -ModuleName EdgeProfileSync Set-EdgeSyncTombstone -Times 0 -Exactly
            $script:Dest | Should -Not -Exist
        }

        It 'never removes Default and does nothing under -WhatIf' {
            $res = @(Remove-EdgeProfile -Name * -UserDataRoot $script:UD -BackupDestination $script:Dest -Permanent -WhatIf -PassThru -WarningAction SilentlyContinue)
            ($res | Where-Object Directory -eq 'Default').Action | Should -Be 'Skipped'
            ($res | Where-Object Directory -eq 'Profile 1').Action | Should -Be 'WhatIf'
            Join-Path $script:UD 'Profile 1' | Should -Exist
            @(Get-EdgeProfile -UserDataRoot $script:UD).Count | Should -Be 2
        }

        It 'refuses while Edge runs without -CloseEdge' {
            Mock -ModuleName EdgeProfileSync Get-EdgeProcessState { [pscustomobject]@{ Running = $true; HasWindows = $false; ProcessCount = 2 } }
            { Remove-EdgeProfile -Directory 'Profile 1' -UserDataRoot $script:UD -BackupDestination $script:Dest -Permanent -Force } | Should -Throw '*running*'
            Join-Path $script:UD 'Profile 1' | Should -Exist
            Should -Invoke -ModuleName EdgeProfileSync Stop-EdgeProcess -Times 0
        }

        It 'removes orphan folders' {
            $orphan = Join-Path $script:UD 'Profile 9'
            $null = New-Item -ItemType Directory -Path $orphan -Force
            Set-Content (Join-Path $orphan 'Preferences') '{}'
            $res = @(Get-EdgeProfile -UserDataRoot $script:UD -All | Where-Object IsOrphan | Remove-EdgeProfile -UserDataRoot $script:UD -Permanent -Force -PassThru)
            $res[0].Action | Should -Be 'Removed'
            $orphan | Should -Not -Exist
            @(Get-EdgeProfile -UserDataRoot $script:UD).Count | Should -Be 2
        }
    }

    Context 'Install-EdgeProfileExtension' {
        It 'opens the store pages in the right profile and drops installed extensions' {
            InModuleScope EdgeProfileSync -Parameters @{ A = $script:IdChrome; B = $script:IdEdge; C = $script:IdUnpacked } {
                param($A, $B, $C)
                Set-EdgePendingExtension -Channel Stable -ProfileKey 'Work' -Extension @(
                    [pscustomobject]@{ Id = $A; Name = 'Chrome Ext'; Version = '2.0'; Source = 'ChromeStore'; StoreUrl = "https://chromewebstore.google.com/detail/$A" }
                    [pscustomobject]@{ Id = $B; Name = 'Already there'; Version = '1'; Source = 'EdgeStore'; StoreUrl = "https://microsoftedge.microsoft.com/addons/detail/$B" }
                    [pscustomobject]@{ Id = $C; Name = 'Dev Ext'; Version = '0.1'; Source = 'Unpacked'; StoreUrl = $null }
                )
            }
            # Target profile has only the Edge-store extension installed.
            $target = Join-Path $TestDrive 'InstallTarget'
            New-FakeUserData -Root $target -OnlyEdgeExtensions

            $res = @(Install-EdgeProfileExtension -UserDataRoot $target -PassThru)
            Should -Invoke -ModuleName EdgeProfileSync Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'C:\fake\msedge.exe' -and
                $ArgumentList -contains '--profile-directory="Profile 1"' -and
                $ArgumentList -contains "https://chromewebstore.google.com/detail/$($script:IdChrome)" -and
                -not ($ArgumentList -match $script:IdEdge)
            }
            ($res | Where-Object Id -eq $script:IdChrome).Action | Should -Be 'Opened'
            ($res | Where-Object Id -eq $script:IdUnpacked).Action | Should -Be 'Manual'
            ($res | Where-Object Id -eq $script:IdEdge).Action | Should -Be 'AlreadyInstalled'
            (Get-EdgeProfile -UserDataRoot $target -Profile Work).PendingExtensions | Should -Be 2
        }

        It '-WhatIf does not start Edge' {
            InModuleScope EdgeProfileSync -Parameters @{ A = $script:IdChrome } {
                param($A)
                Set-EdgePendingExtension -Channel Stable -ProfileKey 'Work' -Extension @(
                    [pscustomobject]@{ Id = $A; Name = 'Chrome Ext'; Source = 'ChromeStore'; StoreUrl = "https://chromewebstore.google.com/detail/$A" })
            }
            Install-EdgeProfileExtension -UserDataRoot $script:UD -WhatIf
            Should -Invoke -ModuleName EdgeProfileSync Start-Process -Times 0 -Exactly
        }

        It 'Set-EdgePendingExtension with an empty list removes the file' {
            InModuleScope EdgeProfileSync {
                Set-EdgePendingExtension -Channel Stable -ProfileKey 'Work' -Extension @([pscustomobject]@{ Id = 'x'; Name = 'x' })
                @(Get-EdgePendingExtension -Channel Stable).Count | Should -Be 1
                Set-EdgePendingExtension -Channel Stable -ProfileKey 'Work' -Extension @()
                @(Get-EdgePendingExtension -Channel Stable).Count | Should -Be 0
            }
        }
    }
}
