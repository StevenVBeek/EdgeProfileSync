# Internal helpers for Unregister-EdgeProfileSyncTask (not exported).

function Remove-EdgeSyncTaskFolderIfEmpty {
    # Module-internal: removes the "\EdgeProfileSync\" Task Scheduler folder when it holds no tasks
    # and no subfolders. Best effort: failures are only logged verbosely.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$FolderPath = '\EdgeProfileSync'
    )
    try {
        $service = New-Object -ComObject 'Schedule.Service'
        $service.Connect()
        $folder = $service.GetFolder($FolderPath)
        if ($folder.GetTasks(1).Count -eq 0 -and $folder.GetFolders(0).Count -eq 0) {
            if ($PSCmdlet.ShouldProcess($FolderPath, 'Remove empty Task Scheduler folder')) {
                $service.GetFolder('\').DeleteFolder($FolderPath.TrimStart('\'), 0)
            }
        }
    }
    catch {
        Write-Verbose "Task Scheduler folder '$FolderPath' not removed: $($_.Exception.Message)"
    }
}
