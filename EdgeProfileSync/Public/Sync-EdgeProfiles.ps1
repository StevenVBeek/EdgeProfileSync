function Sync-EdgeProfiles {
    <#
    .SYNOPSIS
        Two-way sync of Microsoft Edge profiles between machines through a shared folder (OneDrive).

    .DESCRIPTION
        For every Edge channel, profile and data category (bookmarks, settings, history, collections,
        extension list and extension data, ...) the local copy is compared with the copy in the sync
        store (<SyncRoot>\store) and with the state of the last sync on this machine (3-way compare):

        - changed locally only        -> pushed to the store (the previous store copy is archived)
        - changed in the store only   -> pulled into the local profile
        - changed on both sides       -> the newer copy wins; the losing copy is archived (store) or
                                         moved to <LocalDataPath>\replaced\<timestamp>\ (local)

        Profiles that exist only in the store are created locally. Passwords, cookies and other
        machine-bound secrets are never synced. Data is pushed while Edge runs (SQLite files as consistent
        snapshots). Pulled data is written into a profile only while that profile is not loaded by a
        running Edge; for a loaded profile windowless (Startup Boost) Edge is stopped when
        CloseBackgroundEdge is on, otherwise the pull is skipped and retried on the next run. Creating a
        profile needs Edge of that channel fully closed. Profiles deleted on another machine with
        Remove-EdgeProfile (tombstones) are never pushed or re-created.

        Settings not given as parameters come from Get-EdgeProfileSyncConfig. Everything is logged to
        <LocalDataPath>\logs. One failing profile or category never stops the rest of the run; only
        configuration errors (no usable SyncRoot, unknown channel) throw.

    .PARAMETER SyncRoot
        Shared folder that holds the sync store (default: config, normally OneDrive\EdgeProfileSync).

    .PARAMETER Channel
        Edge channels to sync: Stable, Beta, Dev, Canary (default: config, normally Stable).

    .PARAMETER Category
        Data categories to sync (default: config, normally all default categories).

    .PARAMETER IncludeProfile
        Only sync profiles whose display name or key matches one of these patterns (wildcards allowed).

    .PARAMETER ExcludeProfile
        Skip profiles whose display name or key matches one of these patterns (wildcards allowed).

    .PARAMETER CloseBackgroundEdge
        Allow stopping windowless (background / Startup Boost) Edge to apply pulled data (default: config).

    .PARAMETER AllowLiveCopy
        Also push extension data (LevelDB) of a profile that is currently loaded in Edge. Such a copy may
        be inconsistent. (SQLite data is always pushed as a consistent snapshot, Edge open or not.)

    .PARAMETER RemoveDeletedProfiles
        Remove a profile locally (to the Recycle Bin) when it was deleted on another machine with
        Remove-EdgeProfile (tombstone in the store). Requires Edge of that channel fully closed.
        Default: config (normally $false: deleted profiles are only no longer synced).

    .PARAMETER ArchiveRetention
        Number of archived versions kept per profile/category in the store (default: config, 10).

    .PARAMETER Mode
        Both (default), PushOnly or PullOnly.

    .PARAMETER Quiet
        For scheduled runs: no progress bars, status lines, warnings, errors or result objects on the
        console; everything goes to the log. Without -Quiet the run shows a header (sync root, machine,
        channels, categories, Edge state), a progress bar per profile and category (with a child bar for
        large copies), a line per push / pull / conflict / error and a summary at the end.

    .PARAMETER UserDataRoot
        Test hook: overrides the Edge "User Data" folder for all channels.

    .OUTPUTS
        [pscustomobject] per channel, profile and category:
        @{ Channel; Profile; Category; Action; Reason } where Action is InSync, Push, Pull, Skipped,
        Conflict-Push, Conflict-Pull or Error. Extension data items are reported as "ExtensionData:<id>".

    .EXAMPLE
        Sync-EdgeProfiles

        Syncs all profiles of Edge Stable with the configured sync folder.

    .EXAMPLE
        Sync-EdgeProfiles -Category Bookmarks -IncludeProfile 'Work' -WhatIf

        Shows what would be synced for the bookmarks of the profile "Work", without changing anything.

    .EXAMPLE
        Sync-EdgeProfiles -Mode PushOnly -SyncRoot 'D:\Share\EdgeProfileSync'

        Only uploads local changes to a different sync folder.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$SyncRoot,

        [ValidateSet('Stable', 'Beta', 'Dev', 'Canary')]
        [string[]]$Channel,

        [string[]]$Category,

        [string[]]$IncludeProfile,

        [string[]]$ExcludeProfile,

        [bool]$CloseBackgroundEdge,

        [switch]$AllowLiveCopy,

        [bool]$RemoveDeletedProfiles,

        [ValidateRange(1, 1000)]
        [int]$ArchiveRetention,

        [ValidateSet('Both', 'PushOnly', 'PullOnly')]
        [string]$Mode = 'Both',

        [switch]$Quiet,

        [Parameter(DontShow)]
        [string]$UserDataRoot
    )

    $previousQuiet = $script:EdgeSyncQuiet
    $previousEdgeQuiet = $script:EdgeQuiet
    $script:EdgeSyncQuiet = [bool]$Quiet
    if ($Quiet) { $script:EdgeQuiet = $true }
    $mutex = $null
    $ownsMutex = $false
    $progress = $null
    $runWatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        # ---- configuration (errors here are fatal) ---------------------------------------------
        $config = $null
        try {
            $config = Get-EdgeProfileSyncConfig -WarningAction SilentlyContinue -ErrorAction Stop
        }
        catch {
            if (-not $SyncRoot) { throw "EdgeProfileSync configuration could not be read: $($_.Exception.Message)" }
            Write-EdgeSyncEvent "Configuration could not be read, using defaults: $($_.Exception.Message)" -Level Warning
        }

        if (-not $PSBoundParameters.ContainsKey('SyncRoot')) { $SyncRoot = [string](Get-EdgeSyncValue $config 'SyncRoot') }
        if (-not $PSBoundParameters.ContainsKey('Channel')) { $Channel = @(Get-EdgeSyncValue $config 'Channels' @('Stable')) }
        if (-not $PSBoundParameters.ContainsKey('Category')) { $Category = @(Get-EdgeSyncValue $config 'Categories' @((Get-EdgeDataCategory -DefaultOnly).Name)) }
        if (-not $PSBoundParameters.ContainsKey('IncludeProfile')) { $IncludeProfile = @(Get-EdgeSyncValue $config 'IncludeProfiles' @()) }
        if (-not $PSBoundParameters.ContainsKey('ExcludeProfile')) { $ExcludeProfile = @(Get-EdgeSyncValue $config 'ExcludeProfiles' @()) }
        if (-not $PSBoundParameters.ContainsKey('CloseBackgroundEdge')) { $CloseBackgroundEdge = ConvertTo-EdgeSyncBool (Get-EdgeSyncValue $config 'CloseBackgroundEdge') -Default $true }
        if (-not $PSBoundParameters.ContainsKey('RemoveDeletedProfiles')) { $RemoveDeletedProfiles = ConvertTo-EdgeSyncBool (Get-EdgeSyncValue $config 'RemoveDeletedProfiles') -Default $false }
        if (-not $PSBoundParameters.ContainsKey('ArchiveRetention')) { $ArchiveRetention = [int](Get-EdgeSyncValue $config 'ArchiveRetention' 10) }
        if ($ArchiveRetention -lt 1) { $ArchiveRetention = 1 }
        $IncludeProfile = @($IncludeProfile | Where-Object { $_ })
        $ExcludeProfile = @($ExcludeProfile | Where-Object { $_ })

        if ([string]::IsNullOrWhiteSpace($SyncRoot)) {
            throw 'No SyncRoot configured and no OneDrive folder found. Use -SyncRoot or Set-EdgeProfileSyncConfig -SyncRoot.'
        }
        $SyncRoot = [IO.Path]::GetFullPath($SyncRoot)
        if (-not (Test-Path -LiteralPath $SyncRoot -PathType Container)) {
            $parent = Split-Path -Path $SyncRoot -Parent
            if (-not $parent -or -not (Test-Path -LiteralPath $parent -PathType Container)) {
                throw "SyncRoot '$SyncRoot' does not exist and neither does its parent folder."
            }
            if (-not $WhatIfPreference) { $null = New-Item -Path $SyncRoot -ItemType Directory -Force -ErrorAction Stop }
        }
        foreach ($ch in $Channel) {
            if ($ch -notin 'Stable', 'Beta', 'Dev', 'Canary') { throw "Unknown Edge channel '$ch' in configuration." }
        }

        $knownCategories = @(Get-EdgeDataCategoryName)
        $unknown = @($Category | Where-Object { $_ -notin $knownCategories })
        foreach ($u in $unknown) {
            Write-EdgeSyncEvent "Unknown category '$u' ignored." -Level Warning
            Write-EdgeStatus "Unknown category '$u' ignored." -Level Warning
        }
        $categories = @(Get-EdgeDataCategory -Name @($Category | Where-Object { $_ -in $knownCategories }))

        $machineId = Get-EdgeSyncMachineId
        $localDataPath = Get-EdgeSyncLocalDataPath
        $statePath = Join-Path $localDataPath 'state.json'
        $runStamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')
        $startedUtc = [datetime]::UtcNow
        $isWhatIf = [bool]$WhatIfPreference
        $logFile = Join-Path $localDataPath ('logs\EdgeProfileSync-{0}.log' -f (Get-Date).ToString('yyyyMMdd'))
        $multiChannel = @($Channel).Count -gt 1

        # ---- one run at a time per user/data folder ---------------------------------------------
        $mutexName = 'Local\EdgeProfileSync-' + (Get-EdgeSyncSha256 -Text $localDataPath.ToLowerInvariant()).Substring(0, 16)
        $mutex = [System.Threading.Mutex]::new($false, $mutexName)
        try { $ownsMutex = $mutex.WaitOne([TimeSpan]::FromSeconds(5)) }
        catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) {
            Write-EdgeSyncEvent 'Another Sync-EdgeProfiles run is in progress; this run is skipped.' -Level Warning
            Write-EdgeStatus 'Another Sync-EdgeProfiles run is in progress (for example the scheduled task); this run is skipped.' -Level Warning
            return
        }

        Write-EdgeSyncEvent ("Sync started: machine {0}, mode {1}, channels {2}, categories {3}, store '{4}'{5}." -f
            $machineId, $Mode, ($Channel -join ','), (($categories | ForEach-Object { $_.Name }) -join ','), $SyncRoot, $(if ($isWhatIf) { ' (WhatIf)' } else { '' }))

        $state = Read-EdgeSyncState -Path $statePath
        $results = [System.Collections.Generic.List[object]]::new()
        $profileSummary = [System.Collections.Generic.List[object]]::new()
        $errors = [System.Collections.Generic.List[string]]::new()

        # Console statistics (never written to the success stream).
        $bytesStat = @{ Pushed = [long]0; Pulled = [long]0 }
        $loadedProfiles = [System.Collections.Generic.List[string]]::new()
        $createdProfiles = [System.Collections.Generic.List[string]]::new()
        $pendingByProfile = [ordered]@{}
        $changedProfiles = 0

        $addResult = {
            param($r, [long]$Bytes = 0)
            $results.Add($r)
            $level = switch ($r.Action) { 'Error' { 'Error' } 'Skipped' { 'Info' } 'InSync' { 'Verbose' } default { 'Info' } }
            Write-EdgeSyncEvent ('{0}/{1}/{2}: {3} - {4}' -f $r.Channel, $r.Profile, $r.Category, $r.Action, $r.Reason) -Level $level
            if ($r.Action -eq 'Error') { $errors.Add(('{0}/{1}/{2}: {3}' -f $r.Channel, $r.Profile, $r.Category, $r.Reason)) }

            # Console: one line per thing that actually happens (InSync and Skipped are summarised per profile).
            $what = if ($multiChannel) { '{0}/{1}/{2}' -f $r.Channel, $r.Profile, $r.Category } else { '{0}/{1}' -f $r.Profile, $r.Category }
            $size = if ($Bytes -gt 0) { ' ({0})' -f (Format-EdgeSize $Bytes) } else { '' }
            switch ($r.Action) {
                'Push' { Write-EdgeStatus ('  {0} {1}{2} - {3}' -f $(if ($isWhatIf) { 'Would push' } else { 'Pushed' }), $what, $size, $r.Reason) -Level Step }
                'Pull' { Write-EdgeStatus ('  {0} {1}{2} - {3}' -f $(if ($isWhatIf) { 'Would pull' } else { 'Pulled' }), $what, $size, $r.Reason) -Level Step }
                'Conflict-Push' { Write-EdgeStatus ('  Conflict {0}: local copy is newer and wins, {1}{2}; the store copy is archived.' -f $what, $(if ($isWhatIf) { 'would be pushed' } else { 'pushed' }), $size) -Level Warning }
                'Conflict-Pull' { Write-EdgeStatus ('  Conflict {0}: store copy wins, {1}{2}; the local copy is moved to the replaced folder. {3}' -f $what, $(if ($isWhatIf) { 'would be pulled' } else { 'pulled' }), $size, $r.Reason) -Level Warning }
                'Error' { Write-EdgeStatus ('  Error {0}: {1}' -f $what, $r.Reason) -Level Warning }
            }
        }
        $matchesAny = {
            param([string[]]$Patterns, [string[]]$Values)
            foreach ($pattern in $Patterns) { foreach ($v in $Values) { if ($v -and $v -like $pattern) { return $true } } }
            $false
        }
        # Skips that happen on every run and are not worth a console line.
        $isRoutineSkip = {
            param([string]$Reason)
            $Reason -eq 'No data locally or in the store.' -or $Reason -like '*same-machine-only*' -or $Reason -like '*(pending extensions)*'
        }

        # ---- plan: profiles per channel (so the progress bar knows the total) -------------------
        $plans = [System.Collections.Generic.List[object]]::new()
        foreach ($ch in $Channel) {
            try {
                $channelInfo = Get-EdgeChannelInfo -Channel $ch -UserDataRoot $UserDataRoot
                if (-not $channelInfo.Installed) {
                    Write-EdgeSyncEvent "Edge $ch has no User Data folder ('$($channelInfo.UserDataPath)'); channel skipped."
                    Write-EdgeStatus "Edge $ch has no User Data folder ('$($channelInfo.UserDataPath)'); channel skipped." -Level Warning
                    continue
                }

                $localProfiles = @(Get-EdgeLocalProfile -Channel $ch -UserDataRoot $UserDataRoot)
                $storeProfiles = @(Get-EdgeSyncStoreProfile -SyncRoot $SyncRoot -Channel $ch)
                $tombstones = @{}
                foreach ($t in @(Get-EdgeSyncTombstone -SyncRoot $SyncRoot -Channel $ch)) { $tombstones[$t.Key] = $t }

                $keys = [System.Collections.Generic.List[string]]::new()
                $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($k in @($localProfiles | ForEach-Object { $_.Key }) + @($storeProfiles | ForEach-Object { $_.Key })) { if ($k -and $seen.Add($k)) { $keys.Add($k) } }

                $entries = [System.Collections.Generic.List[object]]::new()
                foreach ($key in $keys) {
                    $local = $localProfiles | Where-Object { $_.Key -eq $key } | Select-Object -First 1
                    $stored = $storeProfiles | Where-Object { $_.Key -eq $key } | Select-Object -First 1
                    $displayName = if ($local) { $local.Name } elseif ($stored) { $stored.Name } else { $key }

                    if ($IncludeProfile.Count -and -not (& $matchesAny $IncludeProfile @($displayName, $key))) { continue }
                    if ($ExcludeProfile.Count -and (& $matchesAny $ExcludeProfile @($displayName, $key))) { continue }
                    $entries.Add([pscustomobject]@{ Key = $key; Local = $local; Stored = $stored; DisplayName = $displayName })
                }
                $plans.Add([pscustomobject]@{
                        Channel       = $ch
                        LocalProfiles = $localProfiles
                        StoreProfiles = $storeProfiles
                        Tombstones    = $tombstones
                        Entries       = $entries
                    })
            }
            catch {
                $r = [pscustomobject]@{ Channel = $ch; Profile = '*'; Category = '*'; Action = 'Error'; Reason = $_.Exception.Message }
                & $addResult $r
            }
        }

        $totalProfiles = 0
        foreach ($plan in $plans) { $totalProfiles += $plan.Entries.Count }
        $catCount = [Math]::Max(1, $categories.Count)

        # ---- header (interactive only; the Edge state probe is skipped for -Quiet runs) ----------
        if (-not $script:EdgeQuiet) {
            Write-EdgeStatus ('Edge profile sync{0}' -f $(if ($isWhatIf) { ' (WhatIf: nothing is changed)' } else { '' })) -Level Header
            Write-EdgeStatus ('  Sync root  : {0}' -f $SyncRoot) -Level Header
            Write-EdgeStatus ('  Machine    : {0}' -f $machineId) -Level Header
            Write-EdgeStatus ('  Mode       : {0}' -f $Mode) -Level Header
            Write-EdgeStatus ('  Channels   : {0}' -f ($Channel -join ', ')) -Level Header
            Write-EdgeStatus ('  Categories : {0}' -f $(if ($categories.Count) { ($categories | ForEach-Object { $_.Name }) -join ', ' } else { '(none)' })) -Level Header
            foreach ($plan in $plans) {
                $edgeText = 'unknown'
                $loadedNames = @()
                try {
                    $ps = Get-EdgeProcessState -Channel $plan.Channel
                    $windowCount = Get-EdgeSyncValue $ps 'WindowCount'
                    $edgeText = if (-not $ps.Running) { 'closed' }
                    elseif (-not $ps.HasWindows) { 'running in the background ({0} processes, no windows)' -f $ps.ProcessCount }
                    elseif ($null -ne $windowCount) { 'running with {0} window(s)' -f $windowCount }
                    else { 'running with open windows ({0} processes)' -f $ps.ProcessCount }
                    if ($ps.Running) {
                        $loadedNames = @($plan.LocalProfiles | Where-Object { $_ -and (Test-EdgeProfileInUse -Path $_.Path) } | ForEach-Object { $_.Name })
                    }
                }
                catch { Write-Verbose "Edge state of $($plan.Channel) could not be determined: $($_.Exception.Message)" }
                Write-EdgeStatus ('  {0,-11}: {1}; {2} profile(s) to sync ({3} local, {4} in the store)' -f "Edge $($plan.Channel)", $edgeText, $plan.Entries.Count, $plan.LocalProfiles.Count, $plan.StoreProfiles.Count) -Level Header
                if ($loadedNames.Count) {
                    Write-EdgeStatus ('  Loaded     : {0} (data is pushed; pulls into these profiles wait until they are closed)' -f ($loadedNames -join ', ')) -Level Header
                }
            }
            Write-EdgeStatus ('  To do      : {0} profile(s) x {1} categories' -f $totalProfiles, $categories.Count) -Level Header
        }

        $progress = New-EdgeProgress -Activity ('Syncing Edge profiles{0}' -f $(if ($isWhatIf) { ' (WhatIf)' } else { '' })) -Total ($totalProfiles * $catCount) -Unit Steps -Id 1
        Update-EdgeProgress -Progress $progress -Status 'Starting' -Force
        $profileIndex = 0
        $indexWidth = ([string]$totalProfiles).Length

        foreach ($plan in $plans) {
            $ch = $plan.Channel
            try {
                $ctx = [pscustomobject]@{
                    Cmdlet              = $PSCmdlet
                    Channel             = $ch
                    MachineId           = $machineId
                    LocalDataPath       = $localDataPath
                    RunStamp            = $runStamp
                    State               = $state
                    Mode                = $Mode
                    AllowLiveCopy       = [bool]$AllowLiveCopy
                    CloseBackgroundEdge = [bool]$CloseBackgroundEdge
                    ArchiveRetention    = $ArchiveRetention
                    Gate                = [pscustomobject]@{ Closed = $null; Reason = '' }
                    WhatIf              = $isWhatIf
                    Progress            = $progress
                    ProgressId          = 1
                    ProgressLabel       = ''
                }
                $tombstones = $plan.Tombstones

                foreach ($entry in $plan.Entries) {
                    $key = $entry.Key
                    $local = $entry.Local
                    $stored = $entry.Stored
                    $displayName = $entry.DisplayName

                    $profileIndex++
                    $stepsBefore = $progress.Done
                    $profileTag = '[{0}/{1}]' -f ([string]$profileIndex).PadLeft($indexWidth), $totalProfiles
                    $profileLabel = "Profile $profileIndex/$totalProfiles '$displayName'" + $(if ($multiChannel) { " ($ch)" } else { '' })
                    $ctx.ProgressLabel = $profileLabel
                    Update-EdgeProgress -Progress $progress -Status $profileLabel -Force
                    $profileResults = [System.Collections.Generic.List[object]]::new()
                    $profileBytes = @{}
                    $pctx = $null

                    try {
                        # ---- tombstoned (deleted on purpose somewhere): never push, never re-create
                        if ($tombstones.ContainsKey($key)) {
                            $tomb = $tombstones[$key]
                            try {
                                $recreated = $false
                                if ($local -and -not (Test-EdgeSyncStateProfile -State $state -Channel $ch -Key $key) -and $tomb.DeletedUtc) {
                                    $recreated = (Get-Item -LiteralPath $local.Path -Force).CreationTimeUtc -gt $tomb.DeletedUtc
                                }
                                if ($recreated) {
                                    # A profile created again after the deletion: it may sync again.
                                    if (-not $isWhatIf) { Remove-EdgeSyncTombstone -SyncRoot $SyncRoot -Channel $ch -ProfileKey $key -Confirm:$false }
                                    Write-EdgeStatus "$profileTag ${displayName}: created again after it was deleted on $($tomb.Machine); the deletion mark is removed and the profile syncs again." -Level Info
                                }
                                else {
                                    if (-not $local) {
                                        # Forget the sync history so a later re-created profile counts as new.
                                        if (-not $isWhatIf -and (Test-EdgeSyncStateProfile -State $state -Channel $ch -Key $key)) {
                                            Clear-EdgeSyncStateProfile -State $state -Channel $ch -Key $key
                                            Write-EdgeSyncState -Path $statePath -State $state
                                        }
                                        Write-EdgeSyncEvent "Edge $ch profile '$key' was deleted on $($tomb.Machine); not synced." -Level Verbose
                                    }
                                    elseif (-not $RemoveDeletedProfiles) {
                                        Write-EdgeSyncEvent "Edge $ch profile '$key' was deleted on $($tomb.Machine) ($($tomb.DeletedUtc)); it is no longer synced. Remove it here with Remove-EdgeProfile or enable RemoveDeletedProfiles."
                                        Write-EdgeStatus "$profileTag ${displayName}: deleted on $($tomb.Machine); no longer synced (remove it here with Remove-EdgeProfile or enable RemoveDeletedProfiles)." -Level Warning
                                    }
                                    elseif (-not (Confirm-EdgeSyncChannelClosed -Context $ctx)) {
                                        Write-EdgeSyncEvent "Edge $ch profile '$key' was deleted on $($tomb.Machine); local removal postponed: $($ctx.Gate.Reason)"
                                        Write-EdgeStatus "$profileTag ${displayName}: deleted on $($tomb.Machine); local removal postponed: $($ctx.Gate.Reason)" -Level Warning
                                    }
                                    elseif ($PSCmdlet.ShouldProcess("Edge $ch profile '$($local.Name)' ($($local.Directory))", 'Remove local profile deleted on another machine')) {
                                        Remove-EdgeLocalProfile -Directory $local.Directory -Channel $ch -UserDataRoot $UserDataRoot -Confirm:$false
                                        Clear-EdgeSyncStateProfile -State $state -Channel $ch -Key $key
                                        Write-EdgeSyncState -Path $statePath -State $state
                                        Write-EdgeSyncEvent "Removed Edge $ch profile '$($local.Name)' ($($local.Directory)) because it was deleted on $($tomb.Machine) (Recycle Bin)."
                                        Write-EdgeStatus "$profileTag ${displayName}: removed locally (Recycle Bin) because it was deleted on $($tomb.Machine)." -Level Success
                                    }
                                    continue
                                }
                            }
                            catch {
                                $r = [pscustomobject]@{ Channel = $ch; Profile = $key; Category = '*'; Action = 'Error'; Reason = "Deleted profile handling failed: $($_.Exception.Message)" }
                                & $addResult $r
                                $profileResults.Add($r)
                                continue
                            }
                        }

                        try {
                            $location = Get-EdgeSyncStoreLocation -SyncRoot $SyncRoot -Channel $ch -Key $key
                            $pctx = [pscustomobject]@{
                                Key               = $key
                                Profile           = $local
                                Location          = $location
                                Manifest          = (Read-EdgeSyncManifest -StoreProfilePath $location.Store)
                                Inventory         = $null
                                PushedAny         = $false
                                Writable          = $null
                                GateReason        = ''
                                LastBytes         = [long]0
                                PendingExtensions = $null
                            }

                            # ---- profile only in the store: create it locally first
                            if (-not $local) {
                                $pullable = @(foreach ($cat in $categories) {
                                        if ($cat.Generated -or $cat.PerExtension) { continue }
                                        $e = $pctx.Manifest.Categories[$cat.Name]
                                        if (-not $e) { continue }
                                        if ($cat.SameMachineOnly -and [string](Get-EdgeSyncValue $e 'Machine') -ne $machineId) { continue }
                                        $cat.Name
                                    })
                                $skipAll = $null
                                if ($Mode -eq 'PushOnly') { $skipAll = 'Profile exists only in the store; Mode PushOnly.' }
                                elseif (-not $pullable.Count) { $skipAll = 'Profile exists only in the store and has no data that applies to this machine.' }
                                elseif (-not (Confirm-EdgeSyncChannelClosed -Context $ctx)) { $skipAll = "Profile exists only in the store; cannot create it now: $($ctx.Gate.Reason)" }

                                if (-not $skipAll) {
                                    $infoCache = Get-EdgeSyncValue $stored.Info 'InfoCache'
                                    if ($infoCache -isnot [System.Collections.IDictionary]) { $infoCache = @{} }
                                    if ($PSCmdlet.ShouldProcess("Edge $ch profile '$displayName'", 'Create local profile')) {
                                        Update-EdgeProgress -Progress $progress -Status "${profileLabel}: creating the local profile" -Force
                                        $local = New-EdgeLocalProfile -Name $displayName -InfoCache $infoCache -Channel $ch -UserDataRoot $UserDataRoot -Confirm:$false
                                        if (-not $local) { throw "Creating local profile '$displayName' failed." }
                                        Write-EdgeSyncEvent "Created local Edge $ch profile '$displayName' in '$($local.Directory)' from the sync store."
                                        Write-EdgeStatus "$profileTag ${displayName}: new profile, created locally in '$($local.Directory)' from the sync store." -Level Success
                                        $createdProfiles.Add($displayName)
                                        $pctx.Profile = $local
                                    }
                                    else {
                                        $skipAll = if ($isWhatIf) { 'WhatIf: profile would be created locally and its data pulled.' } else { 'Declined: create local profile.' }
                                    }
                                }
                                if ($skipAll) {
                                    $action = if ($isWhatIf -and $skipAll.StartsWith('WhatIf')) { 'Pull' } else { 'Skipped' }
                                    foreach ($cat in $categories) {
                                        $r = [pscustomobject]@{ Channel = $ch; Profile = $key; Category = $cat.Name; Action = $action; Reason = $skipAll }
                                        & $addResult $r
                                        $profileResults.Add($r)
                                    }
                                    continue
                                }
                            }

                            # ---- categories
                            $catIndex = 0
                            foreach ($cat in $categories) {
                                $catIndex++
                                try {
                                    $extensionIds = @($null)
                                    $ctx.ProgressLabel = "$profileLabel - $($cat.Name)"
                                    if ($cat.PerExtension) {
                                        try {
                                            Update-EdgeProgress -Progress $progress -Status "$($ctx.ProgressLabel): listing extensions"
                                            $inventory = Get-EdgeSyncProfileInventory -ProfileContext $pctx
                                            $extensionIds = @(Get-EdgeSyncExtensionDataId -ProfilePath $pctx.Profile.Path -Category $cat -LocalInventory $inventory -Manifest $pctx.Manifest)
                                        }
                                        catch {
                                            $r = [pscustomobject]@{ Channel = $ch; Profile = $key; Category = $cat.Name; Action = 'Error'; Reason = $_.Exception.Message }
                                            & $addResult $r; $profileResults.Add($r)
                                            continue
                                        }
                                        if (-not $extensionIds.Count) { continue }
                                    }
                                    $extIndex = 0
                                    foreach ($extId in $extensionIds) {
                                        $extIndex++
                                        if ($extId) { $ctx.ProgressLabel = '{0} - {1} {2}/{3}' -f $profileLabel, $cat.Name, $extIndex, $extensionIds.Count }
                                        $pctx.LastBytes = [long]0
                                        try {
                                            $r = Invoke-EdgeSyncItem -Context $ctx -ProfileContext $pctx -Category $cat -ExtensionId $extId
                                        }
                                        catch {
                                            $itemName = if ($extId) { '{0}:{1}' -f $cat.Name, $extId } else { $cat.Name }
                                            $r = [pscustomobject]@{ Channel = $ch; Profile = $key; Category = $itemName; Action = 'Error'; Reason = $_.Exception.Message }
                                        }
                                        $bytes = [long]$pctx.LastBytes
                                        if ($r.Action -in 'Push', 'Conflict-Push') { $bytesStat.Pushed += $bytes }
                                        elseif ($r.Action -in 'Pull', 'Conflict-Pull') { $bytesStat.Pulled += $bytes }
                                        else { $bytes = 0 }
                                        if ($bytes -gt 0) { $profileBytes[$r.Category] = $bytes }
                                        & $addResult $r $bytes
                                        $profileResults.Add($r)
                                    }
                                }
                                finally {
                                    Update-EdgeProgress -Progress $progress -Done ($stepsBefore + $catIndex) -Status $profileLabel
                                }
                            }

                            # ---- profile.json (display name / avatar for other machines)
                            if (-not $isWhatIf -and $pctx.Profile -and ($pctx.PushedAny -or -not (Test-Path -LiteralPath (Join-Path $location.Store 'profile.json')))) {
                                if ($pctx.PushedAny -or (Test-Path -LiteralPath $location.Store -PathType Container)) {
                                    Write-EdgeSyncProfileInfo -StoreProfilePath $location.Store -LocalProfile $pctx.Profile -Key $key -MachineId $machineId
                                }
                            }
                        }
                        catch {
                            $r = [pscustomobject]@{ Channel = $ch; Profile = $key; Category = '*'; Action = 'Error'; Reason = $_.Exception.Message }
                            & $addResult $r
                            $profileResults.Add($r)
                        }
                        finally {
                            if (-not $isWhatIf) {
                                try { Write-EdgeSyncState -Path $statePath -State $state }
                                catch { $errors.Add("Writing local state failed: $($_.Exception.Message)"); Write-EdgeSyncEvent "Writing local state '$statePath' failed: $($_.Exception.Message)" -Level Error }
                            }
                        }

                        $actions = [ordered]@{}
                        foreach ($g in @($profileResults | Group-Object Action)) { $actions[$g.Name] = $g.Count }
                        $profileSummary.Add([ordered]@{
                                Channel = $ch
                                Key     = $key
                                Name    = $displayName
                                Actions = $actions
                            })
                    }
                    finally {
                        # ---- one compact console line per profile with changes (also after 'continue')
                        try {
                            $shortName = {
                                param([string]$Name)
                                if ($Name -like 'ExtensionData:*') { 'ExtensionData:' + $Name.Substring(14, [Math]::Min(8, $Name.Length - 14)) + '...' } else { $Name }
                            }
                            $pushed = @($profileResults | Where-Object Action -in 'Push', 'Conflict-Push' | ForEach-Object { (& $shortName $_.Category) + $(if ($_.Action -eq 'Conflict-Push') { ' (conflict)' } else { '' }) })
                            $pulled = @($profileResults | Where-Object Action -in 'Pull', 'Conflict-Pull' | ForEach-Object { (& $shortName $_.Category) + $(if ($_.Action -eq 'Conflict-Pull') { ' (conflict)' } else { '' }) })
                            $failed = @($profileResults | Where-Object Action -eq 'Error' | ForEach-Object { & $shortName $_.Category })
                            $parts = @()
                            if ($pushed.Count) { $parts += ('{0} {1}' -f $(if ($isWhatIf) { 'would push' } else { 'pushed' }), ($pushed -join ', ')) }
                            if ($pulled.Count) { $parts += ('{0} {1}' -f $(if ($isWhatIf) { 'would pull' } else { 'pulled' }), ($pulled -join ', ')) }
                            if ($failed.Count) { $parts += ('failed {0}' -f ($failed -join ', ')) }
                            if ($parts.Count) {
                                $changedProfiles++
                                [long]$sum = 0
                                foreach ($v in $profileBytes.Values) { $sum += $v }
                                $sizeText = if ($sum -gt 0) { ' ({0})' -f (Format-EdgeSize $sum) } else { '' }
                                Write-EdgeStatus ('{0} {1}: {2}{3}' -f $profileTag, $displayName, ($parts -join '; '), $sizeText) -Level $(if ($failed.Count) { 'Warning' } else { 'Success' })
                            }
                            $skips = @($profileResults | Where-Object { $_.Action -eq 'Skipped' -and -not (& $isRoutineSkip $_.Reason) } | Group-Object Reason)
                            foreach ($g in $skips) {
                                $what = if ($g.Count -ge $categories.Count -and $categories.Count -gt 1) { 'all categories' } else { (@($g.Group | ForEach-Object { & $shortName $_.Category }) -join ', ') }
                                Write-EdgeStatus ('{0} {1}: skipped {2} - {3}' -f $profileTag, $displayName, $what, $g.Name) -Level Warning
                            }
                            if (@($profileResults | Where-Object { $_.Action -eq 'Skipped' -and $_.Reason -like 'Profile is loaded in Edge*' }).Count) {
                                $loadedProfiles.Add($(if ($multiChannel) { "$displayName ($ch)" } else { $displayName }))
                            }
                            if ($pctx) {
                                $pend = @(Get-EdgeSyncValue $pctx 'PendingExtensions' @() | Where-Object { $_ })
                                if ($pend.Count) { $pendingByProfile[$(if ($multiChannel) { "$displayName ($ch)" } else { $displayName })] = $pend }
                            }
                        }
                        catch { Write-Verbose "Progress output failed: $($_.Exception.Message)" }
                        Update-EdgeProgress -Progress $progress -Done ($stepsBefore + $catCount) -Status $profileLabel
                    }
                }
            }
            catch {
                $r = [pscustomobject]@{ Channel = $ch; Profile = '*'; Category = '*'; Action = 'Error'; Reason = $_.Exception.Message }
                & $addResult $r
            }
        }

        # ---- housekeeping and machine summary
        if (-not $isWhatIf) {
            Update-EdgeProgress -Progress $progress -Status 'Housekeeping: pruning old replaced copies, writing the machine summary' -Force
            try { Remove-EdgeSyncOldReplaced -LocalDataPath $localDataPath -Keep $ArchiveRetention }
            catch { Write-EdgeSyncEvent "Pruning replaced folder failed: $($_.Exception.Message)" -Level Warning }

            try {
                $moduleVersion = $null
                if ($MyInvocation.MyCommand.Module) { $moduleVersion = [string]$MyInvocation.MyCommand.Module.Version }
                $counts = [ordered]@{}
                foreach ($g in @($results | Group-Object Action)) { $counts[$g.Name] = $g.Count }
                Write-EdgeSyncMachineSummary -SyncRoot $SyncRoot -MachineId $machineId -Summary ([ordered]@{
                        MachineId     = $machineId
                        ComputerName  = $env:COMPUTERNAME
                        UserName      = $env:USERNAME
                        ModuleVersion = $moduleVersion
                        StartedUtc    = $startedUtc.ToString('o')
                        FinishedUtc   = [datetime]::UtcNow.ToString('o')
                        Mode          = $Mode
                        Channels      = @($Channel)
                        Categories    = @($categories | ForEach-Object { $_.Name })
                        Counts        = $counts
                        Profiles      = @($profileSummary)
                        Errors        = @($errors)
                    })
            }
            catch { Write-EdgeSyncEvent "Writing machine summary failed: $($_.Exception.Message)" -Level Warning }
        }

        $summaryText = (@($results | Group-Object Action | ForEach-Object { '{0} {1}' -f $_.Count, $_.Name }) -join ', ')
        Write-EdgeSyncEvent ("Sync finished: {0}." -f $(if ($summaryText) { $summaryText } else { 'nothing to do' })) -Level $(if ($errors.Count) { 'Warning' } else { 'Info' })

        # ---- console summary
        $count = { param([string[]]$Action) @($results | Where-Object { $_.Action -in $Action }).Count }
        $itemParts = @(
            '{0} pushed' -f (& $count 'Push')
            '{0} pulled' -f (& $count 'Pull')
            '{0} conflict(s) ({1} local won, {2} store won)' -f (& $count 'Conflict-Push', 'Conflict-Pull'), (& $count 'Conflict-Push'), (& $count 'Conflict-Pull')
            '{0} in sync' -f (& $count 'InSync')
            '{0} skipped' -f (& $count 'Skipped')
            '{0} error(s)' -f (& $count 'Error')
        )
        Write-EdgeStatus ('Sync {0} in {1}{2}.' -f $(if ($errors.Count) { 'finished with errors' } else { 'finished' }), (Format-EdgeDuration $runWatch.Elapsed), $(if ($isWhatIf) { ' (WhatIf: nothing was changed)' } else { '' })) -Level $(if ($errors.Count) { 'Warning' } else { 'Success' })
        Write-EdgeStatus ('  Items      : {0}' -f ($itemParts -join ', ')) -Level Header
        Write-EdgeStatus ('  Profiles   : {0} processed, {1} with changes{2}' -f $totalProfiles, $changedProfiles, $(if ($createdProfiles.Count) { ', {0} created ({1})' -f $createdProfiles.Count, ($createdProfiles -join ', ') } else { '' })) -Level Header
        Write-EdgeStatus ('  Data       : {0} pushed, {1} pulled' -f (Format-EdgeSize $bytesStat.Pushed), (Format-EdgeSize $bytesStat.Pulled)) -Level Header
        if ($loadedProfiles.Count) {
            Write-EdgeStatus ('  Waiting    : {0} profile(s) loaded in Edge, pulls retried next run: {1}' -f $loadedProfiles.Count, ($loadedProfiles -join ', ')) -Level Header
        }
        if ($pendingByProfile.Count) {
            [int]$pendingTotal = 0
            $pendingText = @(foreach ($name in $pendingByProfile.Keys) {
                    $list = @($pendingByProfile[$name])
                    $pendingTotal += $list.Count
                    '{0}: {1}' -f $name, (@($list | ForEach-Object { if ($_.Name) { $_.Name } else { $_.Id } }) -join ', ')
                })
            Write-EdgeStatus ('  Extensions : {0} pending install (install them in Edge; their data follows on the next sync) - {1}' -f $pendingTotal, ($pendingText -join '; ')) -Level Header
        }
        if ($errors.Count) {
            Write-EdgeStatus ('  Errors     : {0}' -f $errors.Count) -Level Header
            foreach ($e in @($errors | Select-Object -First 5)) { Write-EdgeStatus ('               {0}' -f $e) -Level Header }
            if ($errors.Count -gt 5) { Write-EdgeStatus ('               ... and {0} more (see the log)' -f ($errors.Count - 5)) -Level Header }
        }
        Write-EdgeStatus ('  Log file   : {0}' -f $logFile) -Level Header

        if (-not $Quiet) { $results.ToArray() }
    }
    finally {
        if ($progress) { Complete-EdgeProgress -Progress $progress }
        if ($mutex) {
            if ($ownsMutex) { try { $mutex.ReleaseMutex() } catch { Write-Verbose $_.Exception.Message } }
            $mutex.Dispose()
        }
        $script:EdgeSyncQuiet = $previousQuiet
        $script:EdgeQuiet = $previousEdgeQuiet
    }
}
