# Core helpers: console layout (boxed headers/summaries and aligned tables).
#
# Everything goes through Write-Host (information stream 6), never to the success stream, and is silent
# when $script:EdgeQuiet is set. The right edge is left open on purpose: long paths may run past the
# box without breaking the layout.

function Get-EdgeConsoleWidth {
    # Internal: usable width of the console, between 60 and 120 columns.
    $w = 0
    try { $w = [int]$Host.UI.RawUI.WindowSize.Width } catch { $w = 0 }
    if ($w -le 0) { $w = 100 }
    [Math]::Max(60, [Math]::Min(120, $w - 1))
}

function Get-EdgeLevelColor {
    # Internal: console color per output level.
    param([string]$Level)
    switch ($Level) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error' { 'Red' }
        'Header' { 'Cyan' }
        'Step' { 'DarkGray' }
        default { 'Gray' }
    }
}

function Write-EdgeBox {
    <#
    .SYNOPSIS
        Writes a titled box with aligned "Label  value" rows:
            ┌─ Title ─────────────
            │ Label     value
            └─────────────────────
        -Rows is an ordered dictionary; $null or empty values are left out.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [System.Collections.IDictionary]$Rows = [ordered]@{},
        [ValidateSet('Header', 'Success', 'Warning', 'Error', 'Info')][string]$Level = 'Header'
    )
    if ($script:EdgeQuiet) { return }
    $color = Get-EdgeLevelColor $Level
    $width = Get-EdgeConsoleWidth
    $top = "┌─ $Title "
    Write-Host ''
    Write-Host ($top + ('─' * [Math]::Max(3, $width - $top.Length))) -ForegroundColor $color
    $labels = @($Rows.Keys | ForEach-Object { [string]$_ })
    $labelWidth = ($labels | Measure-Object -Property Length -Maximum).Maximum
    foreach ($key in $Rows.Keys) {
        $value = $Rows[$key]
        if ($null -eq $value -or "$value" -eq '') { continue }
        # One Write-Host per row, so the row stays intact when the host output is redirected or logged.
        Write-Host ('│ ' + ([string]$key).PadRight([int]$labelWidth + 2) + [string]$value)
    }
    Write-Host ('└' + ('─' * ($width - 1))) -ForegroundColor $color
}

function New-EdgeTable {
    <#
    .SYNOPSIS
        Defines an aligned console table. -Columns: hashtables with Name, Width and optional Align
        ('Left' default, 'Right'). The last column may have Width 0 (= no padding, free text).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable[]]$Columns,
        [int]$Indent = 2
    )
    [pscustomobject]@{ Columns = $Columns; Indent = $Indent }
}

function Format-EdgeTableCell {
    # Internal: pads or truncates one cell (truncation keeps the start and adds an ellipsis).
    param([string]$Text, [hashtable]$Column)
    $w = [int]$Column['Width']
    if ($w -le 0) { return $Text }
    if ($Text.Length -gt $w) { $Text = $Text.Substring(0, [Math]::Max(1, $w - 1)) + '…' }
    if ($Column['Align'] -eq 'Right') { return $Text.PadLeft($w) }
    $Text.PadRight($w)
}

function Write-EdgeTableHeader {
    # Writes the column headers and a rule below them.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Table)
    if ($script:EdgeQuiet) { return }
    $pad = ' ' * $Table.Indent
    $head = ($Table.Columns | ForEach-Object { Format-EdgeTableCell -Text $_['Name'] -Column $_ }) -join '  '
    $rule = ($Table.Columns | ForEach-Object { '─' * ([int]$_['Width'] -gt 0 ? [int]$_['Width'] : [Math]::Max(4, ([string]$_['Name']).Length)) }) -join '  '
    Write-Host ''
    Write-Host ($pad + $head.TrimEnd()) -ForegroundColor Cyan
    Write-Host ($pad + $rule) -ForegroundColor DarkGray
}

function Write-EdgeTableRow {
    # Writes one row. -Level colours the whole row (Info, Success, Warning, Error, Step).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Table,
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][object[]]$Values,
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Step')][string]$Level = 'Info'
    )
    if ($script:EdgeQuiet) { return }
    $cells = for ($i = 0; $i -lt $Table.Columns.Count; $i++) {
        $v = $i -lt $Values.Count ? [string]$Values[$i] : ''
        Format-EdgeTableCell -Text $v -Column $Table.Columns[$i]
    }
    Write-Host ((' ' * $Table.Indent) + ($cells -join '  ').TrimEnd()) -ForegroundColor (Get-EdgeLevelColor $Level)
}

function Write-EdgeTableRule {
    # Writes a rule under the table (before a totals row).
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Table)
    if ($script:EdgeQuiet) { return }
    $rule = ($Table.Columns | ForEach-Object { '─' * ([int]$_['Width'] -gt 0 ? [int]$_['Width'] : [Math]::Max(4, ([string]$_['Name']).Length)) }) -join '  '
    Write-Host ((' ' * $Table.Indent) + $rule) -ForegroundColor DarkGray
}

function Write-EdgeNote {
    # An indented, untimestamped note line (for details under a table row or between sections).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Step')][string]$Level = 'Step',
        [int]$Indent = 2
    )
    if ($script:EdgeQuiet) { return }
    Write-Host ((' ' * $Indent) + $Message) -ForegroundColor (Get-EdgeLevelColor $Level)
}
