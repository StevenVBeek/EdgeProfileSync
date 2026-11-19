# Core helpers: JSON read/write. Edge's Local State contains empty-string property names, so
# everything is read as hashtables. Date-like strings stay strings where PowerShell supports it (7.5+).

$script:EdgeJsonSupportsDateKind = (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')

function Read-EdgeJsonFile {
    <#
    .SYNOPSIS
        Reads a JSON file into nested hashtables / arrays. Throws when the file is missing or invalid.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "JSON file not found: $Path"
    }

    # Open with ReadWrite sharing so files Edge holds open can still be read.
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        $reader = [IO.StreamReader]::new($fs, [Text.UTF8Encoding]::new($false), $true)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally {
        $fs.Dispose()
    }

    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $params = @{ AsHashtable = $true; Depth = 200; NoEnumerate = $true }
    if ($script:EdgeJsonSupportsDateKind) { $params['DateKind'] = 'String' }
    try {
        $text | ConvertFrom-Json @params
    }
    catch {
        throw "Invalid JSON in '$Path': $($_.Exception.Message)"
    }
}

function Write-EdgeJsonFile {
    <#
    .SYNOPSIS
        Writes an object as compressed JSON, UTF-8 without BOM, atomically (temp file + replace).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject,

        [int]$Depth = 100
    )

    $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress
    $full = [IO.Path]::GetFullPath($Path)
    $dir = [IO.Path]::GetDirectoryName($full)
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        $null = New-Item -Path $dir -ItemType Directory -Force
    }

    $temp = Join-Path $dir ('.{0}.tmp-{1}' -f [IO.Path]::GetFileName($full), [guid]::NewGuid().ToString('N').Substring(0, 8))
    [IO.File]::WriteAllText($temp, $json, [Text.UTF8Encoding]::new($false))

    try {
        $attempt = 0
        while ($true) {
            $attempt++
            try {
                if ([IO.File]::Exists($full)) {
                    try {
                        [IO.File]::Replace($temp, $full, [NullString]::Value, $true)
                    }
                    catch [System.PlatformNotSupportedException], [System.UnauthorizedAccessException] {
                        [IO.File]::Move($temp, $full, $true)
                    }
                }
                else {
                    [IO.File]::Move($temp, $full, $true)
                }
                break
            }
            catch [System.IO.IOException] {
                if ($attempt -ge 3) { throw }
                Start-Sleep -Milliseconds (250 * $attempt)
            }
        }
    }
    finally {
        if ([IO.File]::Exists($temp)) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}
