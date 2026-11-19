# Core helpers: Edge channels, machine id, local data folder and safe names.

$script:EdgeChannelFolders = [ordered]@{
    Stable = 'Edge'
    Beta   = 'Edge Beta'
    Dev    = 'Edge Dev'
    Canary = 'Edge SxS'
}

function Get-EdgeChannelInfo {
    <#
    .SYNOPSIS
        Returns paths and registry key for an Edge channel.
    .DESCRIPTION
        -UserDataRoot overrides the User Data path (used by tests).
        Extra property: FolderName ('Edge', 'Edge Beta', 'Edge Dev', 'Edge SxS'), the folder name used
        under %LOCALAPPDATA%\Microsoft and under the install folder (used to match msedge.exe paths).
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Stable', 'Beta', 'Dev', 'Canary')]
        [string]$Channel = 'Stable',

        [string]$UserDataRoot
    )

    $folder = $script:EdgeChannelFolders[$Channel]
    $userData = if ($UserDataRoot) {
        $UserDataRoot
    }
    else {
        Join-Path $env:LOCALAPPDATA "Microsoft\$folder\User Data"
    }

    [pscustomobject]@{
        Channel      = $Channel
        UserDataPath = $userData
        RegistryKey  = "HKCU\Software\Microsoft\$folder\PreferenceMACs"
        Installed    = [bool](Test-Path -LiteralPath $userData -PathType Container)
        FolderName   = $folder
    }
}

function Get-EdgeSyncMachineId {
    <#
    .SYNOPSIS
        Stable machine id: "<COMPUTERNAME>-<first 8 chars of HKLM MachineGuid>".
        Falls back to a hash of the computer name when the MachineGuid cannot be read.
    #>
    [CmdletBinding()]
    param()

    $computer = $env:COMPUTERNAME
    if (-not $computer) { $computer = [Environment]::MachineName }

    $guid = $null
    try {
        $guid = Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name 'MachineGuid' -ErrorAction Stop
    }
    catch {
        Write-Verbose "Could not read MachineGuid: $($_.Exception.Message)"
    }

    if (-not $guid) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($computer.ToUpperInvariant())
        $guid = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }

    $short = ([string]$guid).Replace('-', '').Replace('{', '')
    if ($short.Length -gt 8) { $short = $short.Substring(0, 8) }
    '{0}-{1}' -f (ConvertTo-EdgeSafeName -Name $computer), $short.ToLowerInvariant()
}

function Get-EdgeSyncLocalDataPath {
    <#
    .SYNOPSIS
        Returns (and creates) the local data folder: $env:EDGEPROFILESYNC_HOME or %LOCALAPPDATA%\EdgeProfileSync.
    #>
    [CmdletBinding()]
    param()

    $path = if ($env:EDGEPROFILESYNC_HOME) {
        $env:EDGEPROFILESYNC_HOME
    }
    else {
        Join-Path $env:LOCALAPPDATA 'EdgeProfileSync'
    }

    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        $null = New-Item -Path $path -ItemType Directory -Force -WhatIf:$false
    }
    $path
}

function ConvertTo-EdgeSafeName {
    <#
    .SYNOPSIS
        Filesystem-safe name: invalid chars -> '_', trimmed, trailing dots removed, max 80 chars.
        Empty input becomes '_'; reserved device names (CON, NUL, COM1, ...) get a '_' suffix.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Name
    )

    process {
        $invalid = [IO.Path]::GetInvalidFileNameChars()
        $sb = [Text.StringBuilder]::new($Name.Length)
        foreach ($ch in $Name.ToCharArray()) {
            if ($invalid -contains $ch) { $null = $sb.Append('_') } else { $null = $sb.Append($ch) }
        }
        $safe = $sb.ToString().Trim().TrimEnd('.').Trim()
        if ($safe.Length -gt 80) { $safe = $safe.Substring(0, 80).TrimEnd('.').Trim() }
        if (-not $safe) { $safe = '_' }
        if ($safe -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') { $safe = "${safe}_" }
        $safe
    }
}
