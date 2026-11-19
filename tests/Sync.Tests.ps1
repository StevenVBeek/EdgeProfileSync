#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# Tests for Sync-EdgeProfiles and the sync engine. Everything runs under $TestDrive with fake
# "User Data" folders; the machine id, Edge process state and Stop-EdgeProcess are always mocked,
# so the real Edge installation and the real OneDrive are never touched.

BeforeAll {
    $script:OriginalHome = $env:EDGEPROFILESYNC_HOME
    $env:EDGEPROFILESYNC_HOME = Join-Path $TestDrive 'home-default'

    $manifest = Join-Path $PSScriptRoot '..\EdgeProfileSync\EdgeProfileSync.psd1'
    Import-Module $manifest -Force -ErrorAction Stop

    function Set-TestFile {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$Content,
            [datetime]$TimeUtc = [datetime]::UtcNow
        )
        $dir = Split-Path -Path $Path -Parent
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        [IO.File]::WriteAllText($Path, $Content)
        (Get-Item -LiteralPath $Path).LastWriteTimeUtc = $TimeUtc
    }

    function New-TestUserData {
        # Creates a fake "User Data" folder with a Local State listing the given profiles (Directory -> Name).
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][System.Collections.IDictionary]$Profiles
        )
        $null = New-Item -ItemType Directory -Path $Root -Force
        $infoCache = [ordered]@{}
        foreach ($dir in $Profiles.Keys) {
            $null = New-Item -ItemType Directory -Path (Join-Path $Root $dir) -Force
            $infoCache[$dir] = [ordered]@{ name = $Profiles[$dir]; avatar_icon = 'chrome://theme/IDR_PROFILE_AVATAR_26'; user_name = 'someone@example.com'; gaia_id = '123' }
        }
        $localState = [ordered]@{
            ''      = [ordered]@{ empty = $true }   # Local State contains empty property names
            profile = [ordered]@{ info_cache = $infoCache; profiles_order = @($Profiles.Keys) }
        }
        [IO.File]::WriteAllText((Join-Path $Root 'Local State'), (ConvertTo-Json -InputObject $localState -Depth 10))
    }

    function Get-TestSecurePreferences {
        param([string[]]$ExtensionId)
        $settings = [ordered]@{}
        foreach ($id in $ExtensionId) {
            $settings[$id] = [ordered]@{
                location      = 1
                from_webstore = $false
                manifest      = [ordered]@{ name = "Test extension $($id.Substring(0, 4))"; version = '1.2.3'; update_url = 'https://edge.microsoft.com/extensionwebstorebase/v1/crx' }
            }
        }
        ConvertTo-Json -InputObject ([ordered]@{ extensions = [ordered]@{ settings = $settings } }) -Depth 10
    }

    function Invoke-TestSync {
        # Runs Sync-EdgeProfiles as one of the fake machines.
        param(
            [Parameter(Mandatory)][ValidateSet('PC-A', 'PC-B')][string]$Machine,
            [hashtable]$Extra = @{}
        )
        $env:EPS_TEST_MACHINE = $Machine
        $env:EDGEPROFILESYNC_HOME = $script:Homes[$Machine]
        $params = @{
            SyncRoot     = $script:SyncRoot
            Channel      = 'Stable'
            UserDataRoot = $script:UserData[$Machine]
            WarningAction = 'SilentlyContinue'
        }
        foreach ($k in $Extra.Keys) { $params[$k] = $Extra[$k] }
        @(Sync-EdgeProfiles @params)
    }

    function Get-TestResult {
        param([object[]]$Results, [string]$Profile, [string]$Category)
        $Results | Where-Object { $_.Profile -eq $Profile -and $_.Category -eq $Category } | Select-Object -First 1
    }
}

AfterAll {
    $env:EDGEPROFILESYNC_HOME = $script:OriginalHome
    $env:EPS_TEST_MACHINE = $null
    $env:EPS_TEST_EDGE = $null
    Remove-Module EdgeProfileSync -Force -ErrorAction SilentlyContinue
}

Describe 'Get-EdgeSyncDecision (decision table)' {
    BeforeAll {
        $script:Old = [datetime]::new(2026, 1, 1, 10, 0, 0, [DateTimeKind]::Utc)
        $script:New = [datetime]::new(2026, 1, 1, 12, 0, 0, [DateTimeKind]::Utc)
    }

    It '<Name>' -TestCases @(
        @{ Name = 'nothing on either side -> None'; L = $null; R = $null; B = $null; LT = $null; RT = $null; Expected = 'None' }
        @{ Name = 'nothing on either side but a base -> None'; L = $null; R = $null; B = 'x'; LT = $null; RT = $null; Expected = 'None' }
        @{ Name = 'L == R, no base -> InSync'; L = 'a'; R = 'a'; B = $null; LT = $null; RT = $null; Expected = 'InSync' }
        @{ Name = 'L == R, other base -> InSync'; L = 'a'; R = 'a'; B = 'b'; LT = $null; RT = $null; Expected = 'InSync' }
        @{ Name = 'no base, local only -> Push'; L = 'a'; R = $null; B = $null; LT = 'old'; RT = $null; Expected = 'Push' }
        @{ Name = 'base, store copy vanished -> Push'; L = 'a'; R = $null; B = 'a'; LT = 'old'; RT = $null; Expected = 'Push' }
        @{ Name = 'no base, remote only -> Pull'; L = $null; R = 'a'; B = $null; LT = $null; RT = 'old'; Expected = 'Pull' }
        @{ Name = 'local deleted, remote unchanged -> Pull (no deletion propagation)'; L = $null; R = 'a'; B = 'a'; LT = $null; RT = 'old'; Expected = 'Pull' }
        @{ Name = 'L != B, R == B -> Push'; L = 'b'; R = 'a'; B = 'a'; LT = 'old'; RT = 'new'; Expected = 'Push' }
        @{ Name = 'L == B, R != B -> Pull'; L = 'a'; R = 'b'; B = 'a'; LT = 'new'; RT = 'old'; Expected = 'Pull' }
        @{ Name = 'both changed, local newer -> Conflict-Push'; L = 'b'; R = 'c'; B = 'a'; LT = 'new'; RT = 'old'; Expected = 'Conflict-Push' }
        @{ Name = 'both changed, remote newer -> Conflict-Pull'; L = 'b'; R = 'c'; B = 'a'; LT = 'old'; RT = 'new'; Expected = 'Conflict-Pull' }
        @{ Name = 'both changed, same time -> Conflict-Push'; L = 'b'; R = 'c'; B = 'a'; LT = 'old'; RT = 'old'; Expected = 'Conflict-Push' }
        @{ Name = 'no base, both differ, local newer -> Conflict-Push'; L = 'b'; R = 'c'; B = $null; LT = 'new'; RT = 'old'; Expected = 'Conflict-Push' }
        @{ Name = 'no base, both differ, remote newer -> Conflict-Pull'; L = 'b'; R = 'c'; B = $null; LT = 'old'; RT = 'new'; Expected = 'Conflict-Pull' }
        @{ Name = 'conflict, remote time unknown -> Conflict-Push'; L = 'b'; R = 'c'; B = 'a'; LT = 'old'; RT = $null; Expected = 'Conflict-Push' }
        @{ Name = 'conflict, local time unknown -> Conflict-Pull'; L = 'b'; R = 'c'; B = 'a'; LT = $null; RT = 'old'; Expected = 'Conflict-Pull' }
    ) {
        $times = @{ old = $script:Old; new = $script:New }
        $lt = if ($LT) { $times[$LT] } else { $null }
        $rt = if ($RT) { $times[$RT] } else { $null }
        InModuleScope EdgeProfileSync -Parameters @{ L = $L; R = $R; B = $B; LT = $lt; RT = $rt } {
            param($L, $R, $B, $LT, $RT)
            Get-EdgeSyncDecision -Local $L -Remote $R -Base $B -LocalTimeUtc $LT -RemoteTimeUtc $RT
        } | Should -Be $Expected
    }

    It 'PreferRemoteWithoutBase resolves a first-time conflict to Conflict-Pull even when local is newer' {
        InModuleScope EdgeProfileSync -Parameters @{ Old = $script:Old; New = $script:New } {
            param($Old, $New)
            Get-EdgeSyncDecision -Local 'b' -Remote 'c' -LocalTimeUtc $New -RemoteTimeUtc $Old -PreferRemoteWithoutBase
        } | Should -Be 'Conflict-Pull'
    }

    It 'PreferRemoteWithoutBase does not change decisions when a base exists' {
        InModuleScope EdgeProfileSync -Parameters @{ Old = $script:Old; New = $script:New } {
            param($Old, $New)
            Get-EdgeSyncDecision -Local 'b' -Remote 'c' -Base 'a' -LocalTimeUtc $New -RemoteTimeUtc $Old -PreferRemoteWithoutBase
            Get-EdgeSyncDecision -Local 'b' -Remote 'a' -Base 'a' -PreferRemoteWithoutBase
        } | Should -Be @('Conflict-Push', 'Push')
    }

    It 'treats empty strings as absent' {
        InModuleScope EdgeProfileSync { Get-EdgeSyncDecision -Local '' -Remote 'a' -Base '' } | Should -Be 'Pull'
    }
}

Describe 'Sync store helpers' {
    It 'gives a local item and its store copy the same fingerprint' {
        $root = Join-Path $TestDrive 'fp'
        Set-TestFile -Path (Join-Path $root 'local\Preferences') -Content '{"a":1}'
        Set-TestFile -Path (Join-Path $root 'local\Collections\collectionsSQLite') -Content 'db'
        $null = robocopy (Join-Path $root 'local') (Join-Path $root 'store') /E /COPY:DAT /DCOPY:T /NJH /NJS /NP /NFL /NDL
        InModuleScope EdgeProfileSync -Parameters @{ Root = $root } {
            param($Root)
            $cat = [pscustomobject]@{ Files = @('Preferences', 'Missing.txt'); Directories = @('Collections') }
            $a = Get-EdgeSyncFingerprint -Items @(Get-EdgeSyncItemSpec -Root (Join-Path $Root 'local') -Category $cat)
            $b = Get-EdgeSyncFingerprint -Items @(Get-EdgeSyncItemSpec -Root (Join-Path $Root 'store') -Category $cat)
            $a | Should -Not -BeNullOrEmpty
            $b | Should -Be $a
            Get-EdgeSyncFingerprint -Items @(Get-EdgeSyncItemSpec -Root (Join-Path $Root 'nothing') -Category $cat) | Should -BeNullOrEmpty
        }
    }

    It 'replaces a store item atomically, archives the old copy and applies retention' {
        $root = Join-Path $TestDrive 'publish'
        InModuleScope EdgeProfileSync -Parameters @{ Root = $root } {
            param($Root)
            $final = Join-Path $Root 'store\Bookmarks'
            $archive = Join-Path $Root 'archive\Bookmarks'
            foreach ($i in 1..5) {
                $tmp = "$final.tmp-PC-A"
                $null = New-Item -ItemType Directory -Path $tmp -Force
                Set-Content -LiteralPath (Join-Path $tmp 'Bookmarks') -Value "v$i"
                Publish-EdgeSyncStoreItem -TempPath $tmp -FinalPath $final -ArchiveRoot $archive -PreviousMachine 'PC-A' -ArchiveRetention 3
                Test-Path -LiteralPath $tmp | Should -BeFalse
            }
            (Get-Content -LiteralPath (Join-Path $final 'Bookmarks')) | Should -Be 'v5'
            $versions = @(Get-ChildItem -LiteralPath $archive -Directory)
            $versions.Count | Should -Be 3
            $versions[0].Name | Should -Match '^\d{8}-\d{6}-PC-A'
            # The newest archived versions are kept (v2 and v1 were pruned).
            $kept = @($versions | ForEach-Object { Get-Content -LiteralPath (Join-Path $_.FullName 'Bookmarks') }) | Sort-Object
            $kept | Should -Be @('v2', 'v3', 'v4')
        }
    }

    It 'reads and writes the local state' {
        $path = Join-Path $TestDrive 'state\state.json'
        $null = New-Item -ItemType Directory -Path (Split-Path $path) -Force
        InModuleScope EdgeProfileSync -Parameters @{ Path = $path } {
            param($Path)
            $state = Read-EdgeSyncState -Path $Path
            $state.Items.Count | Should -Be 0
            Set-EdgeSyncStateItem -State $state -ItemKey 'Stable|Work|Bookmarks' -Fingerprint 'abc' -LocalFingerprint 'abc'
            Write-EdgeSyncState -Path $Path -State $state
            $again = Read-EdgeSyncState -Path $Path
            (Get-EdgeSyncStateItem -State $again -ItemKey 'Stable|Work|Bookmarks').Fingerprint | Should -Be 'abc'
        }
    }

    It 'survives a corrupt state file' {
        $path = Join-Path $TestDrive 'state2\state.json'
        $null = New-Item -ItemType Directory -Path (Split-Path $path) -Force
        Set-Content -LiteralPath $path -Value 'not { json'
        InModuleScope EdgeProfileSync -Parameters @{ Path = $path } {
            param($Path)
            $state = Read-EdgeSyncState -Path $Path -WarningAction SilentlyContinue
            $state.Items.Count | Should -Be 0
        }
        @(Get-ChildItem -LiteralPath (Split-Path $path) -Filter 'state.json.corrupt-*').Count | Should -Be 1
    }

    It 'removes account fields from the info_cache written to the store' {
        InModuleScope EdgeProfileSync {
            $clean = Get-EdgeSyncSanitizedInfoCache -InfoCache @{ name = 'Work'; user_name = 'a@b.c'; gaia_id = '1'; edge_account_type = 1; signin_x = 1; avatar_icon = 'x' }
            @($clean.Keys | Sort-Object) | Should -Be @('avatar_icon', 'name')
        }
    }
}

Describe 'Sync-EdgeProfiles between two machines' {
    BeforeAll {
        $script:SyncRoot = Join-Path $TestDrive 'OneDrive\EdgeProfileSync'
        $null = New-Item -ItemType Directory -Path (Split-Path $script:SyncRoot) -Force
        $script:UserData = @{
            'PC-A' = Join-Path $TestDrive 'PC-A\User Data'
            'PC-B' = Join-Path $TestDrive 'PC-B\User Data'
        }
        $script:Homes = @{
            'PC-A' = Join-Path $TestDrive 'PC-A\EdgeProfileSync'
            'PC-B' = Join-Path $TestDrive 'PC-B\EdgeProfileSync'
        }
        $script:ExtId = 'abcdefghijklmnopabcdefghijklmnop'
        $env:EPS_TEST_EDGE = 'closed'

        Mock -ModuleName EdgeProfileSync Get-EdgeSyncMachineId { $env:EPS_TEST_MACHINE }
        Mock -ModuleName EdgeProfileSync Get-EdgeProcessState {
            switch ($env:EPS_TEST_EDGE) {
                'windows' { [pscustomobject]@{ Running = $true; HasWindows = $true; ProcessCount = 12 } }
                'background' { [pscustomobject]@{ Running = $true; HasWindows = $false; ProcessCount = 5 } }
                default { [pscustomobject]@{ Running = $false; HasWindows = $false; ProcessCount = 0 } }
            }
        }
        # Never stop a real Edge.
        Mock -ModuleName EdgeProfileSync Stop-EdgeProcess { $true }
        # Spy on the SQLite snapshot helper (calls the real one).
        Mock -ModuleName EdgeProfileSync Copy-EdgeSqliteSnapshot {
            $bound = @{ Source = $Source; Destination = $Destination }
            & (Get-Module EdgeProfileSync) { param($a) & (Get-Command -Name Copy-EdgeSqliteSnapshot -CommandType Function) @a } $bound
        }
        # A profile counts as loaded in Edge when its path matches $env:EPS_TEST_INUSE.
        Mock -ModuleName EdgeProfileSync Test-EdgeProfileInUse { [bool]($env:EPS_TEST_INUSE -and $Path -like $env:EPS_TEST_INUSE) }
        # Removing profiles: the real helper, but deleting permanently instead of using the Recycle Bin.
        Mock -ModuleName EdgeProfileSync Remove-EdgeLocalProfile {
            $bound = @{ Directory = $Directory }
            if ($Channel) { $bound.Channel = $Channel }
            if ($UserDataRoot) { $bound.UserDataRoot = $UserDataRoot }
            & (Get-Module EdgeProfileSync) { param($a) & (Get-Command -Name Remove-EdgeLocalProfile -CommandType Function) @a -Permanent -Confirm:$false } $bound
        }

        # PC-A: profile "Work" with bookmarks, settings, history, collections and extension X with data.
        New-TestUserData -Root $script:UserData['PC-A'] -Profiles ([ordered]@{ 'Default' = 'Work' })
        $a = Join-Path $script:UserData['PC-A'] 'Default'
        $t0 = [datetime]::UtcNow.AddHours(-5)
        Set-TestFile -Path (Join-Path $a 'Bookmarks') -Content '{"roots":"A1"}' -TimeUtc $t0
        Set-TestFile -Path (Join-Path $a 'EncryptedBookmarks2') -Content 'machine-bound' -TimeUtc $t0
        Set-TestFile -Path (Join-Path $a 'Preferences') -Content '{"pref":"A"}' -TimeUtc $t0
        Set-TestFile -Path (Join-Path $a 'Secure Preferences') -Content (Get-TestSecurePreferences -ExtensionId $script:ExtId) -TimeUtc $t0
        Set-TestFile -Path (Join-Path $a 'History') -Content 'sqlite-history-A' -TimeUtc $t0
        Set-TestFile -Path (Join-Path $a 'Collections\collectionsSQLite') -Content 'collections-A' -TimeUtc $t0
        Set-TestFile -Path (Join-Path $a "Local Extension Settings\$($script:ExtId)\000003.log") -Content 'ext-data-A' -TimeUtc $t0
        Set-TestFile -Path (Join-Path $a 'Login Data') -Content 'secret' -TimeUtc $t0
        Set-TestFile -Path (Join-Path $a 'Cookies') -Content 'secret' -TimeUtc $t0

        # PC-B: only a "Personal" profile.
        New-TestUserData -Root $script:UserData['PC-B'] -Profiles ([ordered]@{ 'Default' = 'Personal' })
        Set-TestFile -Path (Join-Path $script:UserData['PC-B'] 'Default\Bookmarks') -Content '{"roots":"B-personal"}' -TimeUtc $t0
    }

    BeforeEach { $env:EPS_TEST_EDGE = 'closed'; $env:EPS_TEST_INUSE = $null }

    It 'PC-A pushes a new profile to the store' {
        $r = Invoke-TestSync -Machine 'PC-A'
        foreach ($cat in 'Bookmarks', 'Settings', 'SecurePreferences', 'Collections', 'History', 'ExtensionList', "ExtensionData:$($script:ExtId)") {
            (Get-TestResult $r 'Work' $cat).Action | Should -Be 'Push' -Because $cat
        }
        (Get-TestResult $r 'Work' 'Favicons').Action | Should -Be 'Skipped'
        @($r | Where-Object Action -eq 'Error').Count | Should -Be 0

        $store = Join-Path $script:SyncRoot 'store\Stable\Work'
        Get-Content -LiteralPath (Join-Path $store 'Bookmarks\Bookmarks') -Raw | Should -Be '{"roots":"A1"}'
        Test-Path -LiteralPath (Join-Path $store 'Collections\Collections\collectionsSQLite') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $store "ExtensionData\$($script:ExtId)\Local Extension Settings\000003.log") | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $store 'ExtensionList\extensions.json') | Should -BeTrue
        # Never synced: passwords, cookies, machine-bound encrypted bookmarks.
        @(Get-ChildItem -LiteralPath $script:SyncRoot -Recurse -File | Where-Object Name -in 'Login Data', 'Cookies', 'EncryptedBookmarks2').Count | Should -Be 0

        $profileJson = Get-Content -LiteralPath (Join-Path $store 'profile.json') -Raw | ConvertFrom-Json -AsHashtable
        $profileJson.Name | Should -Be 'Work'
        $profileJson.Machine | Should -Be 'PC-A'
        $profileJson.InfoCache.Keys | Should -Not -Contain 'user_name'
        $profileJson.InfoCache.Keys | Should -Not -Contain 'gaia_id'

        $manifest = Get-Content -LiteralPath (Join-Path $store 'manifest.json') -Raw | ConvertFrom-Json -AsHashtable
        $manifest.Categories.Bookmarks.Machine | Should -Be 'PC-A'
        $manifest.Categories.Keys | Should -Contain "ExtensionData:$($script:ExtId)"

        $summary = Get-Content -LiteralPath (Join-Path $script:SyncRoot 'machines\PC-A.json') -Raw | ConvertFrom-Json -AsHashtable
        $summary.MachineId | Should -Be 'PC-A'
        $summary.Errors.Count | Should -Be 0

        Test-Path -LiteralPath (Join-Path $script:Homes['PC-A'] 'state.json') | Should -BeTrue
    }

    It 'a second run on PC-A is in sync' {
        $r = Invoke-TestSync -Machine 'PC-A'
        @($r | Where-Object { $_.Profile -eq 'Work' -and $_.Action -notin 'InSync', 'Skipped' }).Count | Should -Be 0
        (Get-TestResult $r 'Work' 'Bookmarks').Action | Should -Be 'InSync'
    }

    It 'PC-B creates the profile and pulls its data, but not same-machine-only data or data of missing extensions' {
        $r = Invoke-TestSync -Machine 'PC-B'
        @($r | Where-Object Action -eq 'Error') | Should -BeNullOrEmpty

        $work = InModuleScope EdgeProfileSync -Parameters @{ Root = $script:UserData['PC-B'] } {
            param($Root) Get-EdgeLocalProfile -Channel Stable -UserDataRoot $Root | Where-Object Key -eq 'Work'
        }
        $work | Should -Not -BeNullOrEmpty
        $work.Directory | Should -Be 'Profile 1'
        $work.InfoCache.Keys | Should -Not -Contain 'user_name'
        $script:WorkB = $work.Path

        foreach ($cat in 'Bookmarks', 'Settings', 'Collections', 'History') {
            (Get-TestResult $r 'Work' $cat).Action | Should -Be 'Pull' -Because $cat
        }
        Get-Content -LiteralPath (Join-Path $work.Path 'Bookmarks') -Raw | Should -Be '{"roots":"A1"}'
        Get-Content -LiteralPath (Join-Path $work.Path 'Collections\collectionsSQLite') -Raw | Should -Be 'collections-A'

        # SameMachineOnly: Secure Preferences of PC-A is not applied on PC-B.
        (Get-TestResult $r 'Work' 'SecurePreferences').Action | Should -Be 'Skipped'
        Test-Path -LiteralPath (Join-Path $work.Path 'Secure Preferences') | Should -BeFalse

        # Extension X is not installed on PC-B: data stays in the store, X is pending.
        (Get-TestResult $r 'Work' "ExtensionData:$($script:ExtId)").Action | Should -Be 'Skipped'
        Test-Path -LiteralPath (Join-Path $work.Path "Local Extension Settings\$($script:ExtId)") | Should -BeFalse
        $pending = @(InModuleScope EdgeProfileSync { Get-EdgePendingExtension -Channel Stable -ProfileKey 'Work' })
        $pending.Id | Should -Contain $script:ExtId
        $pending[0].StoreUrl | Should -Be "https://microsoftedge.microsoft.com/addons/detail/$($script:ExtId)"

        # PC-B's own profile was pushed.
        (Get-TestResult $r 'Personal' 'Bookmarks').Action | Should -Be 'Push'
        Test-Path -LiteralPath (Join-Path $script:SyncRoot 'machines\PC-B.json') | Should -BeTrue
    }

    It 'PC-B edits bookmarks and pushes; PC-A pulls them' {
        Set-TestFile -Path (Join-Path $script:WorkB 'Bookmarks') -Content '{"roots":"B1"}' -TimeUtc ([datetime]::UtcNow.AddHours(-4))
        $rb = Invoke-TestSync -Machine 'PC-B'
        (Get-TestResult $rb 'Work' 'Bookmarks').Action | Should -Be 'Push'
        (Get-TestResult $rb 'Work' 'Settings').Action | Should -Be 'InSync'

        $ra = Invoke-TestSync -Machine 'PC-A'
        (Get-TestResult $ra 'Work' 'Bookmarks').Action | Should -Be 'Pull'
        $a = Join-Path $script:UserData['PC-A'] 'Default'
        Get-Content -LiteralPath (Join-Path $a 'Bookmarks') -Raw | Should -Be '{"roots":"B1"}'
        # MoveAsideOnRestore: the machine-bound EncryptedBookmarks2 was moved aside, not deleted.
        Test-Path -LiteralPath (Join-Path $a 'EncryptedBookmarks2') | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path $script:Homes['PC-A'] 'replaced') -Recurse -File -Filter 'EncryptedBookmarks2').Count | Should -Be 1
        # PC-A also learned about PC-B's profile.
        (Get-TestResult $ra 'Personal' 'Bookmarks').Action | Should -Be 'Pull'
    }

    It 'conflict: the newer store copy wins and the local loser is moved aside' {
        $a = Join-Path $script:UserData['PC-A'] 'Default'
        Set-TestFile -Path (Join-Path $a 'Bookmarks') -Content '{"roots":"A-old-edit"}' -TimeUtc ([datetime]::UtcNow.AddHours(-3))
        Set-TestFile -Path (Join-Path $script:WorkB 'Bookmarks') -Content '{"roots":"B-new-edit"}' -TimeUtc ([datetime]::UtcNow.AddHours(-2))
        (Get-TestResult (Invoke-TestSync -Machine 'PC-B') 'Work' 'Bookmarks').Action | Should -Be 'Push'

        $ra = Invoke-TestSync -Machine 'PC-A'
        (Get-TestResult $ra 'Work' 'Bookmarks').Action | Should -Be 'Conflict-Pull'
        Get-Content -LiteralPath (Join-Path $a 'Bookmarks') -Raw | Should -Be '{"roots":"B-new-edit"}'
        $loser = @(Get-ChildItem -LiteralPath (Join-Path $script:Homes['PC-A'] 'replaced') -Recurse -File -Filter 'Bookmarks' |
                Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -eq '{"roots":"A-old-edit"}' })
        $loser.Count | Should -Be 1
        $loser[0].Directory.Name | Should -Be 'Default'
    }

    It 'conflict: the newer local copy wins and the store loser is archived' {
        $a = Join-Path $script:UserData['PC-A'] 'Default'
        Set-TestFile -Path (Join-Path $script:WorkB 'Bookmarks') -Content '{"roots":"B-older"}' -TimeUtc ([datetime]::UtcNow.AddMinutes(-90))
        Set-TestFile -Path (Join-Path $a 'Bookmarks') -Content '{"roots":"A-newer"}' -TimeUtc ([datetime]::UtcNow.AddMinutes(-30))
        (Get-TestResult (Invoke-TestSync -Machine 'PC-B') 'Work' 'Bookmarks').Action | Should -Be 'Push'

        $ra = Invoke-TestSync -Machine 'PC-A'
        (Get-TestResult $ra 'Work' 'Bookmarks').Action | Should -Be 'Conflict-Push'
        Get-Content -LiteralPath (Join-Path $script:SyncRoot 'store\Stable\Work\Bookmarks\Bookmarks') -Raw | Should -Be '{"roots":"A-newer"}'
        $archived = @(Get-ChildItem -LiteralPath (Join-Path $script:SyncRoot 'archive\Stable\Work\Bookmarks') -Recurse -File -Filter 'Bookmarks' |
                Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -eq '{"roots":"B-older"}' })
        $archived.Count | Should -Be 1
        $archived[0].Directory.Name | Should -Match '^\d{8}-\d{6}-PC-B'

        $rb = Invoke-TestSync -Machine 'PC-B'
        (Get-TestResult $rb 'Work' 'Bookmarks').Action | Should -Be 'Pull'
        Get-Content -LiteralPath (Join-Path $script:WorkB 'Bookmarks') -Raw | Should -Be '{"roots":"A-newer"}'
    }

    It 'pushes everything (SQLite as snapshot) while Edge runs with windows' {
        $a = Join-Path $script:UserData['PC-A'] 'Default'
        Set-TestFile -Path (Join-Path $a 'Preferences') -Content '{"pref":"A2"}' -TimeUtc ([datetime]::UtcNow.AddMinutes(-25))
        Set-TestFile -Path (Join-Path $a 'History') -Content 'sqlite-history-A2' -TimeUtc ([datetime]::UtcNow.AddMinutes(-25))
        Set-TestFile -Path (Join-Path $a 'Collections\collectionsSQLite') -Content 'collections-A2' -TimeUtc ([datetime]::UtcNow.AddMinutes(-25))
        $env:EPS_TEST_EDGE = 'windows'
        $env:EPS_TEST_INUSE = $a
        $ra = Invoke-TestSync -Machine 'PC-A'
        foreach ($cat in 'Settings', 'History', 'Collections') { (Get-TestResult $ra 'Work' $cat).Action | Should -Be 'Push' -Because $cat }
        Should -Invoke -ModuleName EdgeProfileSync Copy-EdgeSqliteSnapshot -Scope It -ParameterFilter { $Source -like '*\History' }
        Should -Invoke -ModuleName EdgeProfileSync Copy-EdgeSqliteSnapshot -Scope It -ParameterFilter { $Source -like '*collectionsSQLite' }
        Get-Content -LiteralPath (Join-Path $script:SyncRoot 'store\Stable\Work\History\History') -Raw | Should -Be 'sqlite-history-A2'
        Get-Content -LiteralPath (Join-Path $script:SyncRoot 'store\Stable\Work\Collections\Collections\collectionsSQLite') -Raw | Should -Be 'collections-A2'
        Should -Invoke -ModuleName EdgeProfileSync Stop-EdgeProcess -Times 0 -Exactly -Scope It
    }

    It 'pulls into a profile that is not loaded while Edge runs, skips a loaded one' {
        $a = Join-Path $script:UserData['PC-A'] 'Default'
        $rb = Invoke-TestSync -Machine 'PC-B'
        (Get-TestResult $rb 'Work' 'History').Action | Should -Be 'Pull'

        # Edge runs with windows on PC-B, but only "Personal" is loaded there -> pull into Work is fine.
        Set-TestFile -Path (Join-Path $a 'Bookmarks') -Content '{"roots":"A-to-B-live"}' -TimeUtc ([datetime]::UtcNow.AddMinutes(-15))
        (Get-TestResult (Invoke-TestSync -Machine 'PC-A' -Extra @{ Category = 'Bookmarks' }) 'Work' 'Bookmarks').Action | Should -Be 'Push'
        $env:EPS_TEST_EDGE = 'windows'
        $env:EPS_TEST_INUSE = Join-Path $script:UserData['PC-B'] 'Default'
        $rb = Invoke-TestSync -Machine 'PC-B' -Extra @{ Category = 'Bookmarks' }
        (Get-TestResult $rb 'Work' 'Bookmarks').Action | Should -Be 'Pull'
        Get-Content -LiteralPath (Join-Path $script:WorkB 'Bookmarks') -Raw | Should -Be '{"roots":"A-to-B-live"}'

        # The loaded profile on PC-A is skipped while Edge has windows.
        Set-TestFile -Path (Join-Path $script:WorkB 'Bookmarks') -Content '{"roots":"B-again"}' -TimeUtc ([datetime]::UtcNow.AddMinutes(-12))
        $env:EPS_TEST_INUSE = $null
        (Get-TestResult (Invoke-TestSync -Machine 'PC-B' -Extra @{ Category = 'Bookmarks' }) 'Work' 'Bookmarks').Action | Should -Be 'Push'
        $env:EPS_TEST_INUSE = $a
        $ra = Invoke-TestSync -Machine 'PC-A' -Extra @{ CloseBackgroundEdge = $true }
        $bm = Get-TestResult $ra 'Work' 'Bookmarks'
        $bm.Action | Should -Be 'Skipped'
        $bm.Reason | Should -Match 'open windows'
        Get-Content -LiteralPath (Join-Path $a 'Bookmarks') -Raw | Should -Be '{"roots":"A-to-B-live"}'
        Should -Invoke -ModuleName EdgeProfileSync Stop-EdgeProcess -Times 0 -Exactly -Scope It

        # Windowless (background) Edge is stopped when allowed, then the pull happens.
        $env:EPS_TEST_EDGE = 'background'
        $ra = Invoke-TestSync -Machine 'PC-A' -Extra @{ CloseBackgroundEdge = $true }
        (Get-TestResult $ra 'Work' 'Bookmarks').Action | Should -Be 'Pull'
        Should -Invoke -ModuleName EdgeProfileSync Stop-EdgeProcess -Times 1 -Exactly -Scope It -ParameterFilter { $BackgroundOnly }
        Get-Content -LiteralPath (Join-Path $a 'Bookmarks') -Raw | Should -Be '{"roots":"B-again"}'
    }

    It 'does not stop background Edge when CloseBackgroundEdge is off' {
        Set-TestFile -Path (Join-Path $script:WorkB 'Bookmarks') -Content '{"roots":"B-bg"}' -TimeUtc ([datetime]::UtcNow.AddMinutes(-8))
        (Get-TestResult (Invoke-TestSync -Machine 'PC-B') 'Work' 'Bookmarks').Action | Should -Be 'Push'
        $env:EPS_TEST_EDGE = 'background'
        $env:EPS_TEST_INUSE = Join-Path $script:UserData['PC-A'] 'Default'
        $ra = Invoke-TestSync -Machine 'PC-A' -Extra @{ CloseBackgroundEdge = $false }
        (Get-TestResult $ra 'Work' 'Bookmarks').Action | Should -Be 'Skipped'
        Should -Invoke -ModuleName EdgeProfileSync Stop-EdgeProcess -Times 0 -Exactly -Scope It
        $env:EPS_TEST_EDGE = 'closed'
        $env:EPS_TEST_INUSE = $null
        (Get-TestResult (Invoke-TestSync -Machine 'PC-A') 'Work' 'Bookmarks').Action | Should -Be 'Pull'
    }

    It 'pulls extension data once the extension is installed and clears it from the pending list' {
        # Fake-install extension X on PC-B (as Edge would register it in Secure Preferences).
        Set-TestFile -Path (Join-Path $script:WorkB 'Secure Preferences') -Content (Get-TestSecurePreferences -ExtensionId $script:ExtId) -TimeUtc ([datetime]::UtcNow.AddMinutes(-5))
        $rb = Invoke-TestSync -Machine 'PC-B'
        (Get-TestResult $rb 'Work' "ExtensionData:$($script:ExtId)").Action | Should -Be 'Pull'
        Get-Content -LiteralPath (Join-Path $script:WorkB "Local Extension Settings\$($script:ExtId)\000003.log") -Raw | Should -Be 'ext-data-A'
        (Get-TestResult $rb 'Work' 'ExtensionList').Action | Should -Be 'InSync'
        @(InModuleScope EdgeProfileSync { Get-EdgePendingExtension -Channel Stable -ProfileKey 'Work' }).Count | Should -Be 0

        $again = Invoke-TestSync -Machine 'PC-B'
        (Get-TestResult $again 'Work' "ExtensionData:$($script:ExtId)").Action | Should -Be 'InSync'
    }

    It 'WhatIf changes nothing' {
        Set-TestFile -Path (Join-Path $script:WorkB 'Bookmarks') -Content '{"roots":"B-whatif"}' -TimeUtc ([datetime]::UtcNow.AddMinutes(-4))
        $env:EDGEPROFILESYNC_HOME = $script:Homes['PC-B']
        $stateBefore = Get-Content -LiteralPath (Join-Path $script:Homes['PC-B'] 'state.json') -Raw
        $r = Invoke-TestSync -Machine 'PC-B' -Extra @{ WhatIf = $true }
        $bm = Get-TestResult $r 'Work' 'Bookmarks'
        $bm.Action | Should -Be 'Push'
        $bm.Reason | Should -Match '^WhatIf'
        Get-Content -LiteralPath (Join-Path $script:SyncRoot 'store\Stable\Work\Bookmarks\Bookmarks') -Raw | Should -Not -Be '{"roots":"B-whatif"}'
        Get-Content -LiteralPath (Join-Path $script:Homes['PC-B'] 'state.json') -Raw | Should -Be $stateBefore
    }

    It 'Mode PullOnly does not push and -Quiet returns nothing' {
        $r = Invoke-TestSync -Machine 'PC-B' -Extra @{ Mode = 'PullOnly' }
        (Get-TestResult $r 'Work' 'Bookmarks').Action | Should -Be 'Skipped'
        (Get-TestResult $r 'Work' 'Bookmarks').Reason | Should -Match 'PullOnly'
        $quiet = Invoke-TestSync -Machine 'PC-B' -Extra @{ Quiet = $true }
        $quiet.Count | Should -Be 0
        Get-Content -LiteralPath (Join-Path $script:SyncRoot 'store\Stable\Work\Bookmarks\Bookmarks') -Raw | Should -Be '{"roots":"B-whatif"}'
    }

    It 'honours IncludeProfile / ExcludeProfile' {
        $r = Invoke-TestSync -Machine 'PC-A' -Extra @{ IncludeProfile = 'Pers*' }
        @($r | Where-Object Profile -eq 'Work').Count | Should -Be 0
        @($r | Where-Object Profile -eq 'Personal').Count | Should -BeGreaterThan 0
        $r = Invoke-TestSync -Machine 'PC-A' -Extra @{ ExcludeProfile = 'Personal' }
        @($r | Where-Object Profile -eq 'Personal').Count | Should -Be 0
    }

    It 'keeps only ArchiveRetention versions in the store archive' {
        $a = Join-Path $script:UserData['PC-A'] 'Default'
        foreach ($i in 1..5) {
            Set-TestFile -Path (Join-Path $a 'Bookmarks') -Content "{`"roots`":`"A-retention-$i`"}" -TimeUtc ([datetime]::UtcNow.AddSeconds(-60 + $i))
            $r = Invoke-TestSync -Machine 'PC-A' -Extra @{ ArchiveRetention = 2; Category = 'Bookmarks' }
            (Get-TestResult $r 'Work' 'Bookmarks').Action | Should -BeIn @('Push', 'Conflict-Push')
        }
        @(Get-ChildItem -LiteralPath (Join-Path $script:SyncRoot 'archive\Stable\Work\Bookmarks') -Directory).Count | Should -Be 2
        Get-Content -LiteralPath (Join-Path $script:SyncRoot 'store\Stable\Work\Bookmarks\Bookmarks') -Raw | Should -Be '{"roots":"A-retention-5"}'
    }

    It 'reports a failing category as Error and continues with the rest' {
        Mock -ModuleName EdgeProfileSync Copy-EdgeItem { throw 'disk full' } -ParameterFilter { $Source -like '*Bookmarks' }
        Set-TestFile -Path (Join-Path $script:UserData['PC-A'] 'Default\Bookmarks') -Content '{"roots":"A-fail"}' -TimeUtc ([datetime]::UtcNow)
        Set-TestFile -Path (Join-Path $script:UserData['PC-A'] 'Default\Preferences') -Content '{"pref":"A3"}' -TimeUtc ([datetime]::UtcNow)
        $r = Invoke-TestSync -Machine 'PC-A' -Extra @{ ErrorAction = 'SilentlyContinue' }
        (Get-TestResult $r 'Work' 'Bookmarks').Action | Should -Be 'Error'
        (Get-TestResult $r 'Work' 'Bookmarks').Reason | Should -Match 'disk full'
        (Get-TestResult $r 'Work' 'Settings').Action | Should -Be 'Push'
        Test-Path -LiteralPath (Join-Path $script:SyncRoot 'store\Stable\Work\Bookmarks.tmp-PC-A') | Should -BeFalse
        $summary = Get-Content -LiteralPath (Join-Path $script:SyncRoot 'machines\PC-A.json') -Raw | ConvertFrom-Json -AsHashtable
        $summary.Errors.Count | Should -BeGreaterThan 0
    }

    It 'does not re-create a tombstoned profile on another machine' {
        # PC-A creates "Test B", pushes it, then deletes it (tombstone) before PC-B ever saw it.
        $testB = InModuleScope EdgeProfileSync -Parameters @{ Root = $script:UserData['PC-A'] } {
            param($Root) New-EdgeLocalProfile -Name 'Test B' -Channel Stable -UserDataRoot $Root -Confirm:$false
        }
        Set-TestFile -Path (Join-Path $testB.Path 'Bookmarks') -Content '{"roots":"test-b"}'
        (Get-TestResult (Invoke-TestSync -Machine 'PC-A') 'Test B' 'Bookmarks').Action | Should -Be 'Push'

        InModuleScope EdgeProfileSync -Parameters @{ Root = $script:UserData['PC-A']; Dir = $testB.Directory; SyncRoot = $script:SyncRoot } {
            param($Root, $Dir, $SyncRoot)
            Remove-EdgeLocalProfile -Directory $Dir -UserDataRoot $Root -Permanent -Confirm:$false
            Set-EdgeSyncTombstone -SyncRoot $SyncRoot -Channel Stable -ProfileKey 'Test B' -Name 'Test B' -MachineId 'PC-A' -Confirm:$false
            @(Get-EdgeSyncTombstone -SyncRoot $SyncRoot -Channel Stable -ProfileKey 'Test B').Count | Should -Be 1
        }
        $ra = Invoke-TestSync -Machine 'PC-A'
        @($ra | Where-Object Profile -eq 'Test B').Count | Should -Be 0

        $rb = Invoke-TestSync -Machine 'PC-B'
        @($rb | Where-Object Profile -eq 'Test B').Count | Should -Be 0
        $keysB = InModuleScope EdgeProfileSync -Parameters @{ Root = $script:UserData['PC-B'] } { param($Root) @(Get-EdgeLocalProfile -UserDataRoot $Root | ForEach-Object Key) }
        $keysB | Should -Not -Contain 'Test B'
    }

    It 'removes a tombstoned profile locally only with RemoveDeletedProfiles and Edge closed' {
        # "Test A" exists on both machines, then PC-A deletes it.
        $testA = InModuleScope EdgeProfileSync -Parameters @{ Root = $script:UserData['PC-A'] } {
            param($Root) New-EdgeLocalProfile -Name 'Test A' -Channel Stable -UserDataRoot $Root -Confirm:$false
        }
        Set-TestFile -Path (Join-Path $testA.Path 'Bookmarks') -Content '{"roots":"test-a"}'
        (Get-TestResult (Invoke-TestSync -Machine 'PC-A') 'Test A' 'Bookmarks').Action | Should -Be 'Push'
        (Get-TestResult (Invoke-TestSync -Machine 'PC-B') 'Test A' 'Bookmarks').Action | Should -Be 'Pull'
        $onB = InModuleScope EdgeProfileSync -Parameters @{ Root = $script:UserData['PC-B'] } { param($Root) Get-EdgeLocalProfile -UserDataRoot $Root | Where-Object Key -eq 'Test A' }
        $onB | Should -Not -BeNullOrEmpty

        InModuleScope EdgeProfileSync -Parameters @{ SyncRoot = $script:SyncRoot } {
            param($SyncRoot) Set-EdgeSyncTombstone -SyncRoot $SyncRoot -Channel Stable -ProfileKey 'Test A' -Name 'Test A' -MachineId 'PC-A' -Confirm:$false
        }
        $rb = Invoke-TestSync -Machine 'PC-B' -Extra @{ RemoveDeletedProfiles = $false }
        @($rb | Where-Object Profile -eq 'Test A').Count | Should -Be 0
        Test-Path -LiteralPath $onB.Path | Should -BeTrue

        # Edge running: removal postponed.
        $env:EPS_TEST_EDGE = 'windows'
        $null = Invoke-TestSync -Machine 'PC-B' -Extra @{ RemoveDeletedProfiles = $true }
        Test-Path -LiteralPath $onB.Path | Should -BeTrue

        $env:EPS_TEST_EDGE = 'closed'
        $rb = Invoke-TestSync -Machine 'PC-B' -Extra @{ RemoveDeletedProfiles = $true }
        @($rb | Where-Object Profile -eq 'Test A').Count | Should -Be 0
        Test-Path -LiteralPath $onB.Path | Should -BeFalse
        $keysB = InModuleScope EdgeProfileSync -Parameters @{ Root = $script:UserData['PC-B'] } { param($Root) @(Get-EdgeLocalProfile -UserDataRoot $Root | ForEach-Object Key) }
        $keysB | Should -Not -Contain 'Test A'
        $keysB | Should -Contain 'Work'
        Should -Invoke -ModuleName EdgeProfileSync Remove-EdgeLocalProfile -Times 1 -Exactly -Scope It
    }

    It 'throws on a missing SyncRoot configuration' {
        $env:EDGEPROFILESYNC_HOME = Join-Path $TestDrive 'home-noroot'
        $savedA = $env:OneDrive; $savedB = $env:OneDriveCommercial
        try {
            $env:OneDrive = $null; $env:OneDriveCommercial = $null
            { Sync-EdgeProfiles -UserDataRoot $script:UserData['PC-A'] } | Should -Throw '*SyncRoot*'
        }
        finally { $env:OneDrive = $savedA; $env:OneDriveCommercial = $savedB }
    }
}
