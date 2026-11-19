# Sync store helpers: store / archive layout, manifest.json, profile.json, local state.json,
# atomic category replacement, archive retention, machine summary and logging wrapper.
# See docs/ARCHITECTURE.md, sections "Sync store layout" and "Local sync state".

# Set by Sync-EdgeProfiles for the duration of a run: suppresses warning/error stream output
# (the log file still gets everything).
$script:EdgeSyncQuiet = $false

# info_cache fields that identify an account; never written to profile.json in the shared store.
$script:EdgeSyncAccountInfoFields = @(
    'user_name', 'gaia_id', 'gaia_name', 'gaia_given_name', 'gaia_picture_file_name',
    'last_downloaded_gaia_picture_url_with_size', 'hosted_domain',
    'is_consented_primary_account', 'managed_user_id', 'is_managed', 'enterprise_label',
    'user_accepted_account_management', 'use_gaia_picture', 'force_signin_profile_locked'
)

function Write-EdgeSyncEvent {
    <#
    .SYNOPSIS
        Logging wrapper used by the sync engine. Never throws; honours the -Quiet switch of
        Sync-EdgeProfiles (stream output suppressed, log file still written).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Verbose')][string]$Level = 'Info'
    )
    try {
        if ($script:EdgeSyncQuiet) {
            Write-EdgeSyncLog -Message $Message -Level $Level -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false
        }
        else {
            Write-EdgeSyncLog -Message $Message -Level $Level -ErrorAction Continue
        }
    }
    catch {
        Write-Verbose "EdgeProfileSync: logging failed: $($_.Exception.Message)"
    }
}

function Get-EdgeSyncValue {
    <#
    .SYNOPSIS
        StrictMode-safe property / key lookup on hashtables and objects. Returns -Default when missing.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Default = $null
    )
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        foreach ($k in $InputObject.Keys) { if ([string]$k -ieq $Name) { return $InputObject[$k] } }
        return $Default
    }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    $Default
}

function ConvertTo-EdgeSyncUtcDate {
    <#
    .SYNOPSIS
        Converts a manifest/state timestamp (DateTime or ISO 8601 string) to a UTC DateTime, or $null.
    #>
    [CmdletBinding()]
    [OutputType([Nullable[datetime]])]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
        return $Value.ToUniversalTime()
    }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $parsed = [datetime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
    if ([datetime]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $parsed }
    $null
}

function Get-EdgeSyncSha256 {
    <#
    .SYNOPSIS
        Lowercase SHA256 hex of a string (UTF-8) or byte array.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Text')][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory, ParameterSetName = 'Bytes')][byte[]]$Bytes
    )
    if ($PSCmdlet.ParameterSetName -eq 'Text') { $Bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text) }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-EdgeSyncStoreLocation {
    <#
    .SYNOPSIS
        Returns the store and archive folders of one profile key:
        <SyncRoot>\store\<Channel>\<Key> and <SyncRoot>\archive\<Channel>\<Key>.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SyncRoot,
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][string]$Key
    )
    [pscustomobject]@{
        Store   = Join-Path $SyncRoot "store\$Channel\$Key"
        Archive = Join-Path $SyncRoot "archive\$Channel\$Key"
    }
}

function Get-EdgeSyncStoreProfile {
    <#
    .SYNOPSIS
        Lists the profiles present in the store for a channel (folders with profile.json or manifest.json).
    .OUTPUTS
        [pscustomobject]@{ Key; Name; Path; Info (hashtable from profile.json or $null) }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SyncRoot,
        [Parameter(Mandatory)][string]$Channel
    )
    $root = Join-Path $SyncRoot "store\$Channel"
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return }
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        $profileFile = Join-Path $dir.FullName 'profile.json'
        $manifestFile = Join-Path $dir.FullName 'manifest.json'
        $hasProfile = Test-Path -LiteralPath $profileFile -PathType Leaf
        if (-not $hasProfile -and -not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) { continue }
        $info = $null
        if ($hasProfile) {
            try { $info = Read-EdgeJsonFile -Path $profileFile }
            catch { Write-EdgeSyncEvent "Store profile file '$profileFile' could not be read: $($_.Exception.Message)" -Level Warning }
        }
        $name = [string](Get-EdgeSyncValue $info 'Name')
        [pscustomobject]@{
            Key  = $dir.Name
            Name = $(if ($name) { $name } else { $dir.Name })
            Path = $dir.FullName
            Info = $info
        }
    }
}

function Read-EdgeSyncManifest {
    <#
    .SYNOPSIS
        Reads <StoreProfilePath>\manifest.json. Missing file -> empty manifest. Corrupt file -> throws
        (the caller must not push over a manifest it cannot read).
    .OUTPUTS
        [hashtable]@{ Categories = [hashtable] }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$StoreProfilePath)

    $file = Join-Path $StoreProfilePath 'manifest.json'
    $manifest = @{ Categories = @{} }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $manifest }
    $data = Read-EdgeJsonFile -Path $file
    if ($data -isnot [System.Collections.IDictionary]) { throw "Store manifest '$file' is not a JSON object." }
    $cats = Get-EdgeSyncValue $data 'Categories'
    if ($cats -is [System.Collections.IDictionary]) {
        foreach ($k in $cats.Keys) {
            if ($cats[$k] -is [System.Collections.IDictionary]) { $manifest.Categories[[string]$k] = $cats[$k] }
        }
    }
    $manifest
}

function Set-EdgeSyncManifestEntry {
    <#
    .SYNOPSIS
        Re-reads the manifest (another machine may have changed it), sets one category entry and
        writes it back atomically. Returns the updated manifest.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$StoreProfilePath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Entry
    )
    $manifest = Read-EdgeSyncManifest -StoreProfilePath $StoreProfilePath
    $manifest.Categories[$Name] = $Entry
    if (-not (Test-Path -LiteralPath $StoreProfilePath -PathType Container)) {
        $null = New-Item -Path $StoreProfilePath -ItemType Directory -Force
    }
    Write-EdgeJsonFile -Path (Join-Path $StoreProfilePath 'manifest.json') -InputObject $manifest
    $manifest
}

function Get-EdgeSyncSanitizedInfoCache {
    <#
    .SYNOPSIS
        Copy of a Local State info_cache entry without account fields (safe to put in the shared store).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][System.Collections.IDictionary]$InfoCache)

    $clean = [ordered]@{}
    if (-not $InfoCache) { return $clean }
    foreach ($k in $InfoCache.Keys) {
        $ks = [string]$k
        if ($ks -in $script:EdgeSyncAccountInfoFields) { continue }
        if ($ks.StartsWith('edge_account', [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($ks.StartsWith('signin', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $clean[$ks] = $InfoCache[$k]
    }
    $clean
}

function Write-EdgeSyncProfileInfo {
    <#
    .SYNOPSIS
        Writes <StoreProfilePath>\profile.json: { Name, Key, InfoCache (sanitised), UpdatedUtc, Machine }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StoreProfilePath,
        [Parameter(Mandatory)][object]$LocalProfile,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$MachineId
    )
    if (-not (Test-Path -LiteralPath $StoreProfilePath -PathType Container)) {
        $null = New-Item -Path $StoreProfilePath -ItemType Directory -Force
    }
    $info = [ordered]@{
        Name       = [string]$LocalProfile.Name
        Key        = $Key
        InfoCache  = Get-EdgeSyncSanitizedInfoCache -InfoCache (Get-EdgeSyncValue $LocalProfile 'InfoCache')
        UpdatedUtc = [datetime]::UtcNow.ToString('o')
        Machine    = $MachineId
    }
    Write-EdgeJsonFile -Path (Join-Path $StoreProfilePath 'profile.json') -InputObject $info
}

function Read-EdgeSyncState {
    <#
    .SYNOPSIS
        Reads <LocalDataPath>\state.json. A missing file gives an empty state; a corrupt file is renamed
        to state.json.corrupt-<timestamp> and an empty state is returned (with a warning).
    .OUTPUTS
        [hashtable]@{ Items = [hashtable] }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    $state = @{ Items = @{} }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $state }
    try {
        $data = Read-EdgeJsonFile -Path $Path
        $items = Get-EdgeSyncValue $data 'Items'
        if ($items -is [System.Collections.IDictionary]) {
            foreach ($k in $items.Keys) {
                if ($items[$k] -is [System.Collections.IDictionary]) { $state.Items[[string]$k] = $items[$k] }
            }
        }
    }
    catch {
        $bad = '{0}.corrupt-{1}' -f $Path, [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')
        Write-EdgeSyncEvent "Local sync state '$Path' is corrupt, starting with an empty state (old file kept as '$bad'): $($_.Exception.Message)" -Level Warning
        try { Move-Item -LiteralPath $Path -Destination $bad -Force -ErrorAction Stop } catch { Write-Verbose $_.Exception.Message }
    }
    $state
}

function Write-EdgeSyncState {
    <#
    .SYNOPSIS
        Writes the local sync state atomically.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$State
    )
    Write-EdgeJsonFile -Path $Path -InputObject $State
}

function Get-EdgeSyncStateItem {
    <#
    .SYNOPSIS
        Returns the state entry for "<Channel>|<Key>|<Item>" or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$ItemKey
    )
    if ($State.Items.ContainsKey($ItemKey)) { return $State.Items[$ItemKey] }
    $null
}

function Set-EdgeSyncStateItem {
    <#
    .SYNOPSIS
        Records the base fingerprint (store copy) and the local fingerprint seen at sync time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$ItemKey,
        [AllowNull()][AllowEmptyString()][string]$Fingerprint,
        [AllowNull()][AllowEmptyString()][string]$LocalFingerprint
    )
    $State.Items[$ItemKey] = [ordered]@{
        Fingerprint      = $Fingerprint
        LocalFingerprint = $LocalFingerprint
        SyncedUtc        = [datetime]::UtcNow.ToString('o')
    }
}

function Get-EdgeSyncUniquePath {
    # Returns $Path, or "$Path-1", "$Path-2", ... when it already exists.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $candidate = $Path
    $i = 1
    while (Test-Path -LiteralPath $candidate) { $candidate = '{0}-{1}' -f $Path, $i; $i++ }
    $candidate
}

function Remove-EdgeSyncOldArchive {
    <#
    .SYNOPSIS
        Keeps the newest -Keep version folders under an archive folder (names start with
        yyyyMMdd-HHmmss, so name order is time order) and removes the rest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateRange(1, 100000)][int]$Keep
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    $versions = @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue |
            Where-Object Name -Match '^\d{8}-\d{6}' |
            Sort-Object -Property @{ Expression = { $_.Name.Substring(0, 15) } }, @{ Expression = { $_.CreationTimeUtc } } -Descending)
    if ($versions.Count -le $Keep) { return }
    foreach ($old in $versions[$Keep..($versions.Count - 1)]) {
        try {
            Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction Stop
            Write-EdgeSyncEvent "Archive retention: removed '$($old.FullName)'." -Level Verbose
        }
        catch {
            Write-EdgeSyncEvent "Archive retention: could not remove '$($old.FullName)': $($_.Exception.Message)" -Level Warning
        }
    }
}

function Publish-EdgeSyncStoreItem {
    <#
    .SYNOPSIS
        Atomically replaces a store item folder with a prepared temp folder.
    .DESCRIPTION
        The current store copy (if any) is moved into
        <ArchiveRoot>\<yyyyMMdd-HHmmss>-<PreviousMachine>, then <TempPath> is renamed to <FinalPath>.
        If the rename fails the archived copy is moved back. Afterwards the archive is pruned to
        -ArchiveRetention versions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TempPath,
        [Parameter(Mandatory)][string]$FinalPath,
        [Parameter(Mandatory)][string]$ArchiveRoot,
        [AllowNull()][AllowEmptyString()][string]$PreviousMachine,
        [Parameter(Mandatory)][int]$ArchiveRetention
    )
    $archived = $null
    if (Test-Path -LiteralPath $FinalPath) {
        if (-not (Test-Path -LiteralPath $ArchiveRoot -PathType Container)) {
            $null = New-Item -Path $ArchiveRoot -ItemType Directory -Force
        }
        $machine = if ($PreviousMachine) { ConvertTo-EdgeSafeName -Name $PreviousMachine } else { 'unknown' }
        $archived = Get-EdgeSyncUniquePath -Path (Join-Path $ArchiveRoot ('{0}-{1}' -f [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'), $machine))
        Move-Item -LiteralPath $FinalPath -Destination $archived -ErrorAction Stop
    }
    try {
        Move-Item -LiteralPath $TempPath -Destination $FinalPath -ErrorAction Stop
    }
    catch {
        $err = $_
        if ($archived -and -not (Test-Path -LiteralPath $FinalPath)) {
            try { Move-Item -LiteralPath $archived -Destination $FinalPath -ErrorAction Stop } catch { Write-Verbose $_.Exception.Message }
        }
        throw $err
    }
    if ($archived) { Remove-EdgeSyncOldArchive -Path $ArchiveRoot -Keep $ArchiveRetention }
}

function Remove-EdgeSyncOldReplaced {
    <#
    .SYNOPSIS
        Keeps the newest -Keep run folders under <LocalDataPath>\replaced.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LocalDataPath,
        [Parameter(Mandatory)][int]$Keep
    )
    Remove-EdgeSyncOldArchive -Path (Join-Path $LocalDataPath 'replaced') -Keep ([Math]::Max(1, $Keep))
}

function Write-EdgeSyncMachineSummary {
    <#
    .SYNOPSIS
        Writes <SyncRoot>\machines\<MachineId>.json with the summary of the last sync run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SyncRoot,
        [Parameter(Mandatory)][string]$MachineId,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Summary
    )
    $dir = Join-Path $SyncRoot 'machines'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { $null = New-Item -Path $dir -ItemType Directory -Force }
    Write-EdgeJsonFile -Path (Join-Path $dir ("{0}.json" -f (ConvertTo-EdgeSafeName -Name $MachineId))) -InputObject $Summary
}

# --- Tombstones (profiles deleted on purpose; see docs/ARCHITECTURE.md "Tombstones") ------------

function Set-EdgeSyncTombstone {
    <#
    .SYNOPSIS
        Marks a profile key as deleted in the sync store: writes
        <SyncRoot>\store\<Channel>\<ProfileKey>\deleted.json = { Key, Name, DeletedUtc, Machine }.
    .DESCRIPTION
        Other machines then no longer push to or re-create this profile (and remove it locally when
        RemoveDeletedProfiles is on). The store data itself is kept.
    .PARAMETER MachineId
        Machine that deleted the profile (default: this machine).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SyncRoot,
        [Parameter(Mandatory)][ValidateSet('Stable', 'Beta', 'Dev', 'Canary')][string]$Channel,
        [Parameter(Mandatory)][string]$ProfileKey,
        [string]$Name,
        [string]$MachineId
    )
    if (-not $MachineId) { $MachineId = Get-EdgeSyncMachineId }
    $location = Get-EdgeSyncStoreLocation -SyncRoot $SyncRoot -Channel $Channel -Key $ProfileKey
    $file = Join-Path $location.Store 'deleted.json'
    if (-not $PSCmdlet.ShouldProcess($file, 'Write sync tombstone')) { return }
    if (-not (Test-Path -LiteralPath $location.Store -PathType Container)) { $null = New-Item -Path $location.Store -ItemType Directory -Force }
    Write-EdgeJsonFile -Path $file -InputObject ([ordered]@{
            Key        = $ProfileKey
            Name       = $(if ($Name) { $Name } else { $ProfileKey })
            DeletedUtc = [datetime]::UtcNow.ToString('o')
            Machine    = $MachineId
        })
    Write-EdgeSyncEvent "Sync tombstone written for Edge $Channel profile '$ProfileKey'."
}

function Get-EdgeSyncTombstone {
    <#
    .SYNOPSIS
        Lists the tombstones (deleted.json) of a channel in the sync store, optionally for one key.
    .OUTPUTS
        [pscustomobject]@{ Channel; Key; Name; DeletedUtc ([datetime] UTC or $null); Machine; Path }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SyncRoot,
        [Parameter(Mandatory)][ValidateSet('Stable', 'Beta', 'Dev', 'Canary')][string]$Channel,
        [string]$ProfileKey
    )
    $root = Join-Path $SyncRoot "store\$Channel"
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return }
    $dirs = if ($ProfileKey) {
        $d = Join-Path $root $ProfileKey
        if (Test-Path -LiteralPath $d -PathType Container) { Get-Item -LiteralPath $d }
    }
    else { Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue }
    foreach ($dir in @($dirs)) {
        if (-not $dir) { continue }
        $file = Join-Path $dir.FullName 'deleted.json'
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $data = $null
        try { $data = Read-EdgeJsonFile -Path $file }
        catch { Write-EdgeSyncEvent "Tombstone '$file' could not be read (still honoured): $($_.Exception.Message)" -Level Warning }
        $name = [string](Get-EdgeSyncValue $data 'Name')
        [pscustomobject]@{
            Channel    = $Channel
            Key        = $dir.Name
            Name       = $(if ($name) { $name } else { $dir.Name })
            DeletedUtc = ConvertTo-EdgeSyncUtcDate (Get-EdgeSyncValue $data 'DeletedUtc')
            Machine    = [string](Get-EdgeSyncValue $data 'Machine')
            Path       = $file
        }
    }
}

function Remove-EdgeSyncTombstone {
    <#
    .SYNOPSIS
        Removes the tombstone of a profile key (used when the profile was deliberately created again).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SyncRoot,
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][string]$ProfileKey
    )
    $file = Join-Path (Get-EdgeSyncStoreLocation -SyncRoot $SyncRoot -Channel $Channel -Key $ProfileKey).Store 'deleted.json'
    if ((Test-Path -LiteralPath $file -PathType Leaf) -and $PSCmdlet.ShouldProcess($file, 'Remove sync tombstone')) {
        Remove-Item -LiteralPath $file -Force
        Write-EdgeSyncEvent "Sync tombstone removed for Edge $Channel profile '$ProfileKey' (profile was created again)."
    }
}

function Clear-EdgeSyncStateProfile {
    <#
    .SYNOPSIS
        Removes all local state entries of one profile key ("<Channel>|<Key>|*").
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][string]$Key
    )
    $prefix = '{0}|{1}|' -f $Channel, $Key
    foreach ($k in @($State.Items.Keys)) {
        if (([string]$k).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $State.Items.Remove($k) }
    }
}

function Test-EdgeSyncStateProfile {
    # $true when the local state has any entry for the profile key.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][string]$Key
    )
    $prefix = '{0}|{1}|' -f $Channel, $Key
    foreach ($k in $State.Items.Keys) {
        if (([string]$k).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

function ConvertTo-EdgeSyncBool {
    # Robust bool conversion for config values (bool, number or "true"/"false" strings).
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object]$Value, [bool]$Default = $false)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return $Value }
    $text = ([string]$Value).Trim()
    if (-not $text) { return $Default }
    $b = $false
    if ([bool]::TryParse($text, [ref]$b)) { return $b }
    $n = 0
    if ([int]::TryParse($text, [ref]$n)) { return $n -ne 0 }
    $Default
}
