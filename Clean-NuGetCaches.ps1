param(
    # Extra package/build cache roots whose contents are deleted (the root folder itself is kept).
    # C:\RamNuget is the restore and test-artifact folder used by local CI workflows.
    [string[]] $ExtraCachePath = @("C:\RamNuget"),
    [switch] $WhatIf
)

$ErrorActionPreference = "Stop"

function Write-Info {
    param([string] $Message)
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Warn {
    param([string] $Message)
    Write-Host $Message -ForegroundColor Yellow
}

function Format-Size {
    param([long] $Bytes)

    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    "{0:N0} KB" -f ($Bytes / 1KB)
}

function Get-FolderSize {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return 0L
    }

    $total = 0L
    $stack = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
    $stack.Push([System.IO.DirectoryInfo]::new($Path))

    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        try {
            foreach ($file in $current.EnumerateFiles()) {
                $total += $file.Length
            }
            foreach ($child in $current.EnumerateDirectories()) {
                if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                    $stack.Push($child)
                }
            }
        }
        catch {
            # Inaccessible folders are left out of the estimate.
        }
    }

    $total
}

function Get-NuGetLocals {
    $output = & dotnet nuget locals all --list 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not list NuGet locals. Is the .NET SDK installed?"
    }

    foreach ($line in $output) {
        if ($line -match "^\s*([\w-]+):\s*(.+?)\s*$") {
            [PSCustomObject] @{ Name = $Matches[1]; Path = $Matches[2] }
        }
    }
}

function Clear-FolderContents {
    param([string] $Path)

    $failed = 0
    foreach ($item in Get-ChildItem -LiteralPath $Path -Force) {
        try {
            if ($item.PSIsContainer) {
                [System.IO.Directory]::Delete($item.FullName, $true)
            }
            else {
                $item.Delete()
            }
        }
        catch {
            # Read-only files make the .NET APIs fail; Remove-Item -Force handles them.
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }

        if (Test-Path -LiteralPath $item.FullName) {
            $failed++
            Write-Warn "  could not fully delete (files in use?): $($item.FullName)"
        }
    }

    $failed
}

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet was not found in PATH."
}

$locals = @(Get-NuGetLocals)
$extraRoots = @($ExtraCachePath | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) })

$grandTotal = 0L
$failedCount = 0

Write-Info "NuGet local caches"
foreach ($local in $locals) {
    $local | Add-Member -NotePropertyName Size -NotePropertyValue (Get-FolderSize -Path $local.Path)
    $grandTotal += $local.Size
    Write-Host ("  {0,10}  {1}: {2}" -f (Format-Size -Bytes $local.Size), $local.Name, $local.Path)
}

if (-not $WhatIf) {
    & dotnet nuget locals all --clear | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) {
        $failedCount++
        Write-Warn "  dotnet nuget locals --clear reported errors (files in use?)."
    }
}

if ($extraRoots.Count -gt 0) {
    Write-Info ""
    Write-Info "Extra cache folders"
}

foreach ($extraRoot in $extraRoots) {
    foreach ($child in Get-ChildItem -LiteralPath $extraRoot -Directory -Force) {
        $size = Get-FolderSize -Path $child.FullName
        $grandTotal += $size
        Write-Host ("  {0,10}  {1}" -f (Format-Size -Bytes $size), $child.FullName)
    }

    if (-not $WhatIf) {
        $failedCount += Clear-FolderContents -Path $extraRoot
    }
}

Write-Info ""
if ($WhatIf) {
    Write-Info "Dry run completed. $(Format-Size -Bytes $grandTotal) would be freed."
    Write-Info "Re-run without -WhatIf to clear them. Packages are downloaded again on the next restore."
}
else {
    Write-Info "Cleanup completed. Up to $(Format-Size -Bytes $grandTotal) freed."
    if ($failedCount -gt 0) {
        Write-Warn "Some items could not be deleted. Close Visual Studio or run 'Stop .NET hosts' and try again."
        exit 1
    }
}
