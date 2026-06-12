param(
    [Alias("Name")]
    [ValidatePattern("^[A-Za-z_][A-Za-z0-9_-]*$")]
    [string] $CommandName = "workspace-maintenance",

    [ValidatePattern("^[A-Za-z_][A-Za-z0-9_-]*$")]
    [string] $ShortCommandName,

    [switch] $NoShortCommand
)

$ErrorActionPreference = "Stop"

$scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Path $scriptPath -Parent
$launcherPath = Join-Path $repoRoot "Invoke-WorkspaceMaintenance.ps1"

if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
    throw "Could not find Invoke-WorkspaceMaintenance.ps1 next to this installer."
}

$useDefaultShortCommand = -not $PSBoundParameters.ContainsKey("CommandName") -and
    -not $PSBoundParameters.ContainsKey("Name") -and
    -not $PSBoundParameters.ContainsKey("ShortCommandName") -and
    -not $NoShortCommand

if ($useDefaultShortCommand) {
    $ShortCommandName = "wm"
}

if ($NoShortCommand) {
    $ShortCommandName = $null
}

function ConvertTo-PowerShellSingleQuotedLiteral {
    param([string] $Value)

    "'" + ($Value -replace "'", "''") + "'"
}

function Install-ProfileShortcuts {
    param(
        [string] $ProfilePath,
        [string] $LauncherPath,
        [string] $CommandName,
        [string] $ShortCommandName
    )

    $profileFolder = Split-Path -Path $ProfilePath -Parent
    if (-not (Test-Path -LiteralPath $profileFolder -PathType Container)) {
        New-Item -Path $profileFolder -ItemType Directory -Force | Out-Null
    }

    $beginMarker = "# BEGIN WorkspaceMaintenanceTools shortcuts"
    $endMarker = "# END WorkspaceMaintenanceTools shortcuts"
    $quotedLauncherPath = ConvertTo-PowerShellSingleQuotedLiteral -Value $LauncherPath

    $shortcutLines = @(
        $beginMarker
        "function $CommandName {"
        "    & $quotedLauncherPath @args"
        "}"
    )

    if (-not [string]::IsNullOrWhiteSpace($ShortCommandName)) {
        $shortcutLines += @(
            ""
            "function $ShortCommandName {"
            "    & $quotedLauncherPath @args"
            "}"
        )
    }

    $shortcutLines += $endMarker
    $shortcutBlock = $shortcutLines -join [Environment]::NewLine

    $content = ""
    if (Test-Path -LiteralPath $ProfilePath -PathType Leaf) {
        $content = Get-Content -LiteralPath $ProfilePath -Raw
    }

    $escapedBegin = [regex]::Escape($beginMarker)
    $escapedEnd = [regex]::Escape($endMarker)
    $content = [regex]::Replace($content, "(?ms)^$escapedBegin\r?\n.*?^$escapedEnd\r?\n?", "")

    # Remove the older one-off wrapper if it matches the previous local setup exactly.
    $legacyLauncherPath = [regex]::Escape($LauncherPath)
    $content = [regex]::Replace($content, "(?ms)^function wmt \{\r?\n\s*& [`"']$legacyLauncherPath[`"'] @args\r?\n\}\r?\n?", "")
    $content = $content.TrimEnd()

    if ($content.Length -gt 0) {
        $content = $content + [Environment]::NewLine + [Environment]::NewLine
    }

    Set-Content -LiteralPath $ProfilePath -Value ($content + $shortcutBlock + [Environment]::NewLine) -Encoding ASCII
    Write-Host "Installed shortcuts in: $ProfilePath" -ForegroundColor Cyan
}

$documentsPath = [Environment]::GetFolderPath("MyDocuments")
$profilePaths = @(
    Join-Path $documentsPath "PowerShell\profile.ps1"
    Join-Path $documentsPath "WindowsPowerShell\profile.ps1"
)

foreach ($profilePath in $profilePaths) {
    Install-ProfileShortcuts `
        -ProfilePath $profilePath `
        -LauncherPath $launcherPath `
        -CommandName $CommandName `
        -ShortCommandName $ShortCommandName
}

Write-Host ""
if (-not [string]::IsNullOrWhiteSpace($ShortCommandName)) {
    Write-Host "Open a new terminal, then run '$CommandName' or '$ShortCommandName'." -ForegroundColor Green
}
else {
    Write-Host "Open a new terminal, then run '$CommandName'." -ForegroundColor Green
}
Write-Host "In the current terminal, reload the profile with: . `$PROFILE" -ForegroundColor DarkGray
