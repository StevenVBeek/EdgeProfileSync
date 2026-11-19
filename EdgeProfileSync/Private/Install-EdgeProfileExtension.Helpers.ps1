# Internal helpers for Install-EdgeProfileExtension (not exported).

function New-EdgeExtensionInstallResult {
    param($Channel, $Prof, $Extension, [string]$Action)
    [pscustomobject]@{
        Channel   = $Channel
        Profile   = $Prof.Name
        Directory = $Prof.Directory
        Id        = $Extension.Id
        Name      = $Extension.Name
        Source    = $Extension.Source
        StoreUrl  = $Extension.StoreUrl
        Action    = $Action
    }
}

function Get-EdgeExecutablePath {
    # msedge.exe of a channel (per-machine or per-user install), or $null.
    [CmdletBinding()]
    [OutputType([string])]
    param([ValidateSet('Stable', 'Beta', 'Dev', 'Canary')][string]$Channel = 'Stable')
    $folder = (Get-EdgeChannelInfo -Channel $Channel).FolderName
    foreach ($base in ${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA) {
        if (-not $base) { continue }
        $exe = Join-Path $base "Microsoft\$folder\Application\msedge.exe"
        if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
    }
    $null
}
