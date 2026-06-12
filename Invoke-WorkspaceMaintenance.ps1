param(
    [string] $ScriptsFolder = $PSScriptRoot,
    [string] $ConfigPath = (Join-Path $env:APPDATA "WorkspaceMaintenanceTools\config.json")
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ScriptsFolder)) {
    $ScriptsFolder = [Environment]::GetFolderPath("Desktop")
}

function Write-Info {
    param([string] $Message)
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Warn {
    param([string] $Message)
    Write-Host $Message -ForegroundColor Yellow
}

function Get-ScriptDescription {
    param([string] $Name)

    switch ($Name) {
        "Checkout-MainOrMaster-Repos.ps1" { "Checkout main/master" }
        "Clean-GitBranchesAndStaleWorktrees.ps1" { "Clean branches" }
        "Install-WorkspaceMaintenanceShortcuts.ps1" { "Install shortcuts" }
        "Pull-MainOrMaster-Repos.ps1" { "Pull updates" }
        "Kill-DotNetHost.ps1" { "Stop .NET hosts" }
        default { "Run script" }
    }
}

function Test-ShortcutCommandName {
    param([string] $CommandName)

    $CommandName -match "^[A-Za-z_][A-Za-z0-9_-]*$"
}

function Test-SupportsWhatIf {
    param([string] $Path)

    $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $content -match '(?is)\[switch\]\s*\$WhatIf\b'
}

function Test-SupportsRoot {
    param([string] $Path)

    $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $content -match '(?is)\[string\]\s*\$Root\b'
}

function Get-DefaultWorkspaceRoot {
    Join-Path $env:USERPROFILE "source\repos"
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return $null
    }

    try {
        Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Warn "Could not read config. A new config will be created."
        $null
    }
}

function Save-Config {
    param([string] $WorkspaceRoot)

    $configFolder = Split-Path -Path $ConfigPath -Parent
    if (-not (Test-Path -LiteralPath $configFolder -PathType Container)) {
        New-Item -Path $configFolder -ItemType Directory -Force | Out-Null
    }

    [PSCustomObject] @{
        WorkspaceRoot = $WorkspaceRoot
    } | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding ASCII
}

function Read-EditableInput {
    param(
        [string] $Prompt,
        [string] $DefaultValue = ""
    )

    Write-Host $Prompt
    $buffer = [System.Collections.Generic.List[char]]::new()
    foreach ($char in $DefaultValue.ToCharArray()) {
        $buffer.Add($char)
    }

    $cursor = $buffer.Count
    $startLeft = [Console]::CursorLeft
    $startTop = [Console]::CursorTop

    function Render-Line {
        [Console]::SetCursorPosition($startLeft, $startTop)
        $text = -join $buffer
        Write-Host ($text + " ") -NoNewline
        [Console]::SetCursorPosition($startLeft + $cursor, $startTop)
    }

    Render-Line

    while ($true) {
        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            "Enter" {
                Write-Host ""
                return (-join $buffer).Trim()
            }
            "Escape" {
                Write-Host ""
                return $null
            }
            "LeftArrow" {
                if ($cursor -gt 0) {
                    $cursor--
                    Render-Line
                }
            }
            "RightArrow" {
                if ($cursor -lt $buffer.Count) {
                    $cursor++
                    Render-Line
                }
            }
            "Home" {
                $cursor = 0
                Render-Line
            }
            "End" {
                $cursor = $buffer.Count
                Render-Line
            }
            "Backspace" {
                if ($cursor -gt 0) {
                    $buffer.RemoveAt($cursor - 1)
                    $cursor--
                    Render-Line
                }
            }
            "Delete" {
                if ($cursor -lt $buffer.Count) {
                    $buffer.RemoveAt($cursor)
                    Render-Line
                }
            }
            default {
                if (-not [char]::IsControl($key.KeyChar)) {
                    $buffer.Insert($cursor, $key.KeyChar)
                    $cursor++
                    Render-Line
                }
            }
        }
    }
}

function Select-WorkspaceRoot {
    param(
        [string] $CurrentValue,
        [bool] $InitialSetup
    )

    $defaultRoot = Get-DefaultWorkspaceRoot
    $candidate = if ($CurrentValue) { $CurrentValue } else { $defaultRoot }

    if ($InitialSetup -and (Test-Path -LiteralPath $defaultRoot -PathType Container)) {
        $items = @(
            [PSCustomObject] @{
                Label = "Use detected workspace: $defaultRoot"
                Value = $true
            }
            [PSCustomObject] @{
                Label = "Edit workspace path"
                Value = $false
            }
        )

        $selected = Invoke-ArrowMenu -Title "Workspace setup" -Items $items
        if (-not $selected) {
            return $null
        }

        if ($selected.Value) {
            Save-Config -WorkspaceRoot $defaultRoot
            return $defaultRoot
        }
    }

    while ($true) {
        Clear-Host
        Write-Info "Workspace path"
        Write-Host ""
        $typed = Read-EditableInput -Prompt "Enter workspace root. Press Esc to cancel." -DefaultValue $candidate

        if (-not $typed) {
            return $null
        }

        if (Test-Path -LiteralPath $typed -PathType Container) {
            $resolved = (Resolve-Path -LiteralPath $typed).Path
            Save-Config -WorkspaceRoot $resolved
            return $resolved
        }

        Write-Warn "Folder does not exist: $typed"
        Write-Host "Press any key to edit again..." -ForegroundColor DarkGray
        [void] [Console]::ReadKey($true)
        $candidate = $typed
    }
}

function Get-WorkspaceRoot {
    $config = Read-Config

    if ($config -and $config.WorkspaceRoot -and (Test-Path -LiteralPath $config.WorkspaceRoot -PathType Container)) {
        return $config.WorkspaceRoot
    }

    if ($config -and $config.WorkspaceRoot) {
        Write-Warn "Saved workspace no longer exists: $($config.WorkspaceRoot)"
        Write-Host "Press any key to choose a new workspace..." -ForegroundColor DarkGray
        [void] [Console]::ReadKey($true)
        return Select-WorkspaceRoot -CurrentValue $config.WorkspaceRoot -InitialSetup $false
    }

    Select-WorkspaceRoot -CurrentValue (Get-DefaultWorkspaceRoot) -InitialSetup $true
}

function Get-DesktopScripts {
    param([string] $ScriptsPath)

    $thisScriptPath = $PSCommandPath

    Get-ChildItem -LiteralPath $ScriptsPath -Filter "*.ps1" -File |
        Where-Object { $_.FullName -ne $thisScriptPath } |
        Sort-Object Name |
        ForEach-Object {
            [PSCustomObject] @{
                Name = $_.Name
                FullName = $_.FullName
                Description = Get-ScriptDescription -Name $_.Name
                SupportsWhatIf = Test-SupportsWhatIf -Path $_.FullName
                SupportsRoot = Test-SupportsRoot -Path $_.FullName
            }
        }
}

function Write-MenuItem {
    param(
        [object] $Item,
        [bool] $Selected
    )

    $marker = if ($Selected) { "> " } else { "  " }
    $markerColor = if ($Selected) { "Green" } else { "DarkGray" }
    Write-Host $marker -NoNewline -ForegroundColor $markerColor

    if ($Item.Parts) {
        foreach ($part in $Item.Parts) {
            Write-Host $part.Text -NoNewline -ForegroundColor $part.Color
        }
        Write-Host ""
        return
    }

    $color = if ($Selected) { "White" } else { "Gray" }
    Write-Host $Item.Label -ForegroundColor $color
}

function Clear-ConsoleLine {
    $width = [Math]::Max(1, [Console]::BufferWidth - 1)
    Write-Host (" " * $width) -NoNewline
}

function Invoke-ArrowMenu {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Title,

        [Parameter(Mandatory = $true)]
        [object[]] $Items,

        [string] $Footer = "Use Up/Down arrows and Enter. Press Q or Esc to exit."
    )

    if ($Items.Count -eq 0) {
        return $null
    }

    $selectedIndex = 0
    Clear-Host
    $menuTop = [Console]::CursorTop

    function Render-Menu {
        [Console]::SetCursorPosition(0, $menuTop)
        Clear-ConsoleLine
        [Console]::SetCursorPosition(0, $menuTop)
        Write-Info $Title

        [Console]::SetCursorPosition(0, $menuTop + 1)
        Clear-ConsoleLine
        Write-Host ""

        for ($i = 0; $i -lt $Items.Count; $i++) {
            [Console]::SetCursorPosition(0, $menuTop + 2 + $i)
            Clear-ConsoleLine
            [Console]::SetCursorPosition(0, $menuTop + 2 + $i)
            $item = $Items[$i]
            Write-MenuItem -Item $item -Selected ($i -eq $selectedIndex)
        }

        $footerTop = $menuTop + 2 + $Items.Count
        [Console]::SetCursorPosition(0, $footerTop)
        Clear-ConsoleLine
        Write-Host ""
        [Console]::SetCursorPosition(0, $footerTop + 1)
        Clear-ConsoleLine
        [Console]::SetCursorPosition(0, $footerTop + 1)
        Write-Host $Footer -ForegroundColor DarkGray
    }

    $previousCursorVisible = [Console]::CursorVisible
    [Console]::CursorVisible = $false

    try {
        Render-Menu

        while ($true) {
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                "UpArrow" {
                    if ($selectedIndex -gt 0) {
                        $selectedIndex--
                    }
                    else {
                        $selectedIndex = $Items.Count - 1
                    }
                    Render-Menu
                }
                "DownArrow" {
                    if ($selectedIndex -lt ($Items.Count - 1)) {
                        $selectedIndex++
                    }
                    else {
                        $selectedIndex = 0
                    }
                    Render-Menu
                }
                "Enter" {
                    [Console]::SetCursorPosition(0, $menuTop + 3 + $Items.Count)
                    return $Items[$selectedIndex]
                }
                "Escape" {
                    [Console]::SetCursorPosition(0, $menuTop + 3 + $Items.Count)
                    return $null
                }
                "Q" {
                    [Console]::SetCursorPosition(0, $menuTop + 3 + $Items.Count)
                    return $null
                }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $previousCursorVisible
    }
}

function Select-Script {
    param(
        [object[]] $Scripts,
        [string] $WorkspaceRoot
    )

    $items = @(
        foreach ($script in $Scripts) {
            if ($script.Name -eq "Install-WorkspaceMaintenanceShortcuts.ps1") {
                [PSCustomObject] @{
                    Label = "Install shortcuts | Setup"
                    Parts = @(
                        [PSCustomObject] @{ Text = "Install shortcuts"; Color = "White" }
                        [PSCustomObject] @{ Text = " | "; Color = "DarkGray" }
                        [PSCustomObject] @{ Text = "Setup"; Color = "Magenta" }
                    )
                    Value = [PSCustomObject] @{ Type = "InstallShortcuts"; Script = $script }
                }
                continue
            }

            $whatIfText = if ($script.SupportsWhatIf) { "Dry-run available" } else { "No dry-run" }
            $whatIfColor = if ($script.SupportsWhatIf) { "Yellow" } else { "DarkGray" }
            [PSCustomObject] @{
                Label = "{0} | {1}" -f $script.Description, $whatIfText
                Parts = @(
                    [PSCustomObject] @{ Text = $script.Description; Color = "White" }
                    [PSCustomObject] @{ Text = " | "; Color = "DarkGray" }
                    [PSCustomObject] @{ Text = $whatIfText; Color = $whatIfColor }
                )
                Value = [PSCustomObject] @{ Type = "Script"; Script = $script }
            }
        }
        [PSCustomObject] @{
            Label = "Edit workspace | Config"
            Parts = @(
                [PSCustomObject] @{ Text = "Edit workspace"; Color = "White" }
                [PSCustomObject] @{ Text = " | "; Color = "DarkGray" }
                [PSCustomObject] @{ Text = "Config"; Color = "Magenta" }
            )
            Value = [PSCustomObject] @{ Type = "EditWorkspace" }
        }
    )

    $selected = Invoke-ArrowMenu -Title "Workspace: $WorkspaceRoot" -Items $items
    if (-not $selected) {
        return $null
    }

    $selected.Value
}

function Select-ShortcutInstallMode {
    $items = @(
        [PSCustomObject] @{
            Label = "Use default commands | workspace-maintenance + wm"
            Parts = @(
                [PSCustomObject] @{ Text = "Use default commands"; Color = "White" }
                [PSCustomObject] @{ Text = " | "; Color = "DarkGray" }
                [PSCustomObject] @{ Text = "workspace-maintenance + wm"; Color = "Green" }
            )
            Value = [PSCustomObject] @{ Type = "Default" }
        }
        [PSCustomObject] @{
            Label = "Override command name | Custom"
            Parts = @(
                [PSCustomObject] @{ Text = "Override command name"; Color = "White" }
                [PSCustomObject] @{ Text = " | "; Color = "DarkGray" }
                [PSCustomObject] @{ Text = "Custom"; Color = "Yellow" }
            )
            Value = [PSCustomObject] @{ Type = "Custom" }
        }
    )

    $selected = Invoke-ArrowMenu -Title "Install shortcuts" -Items $items
    if (-not $selected) {
        return $null
    }

    $selected.Value
}

function Read-ShortcutCommandName {
    while ($true) {
        Clear-Host
        Write-Info "Custom shortcut"
        Write-Host ""
        $commandName = Read-EditableInput -Prompt "Enter the command name. Press Esc to cancel." -DefaultValue ""

        if (-not $commandName) {
            return $null
        }

        if (Test-ShortcutCommandName -CommandName $commandName) {
            return $commandName
        }

        Write-Warn "Invalid command name: $commandName"
        Write-Host "Use letters, numbers, hyphens, or underscores. Start with a letter or underscore." -ForegroundColor DarkGray
        Write-Host "Press any key to try again..." -ForegroundColor DarkGray
        [void] [Console]::ReadKey($true)
    }
}

function Select-ExecutionMode {
    param([bool] $SupportsWhatIf)

    if (-not $SupportsWhatIf) {
        Write-Warn "This script does not support -WhatIf. It will run in real mode."
        return "Run"
    }

    $items = @(
        [PSCustomObject] @{
            Label = "WhatIf / dry run"
            Value = "WhatIf"
        }
        [PSCustomObject] @{
            Label = "Run for real"
            Value = "Run"
        }
    )

    $selected = Invoke-ArrowMenu -Title "Select execution mode" -Items $items
    if (-not $selected) {
        return $null
    }

    $selected.Value
}

function Invoke-SelectedScript {
    param(
        [object] $Script,
        [string] $Mode,
        [string] $WorkspaceRoot
    )

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $Script.FullName
    )

    if ($Script.SupportsRoot) {
        $arguments += @("-Root", $WorkspaceRoot)
    }

    if ($Mode -eq "WhatIf" -and $Script.SupportsWhatIf) {
        $arguments += "-WhatIf"
    }

    Write-Info ""
    Write-Info "Running: $($Script.Name)"
    Write-Info "Mode: $Mode"
    if ($Script.SupportsRoot) {
        Write-Info "Workspace: $WorkspaceRoot"
    }
    Write-Info ""

    & powershell @arguments
    $exitCode = $LASTEXITCODE

    Write-Info ""
    if ($exitCode -eq 0) {
        Write-Info "Finished successfully."
    }
    else {
        Write-Warn "Script finished with exit code $exitCode."
    }

    Write-Host ""
    Write-Host "Press any key to continue..." -ForegroundColor DarkGray
    [void] [Console]::ReadKey($true)
}

function Invoke-ShortcutInstaller {
    param([object] $Script)

    $installMode = Select-ShortcutInstallMode
    if (-not $installMode) {
        Write-Info "Exiting."
        exit 0
    }

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $Script.FullName
    )

    if ($installMode.Type -eq "Custom") {
        $commandName = Read-ShortcutCommandName
        if (-not $commandName) {
            Write-Info "Exiting."
            exit 0
        }

        $arguments += @("-Name", $commandName)
    }

    Write-Info ""
    Write-Info "Running: $($Script.Name)"
    if ($installMode.Type -eq "Custom") {
        Write-Info "Command name: $commandName"
    }
    else {
        Write-Info "Command names: workspace-maintenance, wm"
    }
    Write-Info ""

    & powershell @arguments
    $exitCode = $LASTEXITCODE

    Write-Info ""
    if ($exitCode -eq 0) {
        Write-Info "Finished successfully."
    }
    else {
        Write-Warn "Script finished with exit code $exitCode."
    }

    Write-Host ""
    Write-Host "Press any key to continue..." -ForegroundColor DarkGray
    [void] [Console]::ReadKey($true)
}

if (-not (Test-Path -LiteralPath $ScriptsFolder -PathType Container)) {
    throw "Scripts folder does not exist: $ScriptsFolder"
}

$scripts = @(Get-DesktopScripts -ScriptsPath $ScriptsFolder)

if ($scripts.Count -eq 0) {
    Write-Warn "No .ps1 scripts found on desktop."
    exit 0
}

$workspaceRoot = Get-WorkspaceRoot
if (-not $workspaceRoot) {
    Write-Info "Exiting."
    exit 0
}

while ($true) {
    $selection = Select-Script -Scripts $scripts -WorkspaceRoot $workspaceRoot

    if (-not $selection) {
        Write-Info "Exiting."
        exit 0
    }

    if ($selection.Type -eq "EditWorkspace") {
        $newWorkspaceRoot = Select-WorkspaceRoot -CurrentValue $workspaceRoot -InitialSetup $false
        if ($newWorkspaceRoot) {
            $workspaceRoot = $newWorkspaceRoot
        }
        continue
    }

    if ($selection.Type -eq "InstallShortcuts") {
        Invoke-ShortcutInstaller -Script $selection.Script
    }
    else {
        $selectedScript = $selection.Script
        $mode = Select-ExecutionMode -SupportsWhatIf $selectedScript.SupportsWhatIf
        if (-not $mode) {
            Write-Info "Exiting."
            exit 0
        }

        Invoke-SelectedScript -Script $selectedScript -Mode $mode -WorkspaceRoot $workspaceRoot
    }

    Write-Info ""
    $againItems = @(
        [PSCustomObject] @{
            Label = "Exit"
            Value = $false
        }
        [PSCustomObject] @{
            Label = "Run another action"
            Value = $true
        }
    )
    $again = Invoke-ArrowMenu -Title "Next step" -Items $againItems
    if (-not $again -or -not $again.Value) {
        Write-Info "Exiting."
        exit 0
    }

    $scripts = @(Get-DesktopScripts -ScriptsPath $ScriptsFolder)
}
