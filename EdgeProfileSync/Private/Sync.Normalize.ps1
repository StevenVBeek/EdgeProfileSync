# Change detection for Edge 'Preferences'.
#
# Edge rewrites Preferences constantly with telemetry-like state (site/media engagement scores, tracker
# counters, window position, language statistics, session logs, update-client data). Comparing the raw file
# would make every machine look "changed" after every browsing session, so the Settings category would
# ping-pong between machines and the newest browsing session would overwrite real setting changes.
# The fingerprint below ignores that noise. It is only used to decide WHETHER something changed: the full,
# unmodified file is still what gets copied.

# Whole subtrees that never carry user choices (dotted paths from the root).
$script:EdgeVolatilePreferencePaths = @(
    'browser.window_placement'
    'browser.app_window_placement'
    'browser.hub_cleanup_candidate_list_for_debug'
    'sessions'
    'updateclientdata'
    'segmentation_platform'
    'optimization_guide'
    'safebrowsing'
    'in_product_help'
    'language_dwell_time_average'
    'language_model_counters'
    'language_usage_count'
    'https_upgrade_navigations'
    'edge_pinning_campaign'
    'omnibox.daily_suggestion_acceptance'
    'ntp.record_user_choices'
    'ntp.user_nurturing'
    'profile.exit_type'
    'profile.exited_cleanly'
    'profile.last_engagement_time'
    'profile.observed_session_time'
    'sync.transport_data_per_account'
    'domain_diversity'
    'uninstall_metrics'
    'user_experience_metrics'
    'media.engagement'
)

# Content-setting types under profile.content_settings.exceptions that are scores/telemetry, not permissions.
$script:EdgeVolatileContentSettingTypes = @(
    'site_engagement', 'media_engagement', 'trackers_data', 'client_hints', 'app_banner',
    'important_site_info', 'formfill_metadata', 'cookie_controls_metadata', 'top_level_storage_access',
    'storage_access', 'https_enforced', 'http_allowed', 'password_protection', 'safe_browsing_url_check_data',
    'permission_autoblocking_data', 'notification_interactions', 'intent_picker_auto_display',
    'third_party_storage_partitioning', 'tracking_org_relationships', 'tracking_org_exceptions'
)

# Per-entry bookkeeping fields inside a content-setting exception.
$script:EdgeVolatileContentSettingFields = @('last_modified', 'last_visit', 'expiration', 'lifetime', 'model')

# Any key with this shape is a timestamp or counter.
$script:EdgeVolatileKeyPattern = '(?i)(_time|_time_v\d+|Time|_timestamp|_count|_counts|_date)$|^last_'

function Remove-EdgeVolatilePreference {
    # Internal: returns a copy of $Node without volatile keys. $Path is the dotted path of $Node.
    param($Node, [string]$Path)

    if ($Node -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        $keys = @($Node.Keys) | Sort-Object -Culture ([cultureinfo]::InvariantCulture)
        foreach ($key in $keys) {
            $k = [string]$key
            $childPath = $Path ? "$Path.$k" : $k
            if ($childPath -in $script:EdgeVolatilePreferencePaths) { continue }
            if ($k -match $script:EdgeVolatileKeyPattern) { continue }
            if ($Path -eq 'profile.content_settings.exceptions' -and $k -in $script:EdgeVolatileContentSettingTypes) { continue }
            # Inside profile.content_settings.exceptions.<type>.<site>: drop bookkeeping fields.
            if ($Path -match '^profile\.content_settings\.exceptions\.[^.]+\.' -and $k -in $script:EdgeVolatileContentSettingFields) { continue }
            # Site keys contain dots; collapse them so the path pattern above keeps working.
            $nextPath = if ($Path -match '^profile\.content_settings\.exceptions\.[^.]+$') { "$Path.<site>" } else { $childPath }
            $out[$k] = Remove-EdgeVolatilePreference -Node $Node[$key] -Path $nextPath
        }
        return $out
    }
    if ($Node -is [System.Collections.IList] -and $Node -isnot [string]) {
        return , @(foreach ($item in $Node) { Remove-EdgeVolatilePreference -Node $item -Path $Path })
    }
    $Node
}

function Get-EdgePreferencesFingerprint {
    <#
    .SYNOPSIS
        SHA256 (lowercase hex) of an Edge Preferences file with volatile state removed. $null when missing.
        Falls back to the raw file fingerprint when the file is not valid JSON.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $json = Read-EdgeJsonFile -Path $Path
    }
    catch {
        return Get-EdgeItemFingerprint -Path $Path
    }
    $clean = Remove-EdgeVolatilePreference -Node $json -Path ''
    $text = ConvertTo-Json -InputObject $clean -Depth 100 -Compress
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
}
