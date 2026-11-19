function Get-EdgeProfile {
    <#
    .SYNOPSIS
        Lists the Microsoft Edge profiles of the current user, with details useful for cleanup.

    .DESCRIPTION
        Returns one object per Edge profile (from 'Local State') for each selected channel:
        Channel, Directory, Name, Key (used in backups and sync), Account, IsSignedIn, Protected (why restore,
        sync and cleanup leave the profile alone: 'Default profile' / 'signed in with an account'), LastActiveUtc /
        LastActive (local time), InUse (loaded by a running Edge), BookmarkCount, ExtensionCount,
        PendingExtensions (extensions still to install, see Install-EdgeProfileExtension), SizeMB (only
        with -IncludeSize: the whole profile folder) and SyncState ('Synced', 'LocalOnly',
        'Deleted elsewhere', or empty when no sync store exists).

        Pipe the output to Remove-EdgeProfile to clean up profiles in bulk.

    .PARAMETER Channel
        Edge channel(s): Stable (default), Beta, Dev, Canary.

    .PARAMETER Name
        Only return profiles whose Name, Key or Directory matches one of these values (wildcards allowed).
        Alias: Profile.

    .PARAMETER IncludeSize
        Calculate SizeMB (size of the whole profile folder; can take a while for large profiles).

    .PARAMETER All
        Also list profile folders that exist on disk but are missing from Local State (Name '(orphan)').

    .EXAMPLE
        Get-EdgeProfile

    .EXAMPLE
        Get-EdgeProfile -IncludeSize | Sort-Object SizeMB -Descending

    .EXAMPLE
        Get-EdgeProfile | Where-Object LastActiveUtc -lt (Get-Date).AddMonths(-6) | Remove-EdgeProfile
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Stable', 'Beta', 'Dev', 'Canary')]
        [string[]]$Channel = @('Stable'),

        [Parameter(Position = 0)]
        [Alias('Profile', 'ProfileName')]
        [SupportsWildcards()]
        [string[]]$Name,

        [switch]$IncludeSize,

        [switch]$All,

        # Overrides the User Data folder (tests).
        [Parameter(DontShow)]
        [string]$UserDataRoot,

        # Overrides the sync root used for SyncState (tests).
        [Parameter(DontShow)]
        [string]$SyncRoot
    )

    $syncRootPath = Get-EdgeBackupSyncRoot -SyncRoot $SyncRoot
    $storeExists = $syncRootPath -and (Test-Path -LiteralPath (Join-Path $syncRootPath 'store') -PathType Container)

    foreach ($ch in $Channel) {
        $info = Get-EdgeChannelInfo -Channel $ch -UserDataRoot $UserDataRoot
        $profiles = @(Get-EdgeLocalProfile -Channel $ch -UserDataRoot $UserDataRoot)
        if ($All) { $profiles += @(Get-EdgeOrphanProfile -UserDataPath $info.UserDataPath -Channel $ch -Registered $profiles) }

        $selected = @(Select-EdgeProfileByFilter -InputObject $profiles -Filter $Name)
        $activity = $IncludeSize ? "Reading Edge $ch profiles (with folder sizes)" : "Reading Edge $ch profiles"
        $progress = New-EdgeProgress -Activity $activity -Total $selected.Count -Unit Steps -Id 30
        try {
            $index = 0
            foreach ($p in $selected) {
                $index++
                Update-EdgeProgress -Progress $progress -Done ($index - 1) -Status ("Reading profile {0}/{1} '{2}'" -f $index, $selected.Count, $p.Name) -CurrentOperation $p.Directory -Force
                $isOrphan = [bool]($p.PSObject.Properties['IsOrphan'] -and $p.IsOrphan)
                $lastActiveUtc = $p.PSObject.Properties['LastActiveUtc'] ? $p.LastActiveUtc : $null

                $syncState = ''
                if ($storeExists -and -not $isOrphan) {
                    # Tombstone written by Remove-EdgeProfile / the sync engine: store\<Channel>\<Key>\deleted.json
                    $storeDir = Join-Path $syncRootPath "store\$ch\$($p.Key)"
                    $syncState = if (Test-Path -LiteralPath (Join-Path $storeDir 'deleted.json') -PathType Leaf) { 'Deleted elsewhere' }
                    elseif (Test-Path -LiteralPath $storeDir -PathType Container) { 'Synced' }
                    else { 'LocalOnly' }
                }

                $out = [ordered]@{
                    PSTypeName        = 'EdgeProfileSync.Profile'
                    Channel           = $ch
                    Directory         = $p.Directory
                    Name              = $p.Name
                    Key               = $p.Key
                    Account           = $p.PSObject.Properties['Account'] ? [string]$p.Account : ''
                    IsSignedIn        = [bool]$p.IsSignedIn
                    Protected         = $isOrphan ? '' : (Test-EdgeProtectedProfile $p -Reason)
                    LastActiveUtc     = $lastActiveUtc
                    LastActive        = $lastActiveUtc ? ([datetime]$lastActiveUtc).ToLocalTime() : $null
                    InUse             = Test-EdgeProfileInUse -Path $p.Path
                    BookmarkCount     = Get-EdgeBookmarkCount -Path (Join-Path $p.Path 'Bookmarks')
                    ExtensionCount    = @(Get-EdgeExtensionInventory -ProfilePath $p.Path -WarningAction SilentlyContinue).Count
                    PendingExtensions = $isOrphan ? 0 : @(Get-EdgePendingExtension -Channel $ch -ProfileKey $p.Key).Count
                    SizeMB            = $null
                    SyncState         = $syncState
                    IsOrphan          = $isOrphan
                    Path              = $p.Path
                }
                if ($IncludeSize) {
                    Update-EdgeProgress -Progress $progress -Status ("Reading profile {0}/{1} '{2}' - measuring folder size" -f $index, $selected.Count, $p.Name) -CurrentOperation $p.Path -Force
                    $bytes = [long](Get-EdgePathSize -Path $p.Path)
                    $out.SizeMB = [math]::Round($bytes / 1MB, 1)
                }
                [pscustomobject]$out
            }
        }
        finally { Complete-EdgeProgress -Progress $progress }
    }
}
