# Core helpers: enumerate and create local Edge profiles from 'Local State'.

$script:EdgeSkippedProfileDirs = @('Guest Profile', 'System Profile')

# info_cache fields that identify an account; never copied to a new profile on another machine.
$script:EdgeAccountInfoFields = @(
    'user_name', 'gaia_id', 'gaia_name', 'gaia_given_name', 'gaia_picture_file_name',
    'last_downloaded_gaia_picture_url_with_size', 'hosted_domain',
    'is_consented_primary_account', 'managed_user_id', 'is_managed', 'enterprise_label',
    'user_accepted_account_management', 'use_gaia_picture', 'force_signin_profile_locked'
)

function Get-EdgeProfileSortKey {
    # Internal: 'Default' first, then 'Profile N' numerically, then anything else alphabetically.
    param([string]$Directory)
    if ($Directory -eq 'Default') { return '0' }
    if ($Directory -match '^Profile (\d+)$') { return '1{0:D10}' -f [int64]$Matches[1] }
    '2' + $Directory.ToLowerInvariant()
}

function Get-EdgeLocalProfile {
    <#
    .SYNOPSIS
        One object per profile listed in Local State info_cache whose folder exists.
    .DESCRIPTION
        Order: profiles_order first, then remaining info_cache entries (Default, Profile 1, 2, ...).
        Key = ConvertTo-EdgeSafeName(Name). Duplicate keys (case-insensitive): the first keeps the bare
        key, later ones get "<key> (<Directory>)".
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Stable', 'Beta', 'Dev', 'Canary')]
        [string]$Channel = 'Stable',

        [string]$UserDataRoot
    )

    $info = Get-EdgeChannelInfo -Channel $Channel -UserDataRoot $UserDataRoot
    $localStatePath = Join-Path $info.UserDataPath 'Local State'
    if (-not (Test-Path -LiteralPath $localStatePath -PathType Leaf)) {
        Write-Verbose "No Local State for Edge $Channel at '$localStatePath'."
        return
    }

    $state = Read-EdgeJsonFile -Path $localStatePath
    if ($state -isnot [System.Collections.IDictionary] -or -not $state.Contains('profile')) { return }
    $profileNode = $state['profile']
    if ($profileNode -isnot [System.Collections.IDictionary] -or -not $profileNode.Contains('info_cache')) { return }
    $infoCache = $profileNode['info_cache']
    if ($infoCache -isnot [System.Collections.IDictionary]) { return }

    $order = [System.Collections.Generic.List[string]]::new()
    if ($profileNode.Contains('profiles_order') -and $null -ne $profileNode['profiles_order']) {
        foreach ($d in @($profileNode['profiles_order'])) {
            if ($d -is [string] -and $infoCache.Contains($d) -and -not $order.Contains($d)) { $order.Add($d) }
        }
    }
    foreach ($d in @($infoCache.Keys | Sort-Object { Get-EdgeProfileSortKey -Directory $_ })) {
        if (-not $order.Contains($d)) { $order.Add($d) }
    }

    $usedKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($dir in $order) {
        if ($dir -in $script:EdgeSkippedProfileDirs) { continue }
        $path = Join-Path $info.UserDataPath $dir
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }

        $entry = $infoCache[$dir]
        if ($entry -isnot [System.Collections.IDictionary]) { $entry = @{} }

        $name = if ($entry.Contains('name') -and -not [string]::IsNullOrWhiteSpace([string]$entry['name'])) { [string]$entry['name'] } else { $dir }
        $key = ConvertTo-EdgeSafeName -Name $name
        if (-not $usedKeys.Add($key)) {
            $key = '{0} ({1})' -f $key, $dir
            $null = $usedKeys.Add($key)
        }
        $userName = if ($entry.Contains('user_name')) { [string]$entry['user_name'] } else { '' }

        # active_time: seconds since the Unix epoch (double) of the last time the profile was active.
        $lastActive = $null
        if ($entry.Contains('active_time') -and $null -ne $entry['active_time']) {
            try { $lastActive = [DateTime]::UnixEpoch.AddSeconds([double]$entry['active_time']) } catch { $lastActive = $null }
        }

        [pscustomobject]@{
            Channel       = $Channel
            Directory     = $dir
            Path          = $path
            Name          = $name
            Key           = $key
            IsSignedIn    = -not [string]::IsNullOrWhiteSpace($userName)
            Account       = $userName
            LastActiveUtc = $lastActive
            InfoCache     = $entry
        }
    }
}

function New-EdgeLocalProfile {
    <#
    .SYNOPSIS
        Creates the next free "Profile N" folder and registers it in Local State. Edge must be closed.
    .DESCRIPTION
        Copies -InfoCache minus account fields, sets name, appends to profiles_order. Backs up Local State
        to "Local State.edgeprofilesync.bak" first. Creates a minimal Local State when none exists.
        Returns the new profile object (as Get-EdgeLocalProfile).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [System.Collections.IDictionary]$InfoCache,

        [ValidateSet('Stable', 'Beta', 'Dev', 'Canary')]
        [string]$Channel = 'Stable',

        [string]$UserDataRoot
    )

    $info = Get-EdgeChannelInfo -Channel $Channel -UserDataRoot $UserDataRoot
    $userData = $info.UserDataPath
    $localStatePath = Join-Path $userData 'Local State'

    if (Test-Path -LiteralPath $localStatePath -PathType Leaf) {
        $state = Read-EdgeJsonFile -Path $localStatePath
    }
    else {
        $state = $null
    }
    if ($state -isnot [System.Collections.IDictionary]) { $state = [ordered]@{} }
    if (-not $state.Contains('profile') -or $state['profile'] -isnot [System.Collections.IDictionary]) { $state['profile'] = [ordered]@{} }
    $profileNode = $state['profile']
    if (-not $profileNode.Contains('info_cache') -or $profileNode['info_cache'] -isnot [System.Collections.IDictionary]) { $profileNode['info_cache'] = [ordered]@{} }
    $infoCacheNode = $profileNode['info_cache']

    $n = 1
    while ($infoCacheNode.Contains("Profile $n") -or (Test-Path -LiteralPath (Join-Path $userData "Profile $n"))) { $n++ }
    $dir = "Profile $n"
    $path = Join-Path $userData $dir

    if (-not $PSCmdlet.ShouldProcess("$path ('$Name')", 'Create Edge profile')) { return }

    $entry = [ordered]@{}
    if ($InfoCache) {
        foreach ($k in $InfoCache.Keys) {
            $ks = [string]$k
            if ($ks -in $script:EdgeAccountInfoFields) { continue }
            if ($ks.StartsWith('edge_account', [StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($ks.StartsWith('signin', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $entry[$ks] = $InfoCache[$k]
        }
    }
    $entry['name'] = $Name
    $entry['is_using_default_name'] = $false
    if (-not $entry.Contains('avatar_icon')) {
        $entry['avatar_icon'] = 'chrome://theme/IDR_PROFILE_AVATAR_0'
        $entry['is_using_default_avatar'] = $true
    }
    $infoCacheNode[$dir] = $entry

    $order = [System.Collections.Generic.List[object]]::new()
    if ($profileNode.Contains('profiles_order') -and $null -ne $profileNode['profiles_order']) {
        foreach ($d in @($profileNode['profiles_order'])) { $order.Add($d) }
    }
    if (-not $order.Contains($dir)) { $order.Add($dir) }
    $profileNode['profiles_order'] = $order.ToArray()

    if (Test-Path -LiteralPath $localStatePath -PathType Leaf) {
        Copy-Item -LiteralPath $localStatePath -Destination (Join-Path $userData 'Local State.edgeprofilesync.bak') -Force
    }
    $null = New-Item -Path $path -ItemType Directory -Force
    Write-EdgeJsonFile -Path $localStatePath -InputObject $state

    Get-EdgeLocalProfile -Channel $Channel -UserDataRoot $UserDataRoot | Where-Object Directory -eq $dir
}

function Remove-EdgeLocalProfile {
    <#
    .SYNOPSIS
        Unregisters a profile from Local State and removes its folder. Edge must be closed (caller's job).
    .DESCRIPTION
        Removes the info_cache entry and every reference in profiles_order, last_active_profiles and
        last_used. Backs up Local State to "Local State.edgeprofilesync.bak" first. The folder goes to the
        Recycle Bin by default; -Permanent deletes it; -KeepFolder leaves it on disk.
        'Default' cannot be removed (Edge recreates it). Returns nothing.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [string]$Directory,

        [ValidateSet('Stable', 'Beta', 'Dev', 'Canary')]
        [string]$Channel = 'Stable',

        [string]$UserDataRoot,

        [switch]$Permanent,

        [switch]$KeepFolder
    )

    if ($Directory -eq 'Default') { throw "The 'Default' profile cannot be removed; Edge recreates it." }
    if ($Directory -in $script:EdgeSkippedProfileDirs -or $Directory -match '[\\/]|\.\.') {
        throw "Refusing to remove '$Directory'."
    }

    $info = Get-EdgeChannelInfo -Channel $Channel -UserDataRoot $UserDataRoot
    $userData = $info.UserDataPath
    $localStatePath = Join-Path $userData 'Local State'
    $path = Join-Path $userData $Directory

    if (-not $PSCmdlet.ShouldProcess("$path", 'Remove Edge profile')) { return }

    if (Test-Path -LiteralPath $localStatePath -PathType Leaf) {
        $state = Read-EdgeJsonFile -Path $localStatePath
        if ($state -is [System.Collections.IDictionary] -and $state.Contains('profile') -and $state['profile'] -is [System.Collections.IDictionary]) {
            $profileNode = $state['profile']
            if ($profileNode.Contains('info_cache') -and $profileNode['info_cache'] -is [System.Collections.IDictionary]) {
                $profileNode['info_cache'].Remove($Directory)
            }
            foreach ($listKey in 'profiles_order', 'last_active_profiles') {
                if ($profileNode.Contains($listKey) -and $null -ne $profileNode[$listKey]) {
                    $profileNode[$listKey] = @(@($profileNode[$listKey]) | Where-Object { $_ -ne $Directory })
                }
            }
            if ($profileNode.Contains('last_used') -and $profileNode['last_used'] -eq $Directory) {
                $profileNode['last_used'] = 'Default'
            }
            Copy-Item -LiteralPath $localStatePath -Destination (Join-Path $userData 'Local State.edgeprofilesync.bak') -Force
            Write-EdgeJsonFile -Path $localStatePath -InputObject $state
        }
    }

    if ($KeepFolder -or -not (Test-Path -LiteralPath $path -PathType Container)) { return }

    if ($Permanent) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
    else {
        Add-Type -AssemblyName Microsoft.VisualBasic
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
            $path,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
    }
}

function Test-EdgeProfileInUse {
    <#
    .SYNOPSIS
        $true when a running Edge has this profile loaded.
    .DESCRIPTION
        Edge keeps a loaded profile's History / Favicons / Web Data databases open without share-write access.
        Opening one of them for read while denying write sharing fails with a sharing violation when the profile is loaded. A profile
        without any of these files counts as not in use.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    foreach ($name in 'History', 'Favicons', 'Web Data') {
        $file = Join-Path $Path $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        try {
            $fs = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $fs.Dispose()
        }
        catch [System.IO.IOException] {
            return $true
        }
        catch [System.UnauthorizedAccessException] {
            return $true
        }
    }
    $false
}
