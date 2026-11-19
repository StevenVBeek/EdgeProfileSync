# Data categories: which parts of an Edge profile are backed up / synced.
# Paths are relative to the profile folder (e.g. "User Data\Profile 3").
#
# Never included (by design): Login Data*, Cookies / Network\*, Local State os_crypt key,
# caches, Sessions, Service Worker, IndexedDB, Local Storage. Passwords and auth tokens are
# DPAPI-bound to the source machine and user, so they are useless elsewhere anyway.

$script:EdgeDataCategories = [ordered]@{
    Bookmarks          = @{
        Files       = @('Bookmarks')
        Directories = @()
        Sqlite      = $false
        Default     = $true
        # On restore these are moved aside so Edge rebuilds them from the restored plain 'Bookmarks'.
        # EncryptedBookmarks2 is encrypted with the machine-bound key and would otherwise win.
        MoveAsideOnRestore = @('Bookmarks.bak', 'EncryptedBookmarks2', 'EncryptedBookmarks2.bak', 'BookmarkMergedSurfaceOrdering')
        Description = 'Favorites / bookmarks bar'
    }
    Settings           = @{
        Files       = @('Preferences', 'Custom Dictionary.txt', 'Edge Profile Picture.png', 'Edge Profile.ico')
        Directories = @()
        Sqlite      = $false
        Default     = $true
        MoveAsideOnRestore = @('Preferences.bak')
        Description = 'Profile settings, appearance, site permissions, spell-check dictionary, profile picture'
    }
    SecurePreferences  = @{
        Files       = @('Secure Preferences')
        Directories = @()
        Sqlite      = $false
        Default     = $true
        # Protected by machine-bound MACs: only restored when source machine == target machine.
        SameMachineOnly = $true
        MoveAsideOnRestore = @('Secure Preferences.bak')
        Description = 'Protected settings (start pages, search engine, extension registration) - same machine only'
    }
    Collections        = @{
        Files       = @()
        Directories = @('Collections')
        Sqlite      = $true
        Default     = $true
        MoveAsideOnRestore = @()
        Description = 'Edge Collections'
    }
    History            = @{
        Files       = @('History', 'Top Sites', 'Shortcuts')
        Directories = @()
        Sqlite      = $true
        Default     = $true
        MoveAsideOnRestore = @('History-journal', 'Top Sites-journal', 'Shortcuts-journal')
        Description = 'Browsing history, top sites, address bar shortcuts'
    }
    Favicons           = @{
        Files       = @('Favicons')
        Directories = @()
        Sqlite      = $true
        Default     = $true
        MoveAsideOnRestore = @('Favicons-journal')
        Description = 'Site icons (for bookmarks and history)'
    }
    ExtensionList      = @{
        # Generated file (not copied from the profile): extensions.json with id/name/version/store URL.
        Files       = @()
        Directories = @()
        Generated   = 'extensions.json'
        Sqlite      = $false
        Default     = $true
        MoveAsideOnRestore = @()
        Description = 'Inventory of installed extensions (restore reports what to reinstall)'
    }
    ExtensionData      = @{
        # Per-extension storage (chrome.storage.local / sync, LevelDB). Not machine-bound, so it can be
        # restored on another machine once the same extension id is installed there.
        # Handled per extension id: item key "<Channel>|<ProfileKey>|ExtensionData:<id>", sub-folder
        # "<dir>\<id>" for each directory below. Only applied to extensions installed locally;
        # for missing ones the pull is deferred until the extension is installed.
        Files       = @()
        Directories = @('Local Extension Settings', 'Sync Extension Settings')
        PerExtension = $true
        Sqlite      = $false
        Default     = $true
        MoveAsideOnRestore = @()
        Description = 'Settings and local data of each extension (applied once the extension is installed)'
    }
    Extensions         = @{
        # Extension binaries. Registration lives in Secure Preferences (machine-bound), so this is only
        # useful on the same machine together with SecurePreferences (full same-machine restore).
        Files       = @()
        Directories = @('Extensions')
        Sqlite      = $false
        Default     = $false
        SameMachineOnly = $true
        MoveAsideOnRestore = @()
        Description = 'Extension binaries (large; same-machine restore only, other machines reinstall from the store)'
    }
    Autofill           = @{
        Files       = @('Web Data')
        Directories = @()
        Sqlite      = $true
        Default     = $false
        MoveAsideOnRestore = @('Web Data-journal')
        Description = 'Autofill addresses and form data (stored card numbers are machine-bound and will not decrypt)'
    }
}

function Get-EdgeDataCategory {
    <#
    .SYNOPSIS
        Returns category definitions as objects. -Name filters, -DefaultOnly returns the default set.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Name,
        [switch]$DefaultOnly
    )
    foreach ($key in $script:EdgeDataCategories.Keys) {
        $def = $script:EdgeDataCategories[$key]
        if ($Name -and $key -notin $Name) { continue }
        if ($DefaultOnly -and -not $def.Default) { continue }
        [pscustomobject]@{
            Name               = $key
            Files              = @($def.Files)
            Directories        = @($def.Directories)
            Generated          = $(if ($def.ContainsKey('Generated')) { $def.Generated } else { $null })
            Sqlite             = [bool]$def.Sqlite
            Default            = [bool]$def.Default
            SameMachineOnly    = [bool]($def.ContainsKey('SameMachineOnly') -and $def.SameMachineOnly)
            PerExtension       = [bool]($def.ContainsKey('PerExtension') -and $def.PerExtension)
            MoveAsideOnRestore = @($def.MoveAsideOnRestore)
            Description        = $def.Description
        }
    }
}

function Get-EdgeDataCategoryName {
    [CmdletBinding()]
    param()
    @($script:EdgeDataCategories.Keys)
}
