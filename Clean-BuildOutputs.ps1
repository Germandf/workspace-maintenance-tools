param(
    [string] $Root = (Join-Path $env:USERPROFILE "source\repos"),
    [switch] $WhatIf
)

$ErrorActionPreference = "Stop"

$outputFolderNames = @("bin", "obj")
$skippedFolderNames = @(".git", ".vs", "node_modules")
$projectFilePatterns = @("*.csproj", "*.fsproj", "*.vbproj", "*.sqlproj", "*.esproj", "*.proj", "*.shproj")

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

function Test-ReparsePoint {
    param([System.IO.FileSystemInfo] $Item)

    ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
}

function Get-FolderSize {
    param([string] $Path)

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
                if (-not (Test-ReparsePoint -Item $child)) {
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

function Test-ProjectFolder {
    param([System.IO.DirectoryInfo] $Folder)

    foreach ($pattern in $projectFilePatterns) {
        foreach ($file in $Folder.EnumerateFiles($pattern)) {
            return $true
        }
    }

    $false
}

function Get-TrackedOutputFolders {
    param([string] $Repository)

    # Collects bin/obj folders that contain files tracked by Git, so they are never deleted.
    $tracked = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $pathspecs = foreach ($name in $outputFolderNames) { ":(glob)**/$name/**" }

    # Windows PowerShell turns native stderr into terminating errors under "Stop" (e.g. broken worktrees).
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $files = & git -C $Repository -c core.quotepath=off ls-files -- @pathspecs 2>$null
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($LASTEXITCODE -ne 0) {
        return , $tracked
    }

    foreach ($file in $files) {
        $segments = $file -split "/"
        for ($i = 0; $i -lt $segments.Count - 1; $i++) {
            if ($outputFolderNames -contains $segments[$i]) {
                $relative = ($segments[0..$i] -join "\")
                [void] $tracked.Add((Join-Path $Repository $relative))
            }
        }
    }

    # The leading comma keeps PowerShell from unrolling the set into its items.
    , $tracked
}

function Get-GitIgnoredFolders {
    param(
        [string] $Repository,
        [string[]] $Folders
    )

    $ignored = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $prefixLength = $Repository.TrimEnd("\").Length + 1
    $relativePaths = foreach ($folder in $Folders) { $folder.Substring($prefixLength).Replace("\", "/") }

    # NUL-separated input avoids the CRLF that Windows PowerShell appends to piped lines,
    # and UTF-8 without BOM keeps the first path intact.
    $stdin = ($relativePaths -join "`0") + "`0"
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = $stdin | & git -C $Repository -c core.quotepath=off check-ignore --stdin -z 2>$null
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    foreach ($path in (($output -join "") -split "`0")) {
        $path = $path.Trim()
        if ($path) {
            [void] $ignored.Add((Join-Path $Repository $path.Replace("/", "\")))
        }
    }

    , $ignored
}

function Find-BuildOutputFolders {
    param([string] $RootPath)

    $emptySet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $results = [System.Collections.Generic.List[object]]::new()
    # bin/obj folders without a project next to them (stale or tool outputs), checked against .gitignore later.
    $unownedByRepository = @{}
    $hasGit = [bool] (Get-Command git -ErrorAction SilentlyContinue)
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push([PSCustomObject] @{ Path = $RootPath; Repository = $null; Tracked = $emptySet })

    while ($stack.Count -gt 0) {
        $entry = $stack.Pop()
        $folder = [System.IO.DirectoryInfo]::new($entry.Path)
        $repository = $entry.Repository
        $tracked = $entry.Tracked

        # A .git folder marks a repository; a .git file marks a linked worktree.
        $gitPath = Join-Path $folder.FullName ".git"
        if ($hasGit -and (Test-Path -LiteralPath $gitPath)) {
            $repository = $folder.FullName
            $tracked = Get-TrackedOutputFolders -Repository $repository
        }

        try {
            $children = @($folder.EnumerateDirectories())
        }
        catch {
            Write-Warn "  skip unreadable folder: $($folder.FullName)"
            continue
        }

        $isProjectFolder = $null
        foreach ($child in $children) {
            if (Test-ReparsePoint -Item $child) {
                continue
            }

            if ($skippedFolderNames -contains $child.Name) {
                continue
            }

            if ($outputFolderNames -contains $child.Name) {
                if ($tracked.Contains($child.FullName)) {
                    Write-Warn "  skip folder with Git-tracked files: $($child.FullName)"
                    continue
                }

                if ($null -eq $isProjectFolder) {
                    $isProjectFolder = Test-ProjectFolder -Folder $folder
                }

                if ($isProjectFolder) {
                    $group = if ($repository) { $repository } else { $RootPath }
                    $results.Add([PSCustomObject] @{ Path = $child.FullName; Repository = $group })
                    continue
                }

                if ($repository) {
                    if (-not $unownedByRepository.ContainsKey($repository)) {
                        $unownedByRepository[$repository] = [System.Collections.Generic.List[string]]::new()
                    }
                    $unownedByRepository[$repository].Add($child.FullName)
                    continue
                }
            }

            $stack.Push([PSCustomObject] @{ Path = $child.FullName; Repository = $repository; Tracked = $tracked })
        }
    }

    foreach ($repository in $unownedByRepository.Keys) {
        $ignored = Get-GitIgnoredFolders -Repository $repository -Folders $unownedByRepository[$repository]
        foreach ($path in $unownedByRepository[$repository]) {
            if ($ignored.Contains($path)) {
                $results.Add([PSCustomObject] @{ Path = $path; Repository = $repository })
            }
        }
    }

    $results
}

function Remove-Folder {
    param([string] $Path)

    try {
        [System.IO.Directory]::Delete($Path, $true)
    }
    catch {
        # Read-only files make Directory.Delete fail; Remove-Item -Force handles them.
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }

    -not (Test-Path -LiteralPath $Path)
}

if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "Root folder does not exist: $Root"
}

$rootFullPath = (Resolve-Path -LiteralPath $Root).Path
Write-Info "Scanning for .NET bin/obj folders under: $rootFullPath"

$folders = @(Find-BuildOutputFolders -RootPath $rootFullPath)
if ($folders.Count -eq 0) {
    Write-Info "No build output folders found."
    exit 0
}

$grandTotal = 0L
$failedCount = 0

foreach ($group in ($folders | Group-Object Repository | Sort-Object Name)) {
    $repositoryTotal = 0L
    $removedCount = 0

    foreach ($item in $group.Group) {
        $size = Get-FolderSize -Path $item.Path
        if ($WhatIf) {
            $repositoryTotal += $size
            $removedCount++
            continue
        }

        if (Remove-Folder -Path $item.Path) {
            $repositoryTotal += $size
            $removedCount++
        }
        else {
            $failedCount++
            Write-Warn "  could not fully delete (files in use?): $($item.Path)"
        }
    }

    $grandTotal += $repositoryTotal
    $verb = if ($WhatIf) { "would delete" } else { "deleted" }
    Write-Host ("  {0,10}  {1} {2} folder(s) in {3}" -f (Format-Size -Bytes $repositoryTotal), $verb, $removedCount, $group.Name)
}

Write-Info ""
if ($WhatIf) {
    Write-Info "Dry run completed. $($folders.Count) folder(s), $(Format-Size -Bytes $grandTotal) would be freed."
    Write-Info "Re-run without -WhatIf to delete them."
}
else {
    Write-Info "Cleanup completed. $(Format-Size -Bytes $grandTotal) freed."
    if ($failedCount -gt 0) {
        Write-Warn "$failedCount folder(s) could not be fully deleted. Close Visual Studio or run 'Stop .NET hosts' and try again."
        exit 1
    }
}
