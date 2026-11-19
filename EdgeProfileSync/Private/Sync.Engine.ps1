# Sync engine: the pure 3-way decision function, fingerprints of sync items, the push / pull
# executors and the per-item orchestration used by Sync-EdgeProfiles.
# See docs/ARCHITECTURE.md, section "Sync algorithm".

function Get-EdgeSyncDecision {
    <#
    .SYNOPSIS
        Pure 3-way sync decision for one item.
    .DESCRIPTION
        L = local fingerprint, R = store manifest fingerprint, B = base fingerprint from the local state.
        Empty string or $null means "absent".

          no L and no R              -> None
          L == R                     -> InSync
          no R (L only)              -> Push   (also when the store copy vanished)
          no L (R only)              -> Pull   (deletions are never propagated)
          no B, L != R               -> conflict
          L != B, R == B             -> Push
          L == B, R != B             -> Pull
          L != B, R != B             -> conflict
          conflict                   -> Conflict-Push when LocalTimeUtc >= RemoteTimeUtc (or remote time
                                        unknown), else Conflict-Pull.
        -PreferRemoteWithoutBase: a conflict without base resolves to Conflict-Pull (used for extension
        data, where a freshly installed extension creates new, empty data that must not win).
    .OUTPUTS
        [string] None | InSync | Push | Pull | Conflict-Push | Conflict-Pull
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Local,
        [AllowNull()][AllowEmptyString()][string]$Remote,
        [AllowNull()][AllowEmptyString()][string]$Base,
        [Nullable[datetime]]$LocalTimeUtc,
        [Nullable[datetime]]$RemoteTimeUtc,
        [switch]$PreferRemoteWithoutBase
    )

    $hasL = -not [string]::IsNullOrEmpty($Local)
    $hasR = -not [string]::IsNullOrEmpty($Remote)
    $hasB = -not [string]::IsNullOrEmpty($Base)

    if (-not $hasL -and -not $hasR) { return 'None' }
    if ($hasL -and $hasR -and $Local -eq $Remote) { return 'InSync' }
    if (-not $hasR) { return 'Push' }
    if (-not $hasL) { return 'Pull' }

    if ($hasB) {
        $localChanged = $Local -ne $Base
        $remoteChanged = $Remote -ne $Base
        if ($localChanged -and -not $remoteChanged) { return 'Push' }
        if ($remoteChanged -and -not $localChanged) { return 'Pull' }
    }
    elseif ($PreferRemoteWithoutBase) {
        return 'Conflict-Pull'
    }

    # Conflict: newer wins.
    if ($null -eq $RemoteTimeUtc) { return 'Conflict-Push' }
    if ($null -eq $LocalTimeUtc) { return 'Conflict-Pull' }
    if (([datetime]$LocalTimeUtc).ToUniversalTime() -ge ([datetime]$RemoteTimeUtc).ToUniversalTime()) { return 'Conflict-Push' }
    'Conflict-Pull'
}

function Get-EdgeSyncItemSpec {
    <#
    .SYNOPSIS
        Lists the files/directories that make up one sync item below a root folder.
    .DESCRIPTION
        Returns { Name; Path; IsDirectory } per Files / Directories entry of the category. Name is the
        path inside the store item folder; Path is the full path below -Root.
        With -ExtensionId (local profile side of a PerExtension category) Path is "<Root>\<dir>\<id>".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][object]$Category,
        [string]$ExtensionId
    )
    foreach ($f in @($Category.Files)) {
        if (-not $f) { continue }
        [pscustomobject]@{ Name = $f; Path = (Join-Path $Root $f); IsDirectory = $false }
    }
    foreach ($d in @($Category.Directories)) {
        if (-not $d) { continue }
        $path = if ($ExtensionId) { Join-Path (Join-Path $Root $d) $ExtensionId } else { Join-Path $Root $d }
        [pscustomobject]@{ Name = $d; Path = $path; IsDirectory = $true }
    }
}

function Get-EdgeSyncFingerprint {
    <#
    .SYNOPSIS
        Composite fingerprint of a sync item: SHA256 over sorted "<Name>|<Get-EdgeItemFingerprint>"
        lines of the parts that exist. $null when no part exists. Independent of the root folder, so a
        local item and its store copy give the same value.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyCollection()][object[]]$Items)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $exists = if ($item.IsDirectory) { Test-Path -LiteralPath $item.Path -PathType Container } else { Test-Path -LiteralPath $item.Path -PathType Leaf }
        if (-not $exists) { continue }
        # Preferences: ignore Edge's constant telemetry rewrites (see Sync.Normalize.ps1).
        $fp = if (-not $item.IsDirectory -and $item.Name -eq 'Preferences') {
            Get-EdgePreferencesFingerprint -Path $item.Path
        }
        else {
            Get-EdgeItemFingerprint -Path $item.Path
        }
        if ($fp) { $lines.Add(('{0}|{1}' -f $item.Name, $fp)) }
    }
    if ($lines.Count -eq 0) { return $null }
    $lines.Sort([StringComparer]::OrdinalIgnoreCase)
    Get-EdgeSyncSha256 -Text ($lines -join "`n")
}

function Get-EdgeSyncLastWriteUtc {
    <#
    .SYNOPSIS
        Newest LastWriteTimeUtc of the existing parts of a sync item (recursive for directories), or $null.
    #>
    [CmdletBinding()]
    [OutputType([Nullable[datetime]])]
    param([AllowEmptyCollection()][object[]]$Items)

    $max = $null
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $times = @()
        if ($item.IsDirectory) {
            if (Test-Path -LiteralPath $item.Path -PathType Container) {
                $times = @(Get-ChildItem -LiteralPath $item.Path -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.LastWriteTimeUtc })
            }
        }
        elseif (Test-Path -LiteralPath $item.Path -PathType Leaf) {
            $times = @((Get-Item -LiteralPath $item.Path -Force).LastWriteTimeUtc)
        }
        foreach ($t in $times) { if ($null -eq $max -or $t -gt $max) { $max = $t } }
    }
    $max
}

# --- Extensions -------------------------------------------------------------------------------

function ConvertTo-EdgeSyncExtensionRecord {
    <#
    .SYNOPSIS
        Normalises an extension object (from Get-EdgeExtensionInventory or extensions.json) to
        [ordered]@{ Id; Name; Version; Source; StoreUrl }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$InputObject)

    $id = [string](Get-EdgeSyncValue $InputObject 'Id')
    if (-not $id) { return }
    $source = [string](Get-EdgeSyncValue $InputObject 'Source')
    if (-not $source) {
        $location = (Get-EdgeSyncValue $InputObject 'Location') -as [int]
        $source = if ($location -eq 4) { 'Unpacked' }
        elseif ($location -in 3, 9) { 'Policy' }
        elseif ([bool](Get-EdgeSyncValue $InputObject 'FromWebstore' (Get-EdgeSyncValue $InputObject 'from_webstore' $false))) { 'ChromeStore' }
        else { 'EdgeStore' }
    }
    $storeUrl = Get-EdgeSyncValue $InputObject 'StoreUrl'
    if (-not $storeUrl -and $source -eq 'EdgeStore') { $storeUrl = "https://microsoftedge.microsoft.com/addons/detail/$id" }
    [ordered]@{
        Id       = $id
        Name     = [string](Get-EdgeSyncValue $InputObject 'Name')
        Version  = [string](Get-EdgeSyncValue $InputObject 'Version')
        Source   = $source
        StoreUrl = $(if ($storeUrl) { [string]$storeUrl } else { $null })
    }
}

function Get-EdgeSyncExtensionInventory {
    <#
    .SYNOPSIS
        Local extension inventory of a profile as normalised records, without Policy and Component
        extensions (those are managed by the machine, never synced). Sorted by Id (ordinal).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProfilePath)

    if (-not (Get-Command -Name Get-EdgeExtensionInventory -ErrorAction Ignore)) {
        throw 'Get-EdgeExtensionInventory is not available.'
    }
    $records = @(Get-EdgeExtensionInventory -ProfilePath $ProfilePath -WarningAction SilentlyContinue |
            ForEach-Object { ConvertTo-EdgeSyncExtensionRecord -InputObject $_ } |
            Where-Object { $_ -and $_.Source -notin 'Policy', 'Component' })
    Group-EdgeSyncExtensionRecord -Records $records
}

function Group-EdgeSyncExtensionRecord {
    # Deduplicates records by Id (last one wins) and sorts them ordinally by Id.
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Records)
    $byId = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in @($Records)) { if ($r) { $byId[[string]$r.Id] = $r } }
    $keys = [string[]]@($byId.Keys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    foreach ($k in $keys) { $byId[$k] }
}

function ConvertTo-EdgeSyncExtensionJson {
    # Canonical JSON (compressed, sorted) of extension records: the content of extensions.json.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyCollection()][object[]]$Records)
    ConvertTo-Json -InputObject @(@($Records) | Where-Object { $_ }) -Depth 5 -Compress
}

function Read-EdgeSyncExtensionList {
    <#
    .SYNOPSIS
        Reads extensions.json from a store item folder as normalised records (empty when missing).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $data = Read-EdgeJsonFile -Path $Path
    $records = @(@($data) | Where-Object { $_ } | ForEach-Object { ConvertTo-EdgeSyncExtensionRecord -InputObject $_ } | Where-Object { $_ })
    Group-EdgeSyncExtensionRecord -Records $records
}

function Update-EdgeSyncPendingExtension {
    <#
    .SYNOPSIS
        Writes the pending-install list of a profile: store-listed extensions that are not installed
        locally (Policy / Component excluded). Uses Set-EdgePendingExtension (Private/Extensions.ps1).
        Returns the pending records.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][string]$ProfileKey,
        [AllowEmptyCollection()][object[]]$StoreList,
        [AllowEmptyCollection()][object[]]$LocalInventory
    )
    $localIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($x in @($LocalInventory)) { if ($x) { $null = $localIds.Add([string]$x.Id) } }
    $pending = @(@($StoreList) | Where-Object { $_ -and -not $localIds.Contains([string]$_.Id) -and $_.Source -notin 'Policy', 'Component' } |
            ForEach-Object { [pscustomobject]$_ })

    if (Get-Command -Name Set-EdgePendingExtension -ErrorAction Ignore) {
        # Keep the original AddedUtc of entries that were already pending.
        $existing = @{}
        if (Get-Command -Name Get-EdgePendingExtension -ErrorAction Ignore) {
            foreach ($e in @(Get-EdgePendingExtension -Channel $Channel -ProfileKey $ProfileKey -WarningAction SilentlyContinue)) {
                if ($e -and $e.Id -and $e.AddedUtc) { $existing[[string]$e.Id] = $e.AddedUtc }
            }
        }
        foreach ($x in $pending) {
            if ($existing.ContainsKey([string]$x.Id)) { $x | Add-Member -NotePropertyName AddedUtc -NotePropertyValue $existing[[string]$x.Id] -Force }
        }
        Set-EdgePendingExtension -Channel $Channel -ProfileKey $ProfileKey -Extension $pending -Confirm:$false
    }
    else {
        Write-EdgeSyncEvent 'Set-EdgePendingExtension is not available; pending extension list not written.' -Level Warning
    }
    foreach ($p in $pending) {
        Write-EdgeSyncEvent ("Extension pending install in {0}/{1}: {2} ({3}) {4}" -f $Channel, $ProfileKey, $p.Name, $p.Id, $p.StoreUrl)
    }
    $pending
}

function Get-EdgeSyncExtensionDataId {
    <#
    .SYNOPSIS
        Extension ids that take part in ExtensionData sync for one profile: locally installed (non-policy)
        extensions that have a data folder, plus ids that have an "ExtensionData:<id>" manifest entry.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string]$ProfilePath,
        [Parameter(Mandatory)][object]$Category,
        [AllowEmptyCollection()][object[]]$LocalInventory,
        [Parameter(Mandatory)][hashtable]$Manifest
    )
    $ids = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($ProfilePath) {
        foreach ($x in @($LocalInventory)) {
            if (-not $x) { continue }
            foreach ($d in @($Category.Directories)) {
                if (Test-Path -LiteralPath (Join-Path (Join-Path $ProfilePath $d) $x.Id) -PathType Container) { $null = $ids.Add([string]$x.Id); break }
            }
        }
    }
    $prefix = "$($Category.Name):"
    foreach ($k in $Manifest.Categories.Keys) {
        if (([string]$k).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $null = $ids.Add(([string]$k).Substring($prefix.Length)) }
    }
    @($ids)
}

# --- Progress helpers --------------------------------------------------------------------------

# Copies of at least this many bytes get their own (child) progress bar.
$script:EdgeSyncCopyProgressMinBytes = 1MB

function Set-EdgeSyncContextValue {
    # Internal: sets a property of a run / profile context when it has that property (StrictMode-safe;
    # contexts built by tests or older callers may not carry the progress / statistics fields).
    param([AllowNull()][object]$InputObject, [string]$Name, [AllowNull()][object]$Value)
    if ($null -ne $InputObject -and $InputObject.PSObject.Properties[$Name]) { $InputObject.$Name = $Value }
}

function Set-EdgeSyncItemPhase {
    <#
    .SYNOPSIS
        Shows the phase of the current sync item ("comparing", "pushing", "pulling") on the run's
        progress bar, when the run context has one (Context.Progress / Context.ProgressLabel).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][string]$Phase,
        [switch]$Force
    )
    $progress = Get-EdgeSyncValue $Context 'Progress'
    if ($null -eq $progress) { return }
    $label = [string](Get-EdgeSyncValue $Context 'ProgressLabel')
    Update-EdgeProgress -Progress $progress -Status $(if ($label) { '{0}: {1}' -f $label, $Phase } else { $Phase }) -Force:$Force
}

function New-EdgeSyncCopyProgress {
    # Internal: child progress bar (Id = ParentId + 1) for a byte copy; $null when there is no parent bar
    # or the copy is too small to be worth a bar.
    param([long]$Total, [string]$Activity, [int]$ParentId = -1)
    if ($ParentId -lt 0 -or $Total -lt $script:EdgeSyncCopyProgressMinBytes) { return $null }
    New-EdgeProgress -Activity $Activity -Total $Total -Unit Bytes -Id ($ParentId + 1) -ParentId $ParentId
}

# --- Executors -------------------------------------------------------------------------------

function Invoke-EdgeSyncPush {
    <#
    .SYNOPSIS
        Copies a local sync item into the store: prepare "<item>.tmp-<MachineId>", archive the current
        store copy, rename. Returns the new manifest entry { Fingerprint; UpdatedUtc; Machine; PushedUtc }.
    .PARAMETER LocalItems
        Item spec of the local side (Get-EdgeSyncItemSpec). Ignored with -GeneratedName.
    .PARAMETER GeneratedName
        File name for generated content (ExtensionList: extensions.json) written from -GeneratedContent.
    .PARAMETER ProgressParentId
        Id of the run's progress bar; large copies then show a child bar with bytes, speed and ETA.
    .PARAMETER Stats
        Optional hashtable; receives Bytes = the number of bytes copied into the store.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$LocalItems,
        [string]$GeneratedName,
        [string]$GeneratedContent,
        [Parameter(Mandatory)][string]$StoreItemPath,
        [Parameter(Mandatory)][string]$ArchiveRoot,
        [Parameter(Mandatory)][string]$MachineId,
        [AllowNull()][AllowEmptyString()][string]$PreviousMachine,
        [Parameter(Mandatory)][int]$ArchiveRetention,
        [Nullable[datetime]]$LocalLastWriteUtc,
        [switch]$Sqlite,
        [int]$ProgressParentId = -1,
        [hashtable]$Stats
    )

    $tmp = '{0}.tmp-{1}' -f $StoreItemPath, (ConvertTo-EdgeSafeName -Name $MachineId)
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction Stop }
    $null = New-Item -Path $tmp -ItemType Directory -Force

    $copyProgress = $null
    try {
        if ($GeneratedName) {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($GeneratedContent)
            [IO.File]::WriteAllBytes((Join-Path $tmp $GeneratedName), $bytes)
            $fingerprint = Get-EdgeSyncSha256 -Bytes $bytes
            if ($null -ne $Stats) { $Stats.Bytes = [long]$bytes.Length }
        }
        else {
            $sizes = @{}
            [long]$total = 0
            foreach ($item in @($LocalItems)) { $sizes[$item.Name] = Get-EdgePathSize -Path $item.Path; $total += $sizes[$item.Name] }
            if ($null -ne $Stats) { $Stats.Bytes = $total }
            $copyProgress = New-EdgeSyncCopyProgress -Total $total -Activity ('Pushing {0} to the sync store' -f (Split-Path -Path $StoreItemPath -Leaf)) -ParentId $ProgressParentId
            foreach ($item in @($LocalItems)) {
                if ($copyProgress) { Update-EdgeProgress -Progress $copyProgress -Status "Copying $($item.Name)" -CurrentOperation $item.Path -Force }
                $dest = Join-Path $tmp $item.Name
                if ($item.IsDirectory) {
                    if (Test-Path -LiteralPath $item.Path -PathType Container) {
                        Copy-EdgeItem -Source $item.Path -Destination $dest -Directory
                        if ($Sqlite) {
                            # Re-copy the databases inside the directory as consistent snapshots.
                            $srcRoot = [IO.Path]::GetFullPath($item.Path).TrimEnd('')
                            foreach ($db in @(Get-ChildItem -LiteralPath $srcRoot -File -Recurse -Force -ErrorAction SilentlyContinue |
                                        Where-Object { ($_.Name -like '*.db' -or $_.Name -like '*SQLite*') -and $_.Name -notmatch '-(journal|wal|shm)$' })) {
                                Copy-EdgeSqliteSnapshot -Source $db.FullName -Destination (Join-Path $dest $db.FullName.Substring($srcRoot.Length + 1))
                            }
                        }
                    }
                }
                elseif (Test-Path -LiteralPath $item.Path -PathType Leaf) {
                    if ($Sqlite) { Copy-EdgeSqliteSnapshot -Source $item.Path -Destination $dest }
                    else { Copy-EdgeItem -Source $item.Path -Destination $dest }
                }
                if ($copyProgress) { Update-EdgeProgress -Progress $copyProgress -Status "Copied $($item.Name)" -Add $sizes[$item.Name] }
            }
            # Fingerprint of what actually landed in the store (the local file may change during the copy).
            $fingerprint = Get-EdgeSyncFingerprint -Items @(Get-EdgeSyncItemSpec -Root $tmp -Category ([pscustomobject]@{
                        Files = @($LocalItems | Where-Object { -not $_.IsDirectory } | ForEach-Object { $_.Name })
                        Directories = @($LocalItems | Where-Object IsDirectory | ForEach-Object { $_.Name })
                    }))
            if (-not $fingerprint) { throw 'Nothing to push: the local item disappeared during the copy.' }
        }

        Publish-EdgeSyncStoreItem -TempPath $tmp -FinalPath $StoreItemPath -ArchiveRoot $ArchiveRoot -PreviousMachine $PreviousMachine -ArchiveRetention $ArchiveRetention
    }
    catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
    finally {
        if ($copyProgress) { Complete-EdgeProgress -Progress $copyProgress }
    }

    $now = [datetime]::UtcNow
    $updated = if ($LocalLastWriteUtc) { ([datetime]$LocalLastWriteUtc).ToUniversalTime() } else { $now }
    [ordered]@{
        Fingerprint = $fingerprint
        UpdatedUtc  = $updated.ToString('o')
        Machine     = $MachineId
        PushedUtc   = $now.ToString('o')
    }
}

function Invoke-EdgeSyncPull {
    <#
    .SYNOPSIS
        Copies a store item over the local profile. Edge of the channel must be closed (caller's job).
    .DESCRIPTION
        -MoveLocalAside (conflict pull): the current local parts are moved to -ReplacedPath first.
        MoveAsideOnRestore files of the category (e.g. EncryptedBookmarks2) are always moved aside.
        Local parts that do not exist in the store copy are left alone (deletions are not propagated).
        -ProgressParentId: id of the run's progress bar (large copies get a child bar). -Stats receives
        Bytes = the number of bytes copied into the profile.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Category,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$LocalItems,
        [Parameter(Mandatory)][string]$StoreItemPath,
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$ReplacedPath,
        [switch]$MoveLocalAside,
        [int]$ProgressParentId = -1,
        [hashtable]$Stats
    )

    if (-not (Test-Path -LiteralPath $StoreItemPath -PathType Container)) { throw "Store copy '$StoreItemPath' does not exist." }

    $sizes = @{}
    [long]$total = 0
    foreach ($item in @($LocalItems)) {
        $src = Join-Path $StoreItemPath $item.Name
        $size = Get-EdgePathSize -Path $src
        if ($Category.Sqlite -and -not $item.IsDirectory) { $size += Get-EdgePathSize -Path "$src-wal" }
        $sizes[$item.Name] = $size
        $total += $size
    }
    if ($null -ne $Stats) { $Stats.Bytes = $total }
    $copyProgress = New-EdgeSyncCopyProgress -Total $total -Activity ('Pulling {0} from the sync store' -f (Split-Path -Path $StoreItemPath -Leaf)) -ParentId $ProgressParentId
    try {

        if ($MoveLocalAside) {
            foreach ($item in @($LocalItems)) {
                if (Test-Path -LiteralPath $item.Path) {
                    $backupRoot = if ($item.IsDirectory -and $item.Path -ne (Join-Path $ProfilePath $item.Name)) { Join-Path $ReplacedPath $item.Name } else { $ReplacedPath }
                    Move-EdgeItemAside -Path $item.Path -BackupRoot $backupRoot -Confirm:$false
                }
            }
        }
        foreach ($name in @($Category.MoveAsideOnRestore)) {
            if (-not $name) { continue }
            $p = Join-Path $ProfilePath $name
            if (Test-Path -LiteralPath $p) { Move-EdgeItemAside -Path $p -BackupRoot $ReplacedPath -Confirm:$false }
        }

        foreach ($item in @($LocalItems)) {
            $src = Join-Path $StoreItemPath $item.Name
            if ($copyProgress) { Update-EdgeProgress -Progress $copyProgress -Status "Copying $($item.Name)" -CurrentOperation $item.Path -Force }
            if ($item.IsDirectory) {
                if (Test-Path -LiteralPath $src -PathType Container) { Copy-EdgeItem -Source $src -Destination $item.Path -Directory }
            }
            elseif (Test-Path -LiteralPath $src -PathType Leaf) {
                if ($Category.Sqlite) {
                    # A stale local write-ahead log / journal must never be applied to the restored database.
                    foreach ($suffix in '-wal', '-journal', '-shm') {
                        if (Test-Path -LiteralPath "$($item.Path)$suffix") { Move-EdgeItemAside -Path "$($item.Path)$suffix" -BackupRoot $ReplacedPath -Confirm:$false }
                    }
                }
                Copy-EdgeItem -Source $src -Destination $item.Path
                if ($Category.Sqlite -and (Test-Path -LiteralPath "$src-wal" -PathType Leaf)) {
                    Copy-EdgeItem -Source "$src-wal" -Destination "$($item.Path)-wal"
                }
            }
            if ($copyProgress) { Update-EdgeProgress -Progress $copyProgress -Status "Copied $($item.Name)" -Add $sizes[$item.Name] }
        }
    }
    finally {
        if ($copyProgress) { Complete-EdgeProgress -Progress $copyProgress }
    }
}

# --- Orchestration ---------------------------------------------------------------------------

function Confirm-EdgeSyncChannelClosed {
    <#
    .SYNOPSIS
        Returns $true when Edge of the run's channel is not running (stopping windowless Edge when
        allowed). The answer is cached in $Context.Gate for the rest of the channel run.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][object]$Context)

    $gate = $Context.Gate
    if ($null -ne $gate.Closed) { return [bool]$gate.Closed }

    $channel = $Context.Channel
    $ps = Get-EdgeProcessState -Channel $channel
    if (-not $ps.Running) {
        $gate.Closed = $true
    }
    elseif (-not $ps.HasWindows -and $Context.CloseBackgroundEdge) {
        if ($Context.Cmdlet.ShouldProcess("Microsoft Edge $channel (background, no windows)", 'Stop process')) {
            $stopped = [bool](Stop-EdgeProcess -Channel $channel -BackgroundOnly)
            $gate.Closed = $stopped
            if ($stopped) {
                Write-EdgeSyncEvent "Stopped windowless (background) Edge $channel to apply changes."
                Write-EdgeStatus "Stopped windowless (background) Edge $channel to apply pulled data." -Level Info
            }
            else { $gate.Reason = "Edge $channel is running and could not be stopped; will retry next run." }
        }
        else {
            # -WhatIf: plan as if it had been stopped.
            $gate.Closed = [bool]$Context.WhatIf
            if (-not $gate.Closed) { $gate.Reason = "Stopping background Edge $channel was declined." }
        }
    }
    elseif (-not $ps.HasWindows) {
        $gate.Closed = $false
        $gate.Reason = "Edge $channel is running in the background and CloseBackgroundEdge is off; will retry next run."
    }
    else {
        $gate.Closed = $false
        $gate.Reason = "Edge $channel is running with open windows; will retry next run."
    }
    if (-not $gate.Closed -and $gate.Reason) {
        Write-EdgeSyncEvent $gate.Reason
        Write-EdgeStatus $gate.Reason -Level Warning
    }
    [bool]$gate.Closed
}

function Confirm-EdgeSyncProfileWritable {
    <#
    .SYNOPSIS
        Returns $true when data may be written into (or LevelDB data read from) the local profile:
        the profile is not loaded by a running Edge (Test-EdgeProfileInUse), or Edge of the channel is
        not running / could be stopped because it has no windows (see Confirm-EdgeSyncChannelClosed).
        Sets $ProfileContext.GateReason when not. Cached per profile.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][object]$ProfileContext
    )
    if ($null -ne $ProfileContext.Writable) { return [bool]$ProfileContext.Writable }
    $writable = $true
    if ($Context.Gate.Closed -ne $true -and $ProfileContext.Profile -and (Test-EdgeProfileInUse -Path $ProfileContext.Profile.Path)) {
        $writable = Confirm-EdgeSyncChannelClosed -Context $Context
        if (-not $writable) {
            $ProfileContext.GateReason = "Profile is loaded in Edge: $($Context.Gate.Reason)"
        }
    }
    $ProfileContext.Writable = $writable
    $writable
}

function Get-EdgeSyncProfileInventory {
    # Lazily computes and caches the local extension inventory of the profile in the profile context.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$ProfileContext)
    if ($null -eq $ProfileContext.Inventory) {
        $inv = @()
        if ($ProfileContext.Profile) { $inv = @(Get-EdgeSyncExtensionInventory -ProfilePath $ProfileContext.Profile.Path) }
        $ProfileContext.Inventory = $inv
    }
    , @($ProfileContext.Inventory)
}

function Invoke-EdgeSyncItem {
    <#
    .SYNOPSIS
        Decides and executes the sync of one item (category, or one extension of a PerExtension category)
        of one profile. Returns the result object. Throws on unexpected errors (caller reports 'Error').
    .PARAMETER Context
        Run context built by Sync-EdgeProfiles (Cmdlet, Channel, MachineId, LocalDataPath, RunStamp,
        State, Mode, AllowLiveCopy, CloseBackgroundEdge, ArchiveRetention, Gate, WhatIf).
        Optional progress fields: Progress (tracker of the run's bar), ProgressLabel, ProgressId.
    .PARAMETER ProfileContext
        Key, Profile (local profile object), Location (store/archive paths), Manifest, Inventory, PushedAny.
        Optional statistics fields (set when present): LastBytes (bytes copied for this item),
        PendingExtensions (extensions listed in the store but not installed locally).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][object]$ProfileContext,
        [Parameter(Mandatory)][object]$Category,
        [string]$ExtensionId
    )

    $ctx = $Context
    $p = $ProfileContext
    $itemName = if ($ExtensionId) { '{0}:{1}' -f $Category.Name, $ExtensionId } else { $Category.Name }
    Set-EdgeSyncContextValue $p 'LastBytes' ([long]0)
    $progressId = if ($null -ne (Get-EdgeSyncValue $ctx 'Progress')) { [int](Get-EdgeSyncValue $ctx 'ProgressId' 1) } else { -1 }
    Set-EdgeSyncItemPhase -Context $ctx -Phase 'comparing'
    $newResult = {
        param([string]$Action, [string]$Reason)
        [pscustomobject]@{ Channel = $ctx.Channel; Profile = $p.Key; Category = $itemName; Action = $Action; Reason = $Reason }
    }

    $isGenerated = [bool]$Category.Generated
    $isPerExtension = [bool]$ExtensionId
    $stateKey = '{0}|{1}|{2}' -f $ctx.Channel, $p.Key, $itemName
    $stateItem = Get-EdgeSyncStateItem -State $ctx.State -ItemKey $stateKey
    $B = [string](Get-EdgeSyncValue $stateItem 'Fingerprint')
    $LF = [string](Get-EdgeSyncValue $stateItem 'LocalFingerprint')

    $entry = $p.Manifest.Categories[$itemName]
    $R = [string](Get-EdgeSyncValue $entry 'Fingerprint')
    $remoteMachine = [string](Get-EdgeSyncValue $entry 'Machine')
    $remoteTime = ConvertTo-EdgeSyncUtcDate (Get-EdgeSyncValue $entry 'UpdatedUtc')

    $storeItemPath = if ($isPerExtension) { Join-Path (Join-Path $p.Location.Store $Category.Name) $ExtensionId } else { Join-Path $p.Location.Store $Category.Name }
    $archiveRoot = if ($isPerExtension) { Join-Path (Join-Path $p.Location.Archive $Category.Name) $ExtensionId } else { Join-Path $p.Location.Archive $Category.Name }
    $profilePath = $p.Profile.Path

    # --- local side
    $localItems = @()
    $generatedJson = $null
    $inventory = @()
    if ($isGenerated -or $isPerExtension) { $inventory = Get-EdgeSyncProfileInventory -ProfileContext $p }
    if ($isGenerated) {
        $generatedJson = ConvertTo-EdgeSyncExtensionJson -Records $inventory
        # No extensions installed = nothing to contribute (never overwrite the store list with an empty one).
        $L = if (@($inventory).Count) { Get-EdgeSyncSha256 -Text $generatedJson } else { $null }
        $localTime = Get-EdgeSyncLastWriteUtc -Items @(
            [pscustomobject]@{ Name = 'Preferences'; Path = (Join-Path $profilePath 'Preferences'); IsDirectory = $false }
            [pscustomobject]@{ Name = 'Secure Preferences'; Path = (Join-Path $profilePath 'Secure Preferences'); IsDirectory = $false })
    }
    else {
        $localItems = @(Get-EdgeSyncItemSpec -Root $profilePath -Category $Category -ExtensionId $ExtensionId)
        $L = Get-EdgeSyncFingerprint -Items $localItems
        $localTime = Get-EdgeSyncLastWriteUtc -Items $localItems
    }

    # Local copy unchanged since the last sync -> treat it as equal to the base (matters when the local
    # side legitimately differs from the store after a pull, e.g. ExtensionList or extra local files).
    $effectiveL = if ($L -and $LF -and $B -and $L -eq $LF) { $B } else { $L }

    # --- decision
    $decision = $null
    if ($Category.SameMachineOnly -and $R -and $remoteMachine -and $remoteMachine -ne $ctx.MachineId) {
        if (-not $L) {
            return & $newResult 'Skipped' "Store copy is from $remoteMachine; same-machine-only data is not applied on other machines."
        }
        if ($B -and $L -eq $B) {
            return & $newResult 'Skipped' "Local copy unchanged; store copy from $remoteMachine is same-machine-only and not applied here."
        }
        $decision = 'Push'
    }
    else {
        $decision = Get-EdgeSyncDecision -Local $effectiveL -Remote $R -Base $B -LocalTimeUtc $localTime -RemoteTimeUtc $remoteTime -PreferRemoteWithoutBase:$isPerExtension
    }

    $refreshPending = {
        if ($isGenerated -and -not $ctx.WhatIf) {
            $storeFile = Join-Path $storeItemPath $Category.Generated
            if (Test-Path -LiteralPath $storeFile -PathType Leaf) {
                $pendingNow = @(Update-EdgeSyncPendingExtension -Channel $ctx.Channel -ProfileKey $p.Key -StoreList @(Read-EdgeSyncExtensionList -Path $storeFile) -LocalInventory $inventory)
                Set-EdgeSyncContextValue $p 'PendingExtensions' $pendingNow
            }
        }
    }
    $target = '{0}/{1}/{2}' -f $ctx.Channel, $p.Key, $itemName
    $declined = {
        param([string]$Action, [string]$Reason)
        if ($ctx.WhatIf) { & $newResult $Action "WhatIf: $Reason" } else { & $newResult 'Skipped' "Declined: $Reason" }
    }

    switch ($decision) {
        'None' {
            return & $newResult 'Skipped' 'No data locally or in the store.'
        }
        'InSync' {
            if (-not $ctx.WhatIf) { Set-EdgeSyncStateItem -State $ctx.State -ItemKey $stateKey -Fingerprint ($R ? $R : $L) -LocalFingerprint $L }
            & $refreshPending
            return & $newResult 'InSync' 'Local copy and store copy are the same.'
        }
        { $_ -in 'Push', 'Conflict-Push' } {
            $reason = if ($decision -eq 'Conflict-Push') {
                "Changed on both sides; local copy ($localTime) is newer than store copy ($remoteTime, $remoteMachine). Store copy archived."
            }
            elseif ($R) { 'Local copy changed.' } else { 'Only the local copy exists.' }
            if ($ctx.Mode -eq 'PullOnly') { return & $newResult 'Skipped' "Mode PullOnly: $reason" }
            # Pushes are always allowed (SQLite via snapshots), except LevelDB extension data of a loaded
            # profile, which cannot be copied consistently (unless -AllowLiveCopy).
            if ($isPerExtension -and -not $ctx.AllowLiveCopy -and -not (Confirm-EdgeSyncProfileWritable -Context $ctx -ProfileContext $p)) {
                return & $newResult 'Skipped' $p.GateReason
            }
            if (-not $ctx.Cmdlet.ShouldProcess($target, 'Push to sync store')) { return & $declined $decision $reason }

            $pushArgs = @{
                StoreItemPath     = $storeItemPath
                ArchiveRoot       = $archiveRoot
                MachineId         = $ctx.MachineId
                PreviousMachine   = $remoteMachine
                ArchiveRetention  = $ctx.ArchiveRetention
                LocalLastWriteUtc = $localTime
            }
            if ($isGenerated) {
                # ExtensionList is a union: extensions known on any machine stay listed.
                $storeList = @(Read-EdgeSyncExtensionList -Path (Join-Path $storeItemPath $Category.Generated))
                $merged = @(Group-EdgeSyncExtensionRecord -Records @($storeList + $inventory))
                $pushArgs.GeneratedName = $Category.Generated
                $pushArgs.GeneratedContent = ConvertTo-EdgeSyncExtensionJson -Records $merged
            }
            else {
                $pushArgs.LocalItems = $localItems
                $pushArgs.Sqlite = [bool]$Category.Sqlite
            }
            $copyStats = @{ Bytes = [long]0 }
            $pushArgs.Stats = $copyStats
            $pushArgs.ProgressParentId = $progressId
            Set-EdgeSyncItemPhase -Context $ctx -Phase $(if ($decision -eq 'Conflict-Push') { 'pushing (conflict, local copy is newer)' } else { 'pushing' }) -Force
            $newEntry = Invoke-EdgeSyncPush @pushArgs
            Set-EdgeSyncContextValue $p 'LastBytes' ([long]$copyStats.Bytes)
            $p.Manifest = Set-EdgeSyncManifestEntry -StoreProfilePath $p.Location.Store -Name $itemName -Entry $newEntry
            Set-EdgeSyncStateItem -State $ctx.State -ItemKey $stateKey -Fingerprint $newEntry.Fingerprint -LocalFingerprint $L
            $p.PushedAny = $true
            & $refreshPending
            return & $newResult $decision $reason
        }
        { $_ -in 'Pull', 'Conflict-Pull' } {
            $reason = if ($decision -eq 'Conflict-Pull') {
                if ($B) { "Changed on both sides; store copy ($remoteTime, $remoteMachine) is newer than local copy ($localTime). Local copy moved to the replaced folder." }
                else { "Local and store copy differ and there is no sync history; store copy ($remoteMachine) applied. Local copy moved to the replaced folder." }
            }
            elseif ($L) { "Store copy changed on $remoteMachine." } else { "Only the store copy exists ($remoteMachine)." }
            if ($ctx.Mode -eq 'PushOnly') { & $refreshPending; return & $newResult 'Skipped' "Mode PushOnly: $reason" }
            if ($isPerExtension -and -not (@($inventory | Where-Object { $_.Id -eq $ExtensionId }).Count)) {
                return & $newResult 'Skipped' "Extension $ExtensionId is not installed in this profile; its data is applied after it has been installed (pending extensions)."
            }
            if (-not $isGenerated -and -not (Confirm-EdgeSyncProfileWritable -Context $ctx -ProfileContext $p)) {
                & $refreshPending
                return & $newResult 'Skipped' $p.GateReason
            }

            # The store copy must match the manifest (OneDrive may still be downloading it).
            $storeFingerprint = if ($isGenerated) {
                Get-EdgeItemFingerprint -Path (Join-Path $storeItemPath $Category.Generated)
            }
            else {
                Get-EdgeSyncFingerprint -Items @(Get-EdgeSyncItemSpec -Root $storeItemPath -Category $Category)
            }
            if ($storeFingerprint -ne $R) {
                return & $newResult 'Skipped' 'Store copy does not match its manifest yet (still syncing?); will retry next run.'
            }
            if (-not $ctx.Cmdlet.ShouldProcess($target, 'Pull from sync store')) { return & $declined $decision $reason }

            $newL = $L
            if (-not $isGenerated) {
                $replaced = Join-Path (Join-Path (Join-Path $ctx.LocalDataPath 'replaced') $ctx.RunStamp) $p.Profile.Directory
                $copyStats = @{ Bytes = [long]0 }
                Set-EdgeSyncItemPhase -Context $ctx -Phase $(if ($decision -eq 'Conflict-Pull') { 'pulling (conflict, store copy is newer)' } else { 'pulling' }) -Force
                Invoke-EdgeSyncPull -Category $Category -LocalItems $localItems -StoreItemPath $storeItemPath -ProfilePath $profilePath -ReplacedPath $replaced -MoveLocalAside:($decision -eq 'Conflict-Pull') -ProgressParentId $progressId -Stats $copyStats
                Set-EdgeSyncContextValue $p 'LastBytes' ([long]$copyStats.Bytes)
                $newL = Get-EdgeSyncFingerprint -Items $localItems
            }
            Set-EdgeSyncStateItem -State $ctx.State -ItemKey $stateKey -Fingerprint $R -LocalFingerprint $newL
            & $refreshPending
            return & $newResult $decision $reason
        }
        default { throw "Unexpected sync decision '$decision'." }
    }
}
