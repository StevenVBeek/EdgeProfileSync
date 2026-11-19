# Extensions: inventory of the extensions installed in a profile, and the per-profile list of
# extensions that still have to be (re)installed after a restore or sync ("pending" list).
# Used by Backup-EdgeProfiles, Restore-EdgeProfiles, Install-EdgeProfileExtension, Get-EdgeProfile
# and the sync engine.

# Chromium Manifest::Location values.
$script:EdgeExtLocationUnpacked = 4
$script:EdgeExtLocationsComponent = @(5, 10)           # COMPONENT, EXTERNAL_COMPONENT
$script:EdgeExtLocationsPolicy = @(7, 9)               # EXTERNAL_POLICY_DOWNLOAD, EXTERNAL_POLICY

function Get-EdgeExtensionStoreUrl {
    <#
    .SYNOPSIS
        Store page URL for an extension id: Edge Add-ons (EdgeStore) or Chrome Web Store (ChromeStore).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Id,
        [ValidateSet('EdgeStore', 'ChromeStore')][string]$Source = 'EdgeStore'
    )
    if ($Source -eq 'ChromeStore') { "https://chromewebstore.google.com/detail/$Id" }
    else { "https://microsoftedge.microsoft.com/addons/detail/$Id" }
}

function Resolve-EdgeExtensionMessage {
    # Resolves a "__MSG_key__" manifest string from the extension's _locales folder (best effort).
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [AllowNull()][AllowEmptyString()][string]$ExtensionDir,
        [AllowNull()][AllowEmptyString()][string]$DefaultLocale
    )
    if (-not $Value -or $Value -notmatch '^__MSG_(.+)__$') { return $Value }
    $key = $Matches[1]
    if (-not $ExtensionDir -or -not (Test-Path -LiteralPath $ExtensionDir -PathType Container)) { return $Value }

    foreach ($locale in (@($DefaultLocale, 'en', 'en_US', 'en_GB') | Where-Object { $_ } | Select-Object -Unique)) {
        $file = Join-Path $ExtensionDir "_locales\$locale\messages.json"
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        try {
            $messages = Read-EdgeJsonFile -Path $file
            if ($messages -isnot [System.Collections.IDictionary]) { continue }
            foreach ($k in $messages.Keys) {
                $m = $messages[$k]
                if ($k -ieq $key -and $m -is [System.Collections.IDictionary] -and $m['message']) { return [string]$m['message'] }
            }
        }
        catch { Write-Verbose "Could not read '$file': $($_.Exception.Message)" }
    }
    $Value
}

function Get-EdgeExtensionInventory {
    <#
    .SYNOPSIS
        Lists the extensions installed in an Edge profile folder.
    .DESCRIPTION
        Merges extensions.settings from 'Preferences' and 'Secure Preferences' (the latter wins).
        Name, version and update_url come from the settings' manifest, or else from
        Extensions\<id>\<version>\manifest.json. Component extensions (location 5/10) and extensions
        installed by default (was_installed_by_default) are skipped, as are stub entries without a
        manifest. Returns objects: Id, Name, Version, Enabled, Source
        ('EdgeStore'|'ChromeStore'|'Policy'|'Unpacked'|'Other'), StoreUrl.
    .PARAMETER ProfilePath
        Full path of the profile folder, e.g. "...\User Data\Profile 3".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilePath
    )

    $settings = @{}
    foreach ($fileName in 'Preferences', 'Secure Preferences') {
        $file = Join-Path $ProfilePath $fileName
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        try { $json = Read-EdgeJsonFile -Path $file }
        catch {
            Write-Warning "Could not read '$file': $($_.Exception.Message)"
            continue
        }
        $ext = $json -is [System.Collections.IDictionary] ? $json['extensions'] : $null
        $set = $ext -is [System.Collections.IDictionary] ? $ext['settings'] : $null
        if ($set -isnot [System.Collections.IDictionary]) { continue }
        foreach ($id in $set.Keys) {
            if ($set[$id] -isnot [System.Collections.IDictionary]) { continue }
            if ($settings.ContainsKey($id)) {
                # Merge: Secure Preferences values override Preferences values.
                $merged = @{}
                foreach ($k in $settings[$id].Keys) { $merged[$k] = $settings[$id][$k] }
                foreach ($k in $set[$id].Keys) { $merged[$k] = $set[$id][$k] }
                $settings[$id] = $merged
            }
            else { $settings[$id] = $set[$id] }
        }
    }

    $extensionsRoot = Join-Path $ProfilePath 'Extensions'
    foreach ($id in ($settings.Keys | Sort-Object)) {
        $entry = $settings[$id]
        $location = $entry['location'] -as [int]
        if ($null -ne $location -and $location -in $script:EdgeExtLocationsComponent) { continue }
        if ([bool]$entry['was_installed_by_default']) { continue }

        # Extension folder on disk (for manifest.json and _locales).
        $extDir = $null
        if ($entry['path']) {
            $p = [string]$entry['path']
            $extDir = [System.IO.Path]::IsPathRooted($p) ? $p : (Join-Path $extensionsRoot $p)
        }
        if (-not $extDir -or -not (Test-Path -LiteralPath $extDir -PathType Container)) {
            $idDir = Join-Path $extensionsRoot $id
            $extDir = if (Test-Path -LiteralPath $idDir -PathType Container) {
                Get-ChildItem -LiteralPath $idDir -Directory | Sort-Object { ($_.Name -replace '_\d+$') -as [version] }, Name | Select-Object -Last 1 -ExpandProperty FullName
            }
        }

        $manifest = $entry['manifest']
        if ($manifest -isnot [System.Collections.IDictionary] -and $extDir) {
            $mf = Join-Path $extDir 'manifest.json'
            if (Test-Path -LiteralPath $mf -PathType Leaf) {
                try { $manifest = Read-EdgeJsonFile -Path $mf } catch { Write-Verbose "Could not read '$mf': $($_.Exception.Message)" }
            }
        }
        if ($manifest -isnot [System.Collections.IDictionary]) { continue }   # stub entry, not installed

        $updateUrl = [string]$manifest['update_url']
        $source = if ($null -ne $location -and $location -in $script:EdgeExtLocationsPolicy) { 'Policy' }
        elseif ($location -eq $script:EdgeExtLocationUnpacked) { 'Unpacked' }
        elseif ($updateUrl -match 'edge\.microsoft\.com') { 'EdgeStore' }
        elseif ($updateUrl -match 'clients2\.google\.com|chromewebstore' -or [bool]$entry['from_webstore']) { 'ChromeStore' }
        else { 'Other' }

        $enabled = $true
        $dr = $entry['disable_reasons']
        if ($null -ne $dr) {
            $enabled = ($dr -is [System.Collections.IEnumerable] -and $dr -isnot [string]) ? (@($dr).Count -eq 0) : (($dr -as [int]) -eq 0)
        }
        if ($null -ne $entry['state'] -and ($entry['state'] -as [int]) -eq 0) { $enabled = $false }

        [pscustomobject]@{
            Id       = $id
            Name     = Resolve-EdgeExtensionMessage -Value ([string]$manifest['name']) -ExtensionDir $extDir -DefaultLocale ([string]$manifest['default_locale'])
            Version  = [string]$manifest['version']
            Enabled  = $enabled
            Source   = $source
            StoreUrl = $source -in 'EdgeStore', 'ChromeStore' ? (Get-EdgeExtensionStoreUrl -Id $id -Source $source) : $null
        }
    }
}

function Get-EdgePendingExtensionFile {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][string]$ProfileKey
    )
    Join-Path (Get-EdgeSyncLocalDataPath) "pending-extensions\$Channel\$ProfileKey.json"
}

function Get-EdgePendingExtension {
    <#
    .SYNOPSIS
        Reads the pending-install lists (<LocalDataPath>\pending-extensions\<Channel>\<ProfileKey>.json).
    .DESCRIPTION
        Returns one object per pending extension: Channel, ProfileKey, Id, Name, Version, Source, StoreUrl, AddedUtc.
        -Channel / -ProfileKey filter (exact match; both optional).
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Stable', 'Beta', 'Dev', 'Canary')][string]$Channel,
        [string]$ProfileKey
    )
    $root = Join-Path (Get-EdgeSyncLocalDataPath) 'pending-extensions'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return }

    $files = if ($Channel -and $ProfileKey) {
        $f = Get-EdgePendingExtensionFile -Channel $Channel -ProfileKey $ProfileKey
        if (Test-Path -LiteralPath $f -PathType Leaf) { Get-Item -LiteralPath $f }
    }
    else {
        Get-ChildItem -LiteralPath $root -Filter '*.json' -File -Recurse |
            Where-Object { -not $Channel -or $_.Directory.Name -eq $Channel } |
            Where-Object { -not $ProfileKey -or $_.BaseName -eq $ProfileKey }
    }

    foreach ($file in @($files)) {
        if (-not $file) { continue }
        try { $data = Read-EdgeJsonFile -Path $file.FullName }
        catch {
            Write-Warning "Could not read pending extension list '$($file.FullName)': $($_.Exception.Message)"
            continue
        }
        if ($data -isnot [System.Collections.IDictionary]) { continue }
        foreach ($e in @($data['Extensions'])) {
            if ($e -isnot [System.Collections.IDictionary]) { continue }
            [pscustomobject]@{
                Channel    = [string]($data['Channel'] ?? $file.Directory.Name)
                ProfileKey = [string]($data['ProfileKey'] ?? $file.BaseName)
                Id         = [string]$e['Id']
                Name       = [string]$e['Name']
                Version    = [string]$e['Version']
                Source     = [string]$e['Source']
                StoreUrl   = $e['StoreUrl']
                AddedUtc   = $e['AddedUtc']
            }
        }
    }
}

function Set-EdgePendingExtension {
    <#
    .SYNOPSIS
        Replaces the pending-install list of one profile. An empty list deletes the file.
    .PARAMETER Extension
        Objects with at least Id (and ideally Name, Version, Source, StoreUrl), e.g. from Get-EdgeExtensionInventory.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateSet('Stable', 'Beta', 'Dev', 'Canary')][string]$Channel,
        [Parameter(Mandatory)][string]$ProfileKey,
        [AllowNull()][AllowEmptyCollection()][object[]]$Extension
    )
    $file = Get-EdgePendingExtensionFile -Channel $Channel -ProfileKey $ProfileKey
    $items = @($Extension | Where-Object { $_ })
    if (-not $items) {
        if ((Test-Path -LiteralPath $file) -and $PSCmdlet.ShouldProcess($file, 'Remove pending extension list')) {
            Remove-Item -LiteralPath $file -Force
        }
        return
    }

    $now = [datetime]::UtcNow.ToString('o')
    $list = foreach ($e in $items) {
        $get = { param($n) if ($e -is [System.Collections.IDictionary]) { $e[$n] } else { $e.PSObject.Properties[$n]?.Value } }
        [ordered]@{
            Id       = [string](& $get 'Id')
            Name     = [string](& $get 'Name')
            Version  = [string](& $get 'Version')
            Source   = [string](& $get 'Source')
            StoreUrl = & $get 'StoreUrl'
            AddedUtc = (& $get 'AddedUtc') ?? $now
        }
    }
    if ($PSCmdlet.ShouldProcess($file, "Write pending extension list ($(@($list).Count))")) {
        $dir = Split-Path $file
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        Write-EdgeJsonFile -Path $file -InputObject ([ordered]@{
                Channel    = $Channel
                ProfileKey = $ProfileKey
                UpdatedUtc = $now
                Extensions = @($list)
            })
    }
}
