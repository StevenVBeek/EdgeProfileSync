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
        For scheduled runs: no warnings, errors or result objects on the console; everything goes to the log.

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
    $script:EdgeSyncQuiet = [bool]$Quiet
    $mutex = $null
    $ownsMutex = $false
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
        foreach ($u in $unknown) { Write-EdgeSyncEvent "Unknown category '$u' ignored." -Level Warning }
        $categories = @(Get-EdgeDataCategory -Name @($Category | Where-Object { $_ -in $knownCategories }))

        $machineId = Get-EdgeSyncMachineId
        $localDataPath = Get-EdgeSyncLocalDataPath
        $statePath = Join-Path $localDataPath 'state.json'
        $runStamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')
        $startedUtc = [datetime]::UtcNow
        $isWhatIf = [bool]$WhatIfPreference

        # ---- one run at a time per user/data folder ---------------------------------------------
        $mutexName = 'Local\EdgeProfileSync-' + (Get-EdgeSyncSha256 -Text $localDataPath.ToLowerInvariant()).Substring(0, 16)
        $mutex = [System.Threading.Mutex]::new($false, $mutexName)
        try { $ownsMutex = $mutex.WaitOne([TimeSpan]::FromSeconds(5)) }
        catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) {
            Write-EdgeSyncEvent 'Another Sync-EdgeProfiles run is in progress; this run is skipped.' -Level Warning
            return
        }

        Write-EdgeSyncEvent ("Sync started: machine {0}, mode {1}, channels {2}, categories {3}, store '{4}'{5}." -f
            $machineId, $Mode, ($Channel -join ','), (($categories | ForEach-Object { $_.Name }) -join ','), $SyncRoot, $(if ($isWhatIf) { ' (WhatIf)' } else { '' }))

        $state = Read-EdgeSyncState -Path $statePath
        $results = [System.Collections.Generic.List[object]]::new()
        $profileSummary = [System.Collections.Generic.List[object]]::new()
        $errors = [System.Collections.Generic.List[string]]::new()

        $addResult = {
            param($r)
            $results.Add($r)
            $level = switch ($r.Action) { 'Error' { 'Error' } 'Skipped' { 'Info' } 'InSync' { 'Verbose' } default { 'Info' } }
            Write-EdgeSyncEvent ('{0}/{1}/{2}: {3} - {4}' -f $r.Channel, $r.Profile, $r.Category, $r.Action, $r.Reason) -Level $level
            if ($r.Action -eq 'Error') { $errors.Add(('{0}/{1}/{2}: {3}' -f $r.Channel, $r.Profile, $r.Category, $r.Reason)) }
        }
        $matchesAny = {
            param([string[]]$Patterns, [string[]]$Values)
            foreach ($pattern in $Patterns) { foreach ($v in $Values) { if ($v -and $v -like $pattern) { return $true } } }
            $false
        }

        foreach ($ch in $Channel) {
            try {
                $channelInfo = Get-EdgeChannelInfo -Channel $ch -UserDataRoot $UserDataRoot
                if (-not $channelInfo.Installed) {
                    Write-EdgeSyncEvent "Edge $ch has no User Data folder ('$($channelInfo.UserDataPath)'); channel skipped."
                    continue
                }

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
                }

                $localProfiles = @(Get-EdgeLocalProfile -Channel $ch -UserDataRoot $UserDataRoot)
                $storeProfiles = @(Get-EdgeSyncStoreProfile -SyncRoot $SyncRoot -Channel $ch)
                $tombstones = @{}
                foreach ($t in @(Get-EdgeSyncTombstone -SyncRoot $SyncRoot -Channel $ch)) { $tombstones[$t.Key] = $t }

                $keys = [System.Collections.Generic.List[string]]::new()
                $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($k in @($localProfiles | ForEach-Object { $_.Key }) + @($storeProfiles | ForEach-Object { $_.Key })) { if ($k -and $seen.Add($k)) { $keys.Add($k) } }

                foreach ($key in $keys) {
                    $local = $localProfiles | Where-Object { $_.Key -eq $key } | Select-Object -First 1
                    $stored = $storeProfiles | Where-Object { $_.Key -eq $key } | Select-Object -First 1
                    $displayName = if ($local) { $local.Name } elseif ($stored) { $stored.Name } else { $key }

                    if ($IncludeProfile.Count -and -not (& $matchesAny $IncludeProfile @($displayName, $key))) { continue }
                    if ($ExcludeProfile.Count -and (& $matchesAny $ExcludeProfile @($displayName, $key))) { continue }

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
                                }
                                elseif (-not (Confirm-EdgeSyncChannelClosed -Context $ctx)) {
                                    Write-EdgeSyncEvent "Edge $ch profile '$key' was deleted on $($tomb.Machine); local removal postponed: $($ctx.Gate.Reason)"
                                }
                                elseif ($PSCmdlet.ShouldProcess("Edge $ch profile '$($local.Name)' ($($local.Directory))", 'Remove local profile deleted on another machine')) {
                                    Remove-EdgeLocalProfile -Directory $local.Directory -Channel $ch -UserDataRoot $UserDataRoot -Confirm:$false
                                    Clear-EdgeSyncStateProfile -State $state -Channel $ch -Key $key
                                    Write-EdgeSyncState -Path $statePath -State $state
                                    Write-EdgeSyncEvent "Removed Edge $ch profile '$($local.Name)' ($($local.Directory)) because it was deleted on $($tomb.Machine) (Recycle Bin)."
                                }
                                continue
                            }
                        }
                        catch {
                            $r = [pscustomobject]@{ Channel = $ch; Profile = $key; Category = '*'; Action = 'Error'; Reason = "Deleted profile handling failed: $($_.Exception.Message)" }
                            & $addResult $r
                            continue
                        }
                    }

                    $profileResults = [System.Collections.Generic.List[object]]::new()
                    try {
                        $location = Get-EdgeSyncStoreLocation -SyncRoot $SyncRoot -Channel $ch -Key $key
                        $pctx = [pscustomobject]@{
                            Key       = $key
                            Profile   = $local
                            Location  = $location
                            Manifest  = (Read-EdgeSyncManifest -StoreProfilePath $location.Store)
                            Inventory = $null
                            PushedAny = $false
                            Writable  = $null
                            GateReason = ''
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
                                    $local = New-EdgeLocalProfile -Name $displayName -InfoCache $infoCache -Channel $ch -UserDataRoot $UserDataRoot -Confirm:$false
                                    if (-not $local) { throw "Creating local profile '$displayName' failed." }
                                    Write-EdgeSyncEvent "Created local Edge $ch profile '$displayName' in '$($local.Directory)' from the sync store."
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
                        foreach ($cat in $categories) {
                            $extensionIds = @($null)
                            if ($cat.PerExtension) {
                                try {
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
                            foreach ($extId in $extensionIds) {
                                try {
                                    $r = Invoke-EdgeSyncItem -Context $ctx -ProfileContext $pctx -Category $cat -ExtensionId $extId
                                }
                                catch {
                                    $itemName = if ($extId) { '{0}:{1}' -f $cat.Name, $extId } else { $cat.Name }
                                    $r = [pscustomobject]@{ Channel = $ch; Profile = $key; Category = $itemName; Action = 'Error'; Reason = $_.Exception.Message }
                                }
                                & $addResult $r
                                $profileResults.Add($r)
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
            }
            catch {
                $r = [pscustomobject]@{ Channel = $ch; Profile = '*'; Category = '*'; Action = 'Error'; Reason = $_.Exception.Message }
                & $addResult $r
            }
        }

        # ---- housekeeping and machine summary
        if (-not $isWhatIf) {
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

        if (-not $Quiet) { $results.ToArray() }
    }
    finally {
        if ($mutex) {
            if ($ownsMutex) { try { $mutex.ReleaseMutex() } catch { Write-Verbose $_.Exception.Message } }
            $mutex.Dispose()
        }
        $script:EdgeSyncQuiet = $previousQuiet
    }
}
