#Requires -Version 7.4
Set-StrictMode -Version 3.0

$privateFiles = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue)
$publicFiles  = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public')  -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($file in @($privateFiles + $publicFiles)) {
    try {
        . $file.FullName
    }
    catch {
        throw "Failed to import '$($file.FullName)': $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function $publicFiles.BaseName

# EDGEProfiles 1.x (the predecessor) exports Backup-EdgeProfiles / Restore-EdgeProfiles with different
# parameters. When both are installed, Windows PowerShell or a session that loaded the old module first
# silently runs the old commands. Cheap check (folder lookup only), warns once per session.
if (-not (Get-Variable -Name EdgeProfileSyncLegacyChecked -Scope Global -ErrorAction Ignore)) {
    $global:EdgeProfileSyncLegacyChecked = $true
    $legacy = foreach ($dir in ($env:PSModulePath -split [System.IO.Path]::PathSeparator)) {
        if ($dir -and (Test-Path -LiteralPath (Join-Path $dir 'EdgeProfiles') -PathType Container)) { Join-Path $dir 'EdgeProfiles' }
    }
    if ($legacy) {
        Write-Warning ("The old EDGEProfiles module is also installed ($(@($legacy)[0])). It has commands with the same names " +
            '(Backup-EdgeProfiles, Restore-EdgeProfiles) but different parameters. Remove it with: Uninstall-Module EdgeProfiles -AllVersions ' +
            '(in Windows PowerShell as well), or call the commands as EdgeProfileSync\Restore-EdgeProfiles.')
    }
}
