#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# Tests for Private/Core.*.ps1. Everything runs against fake User Data folders under $TestDrive;
# processes are mocked. Nothing touches the real Edge installation.

BeforeAll {
    $script:ModuleManifest = Join-Path $PSScriptRoot '..\EdgeProfileSync\EdgeProfileSync.psd1'
    $script:OldHome = $env:EDGEPROFILESYNC_HOME
    $env:EDGEPROFILESYNC_HOME = Join-Path $TestDrive 'home'
    Import-Module $script:ModuleManifest -Force -ErrorAction Stop

    function New-FakeUserData {
        param([string]$Root, [hashtable[]]$Profiles, [string[]]$Order, [switch]$MissingFolderFor)
        $null = New-Item -Path $Root -ItemType Directory -Force
        $info = [ordered]@{}
        foreach ($p in $Profiles) {
            $info[$p.Dir] = [ordered]@{ name = $p.Name; user_name = $p.User ?? ''; avatar_icon = 'chrome://theme/IDR_PROFILE_AVATAR_26' }
            if (-not $p.ContainsKey('NoFolder')) { $null = New-Item -Path (Join-Path $Root $p.Dir) -ItemType Directory -Force }
        }
        $state = [ordered]@{
            ''      = @{ 'x' = 1 }    # Local State really contains empty property names
            profile = [ordered]@{ info_cache = $info; profiles_order = @($Order) }
        }
        Set-Content -LiteralPath (Join-Path $Root 'Local State') -Value ($state | ConvertTo-Json -Depth 20) -Encoding utf8NoBOM
    }
}

AfterAll {
    $env:EDGEPROFILESYNC_HOME = $script:OldHome
    Remove-Module EdgeProfileSync -Force -ErrorAction SilentlyContinue
}

Describe 'Core.Paths' {
    It 'Get-EdgeChannelInfo maps channels to folders and registry keys' {
        InModuleScope EdgeProfileSync {
            $s = Get-EdgeChannelInfo
            $s.Channel | Should -Be 'Stable'
            $s.UserDataPath | Should -Be (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data')
            $s.RegistryKey | Should -Be 'HKCU\Software\Microsoft\Edge\PreferenceMACs'

            $c = Get-EdgeChannelInfo -Channel Canary
            $c.UserDataPath | Should -BeLike '*\Microsoft\Edge SxS\User Data'
            $c.RegistryKey | Should -Be 'HKCU\Software\Microsoft\Edge SxS\PreferenceMACs'
            (Get-EdgeChannelInfo -Channel Beta).RegistryKey | Should -Be 'HKCU\Software\Microsoft\Edge Beta\PreferenceMACs'
        }
    }

    It 'Get-EdgeChannelInfo honours -UserDataRoot and reports Installed' {
        $root = Join-Path $TestDrive 'ud-paths'
        InModuleScope EdgeProfileSync -Parameters @{ Root = $root } {
            param($Root)
            (Get-EdgeChannelInfo -UserDataRoot $Root).Installed | Should -BeFalse
            $null = New-Item -Path $Root -ItemType Directory
            $i = Get-EdgeChannelInfo -Channel Dev -UserDataRoot $Root
            $i.UserDataPath | Should -Be $Root
            $i.Installed | Should -BeTrue
        }
    }

    It 'Get-EdgeSyncMachineId is COMPUTERNAME-8 hex chars and stable' {
        InModuleScope EdgeProfileSync {
            $id = Get-EdgeSyncMachineId
            $id | Should -Match ('^' + [regex]::Escape($env:COMPUTERNAME) + '-[0-9a-f]{8}$')
            Get-EdgeSyncMachineId | Should -Be $id
        }
    }

    It 'Get-EdgeSyncMachineId uses the MachineGuid' {
        InModuleScope EdgeProfileSync {
            Mock Get-ItemPropertyValue { 'ABCDEF12-3456-7890-abcd-ef1234567890' }
            Get-EdgeSyncMachineId | Should -Be "$env:COMPUTERNAME-abcdef12"
        }
    }

    It 'Get-EdgeSyncLocalDataPath honours EDGEPROFILESYNC_HOME and creates it' {
        InModuleScope EdgeProfileSync {
            $p = Get-EdgeSyncLocalDataPath
            $p | Should -Be $env:EDGEPROFILESYNC_HOME
            Test-Path -LiteralPath $p -PathType Container | Should -BeTrue
        }
    }

    It 'ConvertTo-EdgeSafeName produces <Expected> from <In>' -TestCases @(
        @{ In = 'Work'; Expected = 'Work' }
        @{ In = 'a:b/c\d*e?f"g<h>i|j'; Expected = 'a_b_c_d_e_f_g_h_i_j' }
        @{ In = '  Test A.. '; Expected = 'Test A' }
        @{ In = ''; Expected = '_' }
        @{ In = 'CON'; Expected = 'CON_' }
    ) {
        param($In, $Expected)
        InModuleScope EdgeProfileSync -Parameters @{ In = $In; Expected = $Expected } {
            param($In, $Expected)
            ConvertTo-EdgeSafeName -Name $In | Should -BeExactly $Expected
        }
    }

    It 'ConvertTo-EdgeSafeName limits to 80 chars' {
        InModuleScope EdgeProfileSync {
            (ConvertTo-EdgeSafeName -Name ('x' * 200)).Length | Should -Be 80
        }
    }
}

Describe 'Core.Json' {
    It 'round-trips JSON with empty property names, atomically and without BOM' {
        $path = Join-Path $TestDrive 'json\sub\state.json'
        InModuleScope EdgeProfileSync -Parameters @{ Path = $path } {
            param($Path)
            $obj = [ordered]@{ '' = @{ a = 1 }; name = 'Personal'; list = @(1, 2, 3); when = '2026-01-02T03:04:05Z'; big = 13350000000000000 }
            Write-EdgeJsonFile -Path $Path -InputObject $obj
            $bytes = [IO.File]::ReadAllBytes($Path)
            $bytes[0] | Should -Not -Be 0xEF
            $back = Read-EdgeJsonFile -Path $Path
            $back | Should -BeOfType [System.Collections.IDictionary]
            $back[''].a | Should -Be 1
            $back.name | Should -Be 'Personal'
            $back.list.Count | Should -Be 3
            $back.big | Should -Be 13350000000000000
            # overwrite path (File.Replace) and no temp files left behind
            $back.name = 'Work'
            Write-EdgeJsonFile -Path $Path -InputObject $back
            (Read-EdgeJsonFile -Path $Path).name | Should -Be 'Work'
            @(Get-ChildItem -LiteralPath (Split-Path $Path) -Force).Count | Should -Be 1
        }
    }

    It 'keeps date-like strings as strings when supported' -Skip:(-not (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $path = Join-Path $TestDrive 'json\date.json'
        InModuleScope EdgeProfileSync -Parameters @{ Path = $path } {
            param($Path)
            Write-EdgeJsonFile -Path $Path -InputObject @{ when = '2026-01-02T03:04:05Z' }
            (Read-EdgeJsonFile -Path $Path).when | Should -BeOfType [string]
        }
    }

    It 'reads top-level arrays and UTF-8 with BOM' {
        $path = Join-Path $TestDrive 'json\arr.json'
        [IO.File]::WriteAllText($path, '[{"x":1},{"x":2}]', [Text.UTF8Encoding]::new($true))
        InModuleScope EdgeProfileSync -Parameters @{ Path = $path } {
            param($Path)
            $a = Read-EdgeJsonFile -Path $Path
            $a.Count | Should -Be 2
            $a[1].x | Should -Be 2
        }
    }

    It 'throws on a missing file' {
        InModuleScope EdgeProfileSync -Parameters @{ Path = (Join-Path $TestDrive 'nope.json') } {
            param($Path)
            { Read-EdgeJsonFile -Path $Path } | Should -Throw '*not found*'
        }
    }
}

Describe 'Core.Process' {
    BeforeEach {
        InModuleScope EdgeProfileSync {
            function New-FakeProc([int]$Id, [string]$Path, [int64]$Window = 0, [string]$Name = 'msedge') {
                $o = [pscustomobject]@{ Id = $Id; ProcessName = $Name; Path = $Path; MainWindowHandle = [IntPtr]$Window }
                $o | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value {
                    $script:Closed.Add($this.Id)
                    $script:FakeProcs = @($script:FakeProcs | Where-Object Id -ne $this.Id)
                    $true
                }
                $o
            }
            $stable = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
            $beta = 'C:\Program Files (x86)\Microsoft\Edge Beta\Application\msedge.exe'
            $script:Closed = [System.Collections.Generic.List[int]]::new()
            $script:FakeProcs = @(
                New-FakeProc 1 $stable
                New-FakeProc 2 $stable
                New-FakeProc 3 $beta 1234
                New-FakeProc 4 'C:\Program Files (x86)\Microsoft\EdgeWebView\Application\1.0\msedgewebview2.exe' 0 'msedgewebview2'
                New-FakeProc 5 $null
            )
            Mock Get-Process { $script:FakeProcs }
            Mock Stop-Process { $script:FakeProcs = @($script:FakeProcs | Where-Object Id -notin $Id) }
            Mock Start-Sleep { }
        }
    }

    It 'Get-EdgeProcessState separates channels by path' {
        InModuleScope EdgeProfileSync {
            $s = Get-EdgeProcessState -Channel Stable
            $s.Running | Should -BeTrue
            $s.HasWindows | Should -BeFalse
            $s.ProcessCount | Should -Be 2

            $b = Get-EdgeProcessState -Channel Beta
            $b.ProcessCount | Should -Be 1
            $b.HasWindows | Should -BeTrue

            (Get-EdgeProcessState -Channel Dev).Running | Should -BeFalse
        }
    }

    It 'Stop-EdgeProcess -BackgroundOnly stops windowless Stable only' {
        InModuleScope EdgeProfileSync {
            Stop-EdgeProcess -Channel Stable -BackgroundOnly | Should -BeTrue
            Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { (@($Id) -join ',') -eq '1,2' }
            @($script:FakeProcs.Id) | Should -Be @(3, 4, 5)
        }
    }

    It 'Stop-EdgeProcess -BackgroundOnly refuses when windows are open' {
        InModuleScope EdgeProfileSync {
            Stop-EdgeProcess -Channel Beta -BackgroundOnly | Should -BeFalse
            Should -Invoke Stop-Process -Times 0 -Exactly
            $script:Closed.Count | Should -Be 0
        }
    }

    It 'Stop-EdgeProcess closes windows gracefully first' {
        InModuleScope EdgeProfileSync {
            Stop-EdgeProcess -Channel Beta | Should -BeTrue
            @($script:Closed) | Should -Be @(3)
            Should -Invoke Stop-Process -Times 0 -Exactly
        }
    }

    It 'Stop-EdgeProcess returns true when nothing runs and never touches webview2' {
        InModuleScope EdgeProfileSync {
            Stop-EdgeProcess -Channel Canary | Should -BeTrue
            Should -Invoke Stop-Process -Times 0 -Exactly
        }
    }

    It 'Stop-EdgeProcess returns false after the timeout when processes survive' {
        InModuleScope EdgeProfileSync {
            Mock Stop-Process { }
            Stop-EdgeProcess -Channel Stable -TimeoutSeconds 1 | Should -BeFalse
            Should -Invoke Stop-Process -ParameterFilter { 4 -notin $Id -and 5 -notin $Id }
        }
    }
}

Describe 'Core.Profiles' {
    It 'lists existing profiles in profiles_order with case-insensitive duplicate keys' {
        $root = Join-Path $TestDrive 'ud-list'
        New-FakeUserData -Root $root -Order @('Profile 2', 'Default', 'Profile 1') -Profiles @(
            @{ Dir = 'Default'; Name = 'Personal'; User = 'someone@example.com' }
            @{ Dir = 'Profile 1'; Name = 'work' }
            @{ Dir = 'Profile 2'; Name = 'Work' }
            @{ Dir = 'Profile 3'; Name = 'Test: A' }
            @{ Dir = 'Profile 4'; Name = 'Gone'; NoFolder = $true }
            @{ Dir = 'Guest Profile'; Name = 'Guest' }
        )
        InModuleScope EdgeProfileSync -Parameters @{ Root = $root } {
            param($Root)
            $p = @(Get-EdgeLocalProfile -UserDataRoot $Root)
            $p.Directory | Should -Be @('Profile 2', 'Default', 'Profile 1', 'Profile 3')
            $p.Key | Should -Be @('Work', 'Personal', 'work (Profile 1)', 'Test_ A')
            $p[1].IsSignedIn | Should -BeTrue
            $p[0].IsSignedIn | Should -BeFalse
            $p[0].Path | Should -Be (Join-Path $Root 'Profile 2')
            $p[0].Channel | Should -Be 'Stable'
            $p[0].InfoCache['name'] | Should -Be 'Work'
        }
    }

    It 'returns nothing when Local State is missing' {
        $root = Join-Path $TestDrive 'ud-empty'
        $null = New-Item -Path $root -ItemType Directory
        InModuleScope EdgeProfileSync -Parameters @{ Root = $root } {
            param($Root)
            @(Get-EdgeLocalProfile -UserDataRoot $Root).Count | Should -Be 0
        }
    }

    It 'New-EdgeLocalProfile creates the next free folder without account fields' {
        $root = Join-Path $TestDrive 'ud-new'
        New-FakeUserData -Root $root -Order @('Default', 'Profile 1') -Profiles @(
            @{ Dir = 'Default'; Name = 'Personal' }
            @{ Dir = 'Profile 1'; Name = 'Work' }
        )
        $null = New-Item -Path (Join-Path $root 'Profile 2') -ItemType Directory   # stray folder: must be skipped
        InModuleScope EdgeProfileSync -Parameters @{ Root = $root } {
            param($Root)
            $src = @{
                name = 'old'; avatar_icon = 'chrome://theme/IDR_PROFILE_AVATAR_5'; user_name = 'a@example.com'
                gaia_id = '1'; edge_account_cid = 'x'; 'signin.with_credential_provider' = $false
                hosted_domain = 'example.com'; shortcut_name = 'Test A'
            }
            $new = New-EdgeLocalProfile -Name 'Test A' -InfoCache $src -UserDataRoot $Root
            $new.Directory | Should -Be 'Profile 3'
            $new.Name | Should -Be 'Test A'
            $new.Key | Should -Be 'Test A'
            $new.IsSignedIn | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $Root 'Profile 3') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $Root 'Local State.edgeprofilesync.bak') | Should -BeTrue

            $state = Read-EdgeJsonFile -Path (Join-Path $Root 'Local State')
            $state[''].x | Should -Be 1
            $entry = $state.profile.info_cache['Profile 3']
            $entry.Keys | Should -Not -Contain 'user_name'
            $entry.Keys | Should -Not -Contain 'gaia_id'
            $entry.Keys | Should -Not -Contain 'edge_account_cid'
            $entry.Keys | Should -Not -Contain 'signin.with_credential_provider'
            $entry.Keys | Should -Not -Contain 'hosted_domain'
            $entry.avatar_icon | Should -Be 'chrome://theme/IDR_PROFILE_AVATAR_5'
            $entry.shortcut_name | Should -Be 'Test A'
            @($state.profile.profiles_order) | Should -Be @('Default', 'Profile 1', 'Profile 3')
            $src.user_name | Should -Be 'a@example.com'   # input not modified
        }
    }

    It 'New-EdgeLocalProfile works without an existing Local State' {
        $root = Join-Path $TestDrive 'ud-fresh'
        InModuleScope EdgeProfileSync -Parameters @{ Root = $root } {
            param($Root)
            $new = New-EdgeLocalProfile -Name 'Test B' -UserDataRoot $Root
            $new.Directory | Should -Be 'Profile 1'
            @(Get-EdgeLocalProfile -UserDataRoot $Root).Count | Should -Be 1
        }
    }
}

Describe 'Core.Files' {
    It 'Copy-EdgeItem copies a file, creates parents and preserves LastWriteTimeUtc' {
        $src = Join-Path $TestDrive 'files\src.txt'
        $dst = Join-Path $TestDrive 'files\out\deep\dst.txt'
        $null = New-Item -Path (Split-Path $src) -ItemType Directory -Force
        Set-Content -LiteralPath $src -Value 'hello'
        $t = [datetime]::new(2024, 5, 6, 7, 8, 9, [DateTimeKind]::Utc)
        [IO.File]::SetLastWriteTimeUtc($src, $t)
        InModuleScope EdgeProfileSync -Parameters @{ Src = $src; Dst = $dst } {
            param($Src, $Dst)
            Copy-EdgeItem -Source $Src -Destination $Dst | Should -BeNullOrEmpty
            Copy-EdgeItem -Source $Src -Destination $Dst   # overwrite
        }
        Get-Content -LiteralPath $dst | Should -Be 'hello'
        [IO.File]::GetLastWriteTimeUtc($dst) | Should -Be $t
    }

    It 'Copy-EdgeItem copies a file that is open for writing by another handle' {
        $src = Join-Path $TestDrive 'files\locked.db'
        Set-Content -LiteralPath $src -Value 'sqlite'
        $fs = [IO.File]::Open($src, 'Open', 'ReadWrite', 'ReadWrite')
        try {
            InModuleScope EdgeProfileSync -Parameters @{ Src = $src; Dst = (Join-Path $TestDrive 'files\locked-copy.db') } {
                param($Src, $Dst)
                Copy-EdgeItem -Source $Src -Destination $Dst
                Test-Path -LiteralPath $Dst | Should -BeTrue
            }
        }
        finally { $fs.Dispose() }
    }

    It 'Copy-EdgeItem -Directory mirrors with robocopy and keeps fingerprints equal' {
        $src = Join-Path $TestDrive 'dir\src'
        $dst = Join-Path $TestDrive 'dir\dst with space'
        $null = New-Item -Path (Join-Path $src 'sub') -ItemType Directory -Force
        Set-Content -LiteralPath (Join-Path $src 'a.txt') -Value 'a'
        Set-Content -LiteralPath (Join-Path $src 'sub\b.txt') -Value 'b'
        $null = New-Item -Path $dst -ItemType Directory -Force
        Set-Content -LiteralPath (Join-Path $dst 'extra.txt') -Value 'x'
        InModuleScope EdgeProfileSync -Parameters @{ Src = $src; Dst = $dst } {
            param($Src, $Dst)
            Copy-EdgeItem -Source $Src -Destination $Dst -Directory
            Test-Path -LiteralPath (Join-Path $Dst 'sub\b.txt') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $Dst 'extra.txt') | Should -BeFalse
            Get-EdgeItemFingerprint -Path $Dst | Should -Be (Get-EdgeItemFingerprint -Path $Src)
        }
    }

    It 'Copy-EdgeItem throws on robocopy failure and missing sources' {
        InModuleScope EdgeProfileSync -Parameters @{ Root = $TestDrive } {
            param($Root)
            { Copy-EdgeItem -Source (Join-Path $Root 'missing') -Destination (Join-Path $Root 'x') -Directory } | Should -Throw '*not found*'
            { Copy-EdgeItem -Source (Join-Path $Root 'missing.txt') -Destination (Join-Path $Root 'x.txt') } | Should -Throw '*not found*'
            $src = Join-Path $Root 'dir\src'
            # destination on an invalid drive -> robocopy exit code 16
            { Copy-EdgeItem -Source $src -Destination 'Q:\no\such\drive\EdgeProfileSyncTest' -Directory } | Should -Throw '*exit code*'
        }
    } -Skip:(Test-Path 'Q:\')

    It 'Get-EdgeItemFingerprint: file hash, directory hash, missing path' {
        $f1 = Join-Path $TestDrive 'fp\one.txt'
        $null = New-Item -Path (Split-Path $f1) -ItemType Directory -Force
        [IO.File]::WriteAllText($f1, 'abc')
        InModuleScope EdgeProfileSync -Parameters @{ F1 = $f1; Root = $TestDrive } {
            param($F1, $Root)
            Get-EdgeItemFingerprint -Path $F1 | Should -Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
            Get-EdgeItemFingerprint -Path (Join-Path $Root 'fp\none') | Should -BeNullOrEmpty

            $d1 = Join-Path $Root 'fp\d1'; $d2 = Join-Path $Root 'fp\d2'
            foreach ($d in $d1, $d2) {
                $null = New-Item -Path (Join-Path $d 'Sub') -ItemType Directory -Force
                [IO.File]::WriteAllText((Join-Path $d 'x.bin'), '123')
                [IO.File]::WriteAllText((Join-Path $d 'Sub\y.bin'), '4567')
                foreach ($f in Get-ChildItem $d -Recurse -File) { $f.LastWriteTimeUtc = [datetime]::new(2025, 1, 1, 0, 0, 0, [DateTimeKind]::Utc) }
            }
            # sub-second differences are ignored
            [IO.File]::SetLastWriteTimeUtc((Join-Path $d2 'x.bin'), [datetime]::new(2025, 1, 1, 0, 0, 0, [DateTimeKind]::Utc).AddMilliseconds(300))
            $fp1 = Get-EdgeItemFingerprint -Path $d1
            $fp1 | Should -Match '^[0-9a-f]{64}$'
            Get-EdgeItemFingerprint -Path $d2 | Should -Be $fp1

            [IO.File]::WriteAllText((Join-Path $d2 'x.bin'), '124')   # same length, new time
            Get-EdgeItemFingerprint -Path $d2 | Should -Not -Be $fp1
        }
    }

    It 'Move-EdgeItemAside moves files and directories and never overwrites' {
        $root = Join-Path $TestDrive 'aside'
        $null = New-Item -Path (Join-Path $root 'live\Coll') -ItemType Directory -Force
        Set-Content -LiteralPath (Join-Path $root 'live\Bookmarks.bak') -Value '1'
        InModuleScope EdgeProfileSync -Parameters @{ Root = $root } {
            param($Root)
            $bk = Join-Path $Root 'backup'
            $r1 = Move-EdgeItemAside -Path (Join-Path $Root 'live\Bookmarks.bak') -BackupRoot $bk -PassThru
            $r1 | Should -Be (Join-Path $bk 'Bookmarks.bak')
            Set-Content -LiteralPath (Join-Path $Root 'live\Bookmarks.bak') -Value '2'
            $r2 = Move-EdgeItemAside -Path (Join-Path $Root 'live\Bookmarks.bak') -BackupRoot $bk -PassThru
            $r2 | Should -Be (Join-Path $bk 'Bookmarks.bak.1')
            Get-Content $r1 | Should -Be '1'
            Get-Content $r2 | Should -Be '2'

            Move-EdgeItemAside -Path (Join-Path $Root 'live\Coll') -BackupRoot $bk | Should -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path $bk 'Coll') -PathType Container | Should -BeTrue
            Move-EdgeItemAside -Path (Join-Path $Root 'live\missing') -BackupRoot $bk -PassThru | Should -BeNullOrEmpty
        }
    }
}

Describe 'Core.Log' {
    It 'appends to the daily log under EDGEPROFILESYNC_HOME and prunes old logs' {
        $logDir = Join-Path $env:EDGEPROFILESYNC_HOME 'logs'
        $null = New-Item -Path $logDir -ItemType Directory -Force
        $old = Join-Path $logDir ('EdgeProfileSync-{0}.log' -f (Get-Date).AddDays(-30).ToString('yyyyMMdd'))
        $recent = Join-Path $logDir ('EdgeProfileSync-{0}.log' -f (Get-Date).AddDays(-3).ToString('yyyyMMdd'))
        Set-Content -LiteralPath $old, $recent -Value 'old'
        InModuleScope EdgeProfileSync {
            $script:EdgeSyncLogPruned = $false
            Write-EdgeSyncLog -Message 'hello info'
            Write-EdgeSyncLog -Message 'careful' -Level Warning 3>$null
            Write-EdgeSyncLog -Message 'broken' -Level Error 2>$null
            Write-EdgeSyncLog -Message 'details' -Level Verbose
        }
        Test-Path -LiteralPath $old | Should -BeFalse
        Test-Path -LiteralPath $recent | Should -BeTrue
        $today = Join-Path $logDir ('EdgeProfileSync-{0}.log' -f (Get-Date).ToString('yyyyMMdd'))
        $lines = Get-Content -LiteralPath $today
        $lines.Count | Should -Be 4
        $lines[0] | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2} INFO hello info$'
        $lines[1] | Should -Match ' WARNING careful$'
        $lines[2] | Should -Match ' ERROR broken$'
        $lines[3] | Should -Match ' VERBOSE details$'
    }

    It 'writes to the matching streams and does not throw on Error under ErrorAction Stop' {
        InModuleScope EdgeProfileSync {
            $w = Write-EdgeSyncLog -Message 'w' -Level Warning 3>&1
            "$w" | Should -Be 'w'
            $ErrorActionPreference = 'Stop'
            { Write-EdgeSyncLog -Message 'e' -Level Error 2>$null } | Should -Not -Throw
            $v = Write-EdgeSyncLog -Message 'v' -Verbose 4>&1
            "$v" | Should -Be 'v'
        }
    }
}
