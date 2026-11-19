# Internal helpers for Register-EdgeProfileSyncTask (not exported).

$script:EdgeSyncTaskPath = '\EdgeProfileSync\'

function Get-EdgeSyncTaskUser {
    # Module-internal: "DOMAIN\user" (or "AzureAD\user") of the current user.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Get-EdgeSyncTaskName {
    # Module-internal: "EdgeProfileSync - <user>" with characters that are invalid in task names replaced.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$UserName = $env:USERNAME
    )
    $safe = $UserName -replace '[\\/:*?"<>|]', '_'
    "EdgeProfileSync - $safe"
}

function Get-EdgeSyncPwshPath {
    # Module-internal: full path of pwsh.exe for the scheduled task action.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $command = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.Source) { return $command.Source }
    Join-Path $PSHOME 'pwsh.exe'
}

function New-EdgeSyncSessionLockTrigger {
    # Module-internal: Task Scheduler trigger that fires when the given user locks the workstation.
    # There is no New-ScheduledTaskTrigger switch for this, so the CIM instance is built directly.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$UserId
    )
    $class = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskSessionStateChangeTrigger' -ErrorAction Stop
    $trigger = New-CimInstance -CimClass $class -ClientOnly
    $trigger.StateChange = 7   # TASK_SESSION_LOCK
    $trigger.UserId = $UserId
    $trigger.Enabled = $true
    $trigger
}

function Get-EdgeSyncTaskCommandLine {
    # Module-internal: executable and arguments of the scheduled task action.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ModulePath,

        [string]$PwshPath = (Get-EdgeSyncPwshPath)
    )
    $quotedModule = $ModulePath.Replace("'", "''")
    $command = "Import-Module '$quotedModule'; Sync-EdgeProfiles -Quiet"
    [pscustomobject]@{
        Execute  = Join-Path $env:SystemRoot 'System32\conhost.exe'
        Argument = "--headless `"$PwshPath`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"$command`""
    }
}

function Install-EdgeSyncModuleForUser {
    # Module-internal: copies the module folder to "<UserModuleRoot>\EdgeProfileSync\<version>" and
    # returns the path of the installed manifest.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$ModulePath,

        [Parameter(Mandatory)]
        [string]$UserModuleRoot
    )
    $manifest = Import-PowerShellDataFile -LiteralPath $ModulePath
    $version = [string]$manifest.ModuleVersion
    $sourceDir = Split-Path -Parent $ModulePath
    $targetDir = Join-Path (Join-Path $UserModuleRoot 'EdgeProfileSync') $version
    $targetManifest = Join-Path $targetDir (Split-Path -Leaf $ModulePath)

    if ([System.IO.Path]::GetFullPath($sourceDir).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($targetDir).TrimEnd('\')) {
        return $targetManifest
    }

    if ($PSCmdlet.ShouldProcess($targetDir, "Install EdgeProfileSync $version for the current user")) {
        if (Test-Path -LiteralPath $targetDir) {
            Remove-Item -LiteralPath $targetDir -Recurse -Force -ErrorAction Stop
        }
        $null = New-Item -Path $targetDir -ItemType Directory -Force -ErrorAction Stop
        Get-ChildItem -LiteralPath $sourceDir -Force | Copy-Item -Destination $targetDir -Recurse -Force -ErrorAction Stop
        Write-Verbose "Installed EdgeProfileSync $version to '$targetDir'."
    }
    $targetManifest
}
