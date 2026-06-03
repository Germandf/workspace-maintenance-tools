param(
    [string] $Root = (Join-Path $env:USERPROFILE "source\repos"),
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

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    & git -C $Repository @Arguments
}

function Get-GitRepositories {
    param([string] $RootPath)

    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        throw "Root folder does not exist: $RootPath"
    }

    $rootFullPath = (Resolve-Path -LiteralPath $RootPath).Path
    $repositories = [System.Collections.Generic.List[string]]::new()
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($rootFullPath)

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $gitPath = Join-Path $current ".git"

        if (Test-Path -LiteralPath $gitPath -PathType Container) {
            $repositories.Add($current)
            continue
        }

        if (Test-Path -LiteralPath $gitPath -PathType Leaf) {
            Write-Warn "Skipping existing worktree folder: $current"
            continue
        }

        Get-ChildItem -LiteralPath $current -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne ".git" } |
            ForEach-Object { $queue.Enqueue($_.FullName) }
    }

    $repositories
}

function Get-ExistingWorktreeBranches {
    param([string] $Repository)

    $branches = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $worktreeOutput = Invoke-Git -Repository $Repository -Arguments @("worktree", "list", "--porcelain")

    $worktreePath = $null
    foreach ($line in $worktreeOutput) {
        if ($line -like "worktree *") {
            $worktreePath = $line.Substring("worktree ".Length)
            continue
        }

        if ($line -like "branch refs/heads/*") {
            if ($worktreePath -and (Test-Path -LiteralPath $worktreePath -PathType Container)) {
                [void] $branches.Add($line.Substring("branch refs/heads/".Length))
            }
        }
    }

    $branches
}

function Remove-ExtraBranches {
    param([string] $Repository)

    $protectedBranches = [System.Collections.Generic.HashSet[string]]::new(
        [string[]] @("main", "master"),
        [System.StringComparer]::Ordinal
    )
    $checkedOutBranches = Get-ExistingWorktreeBranches -Repository $Repository
    $branches = Invoke-Git -Repository $Repository -Arguments @(
        "for-each-ref",
        "--format=%(refname:short)",
        "refs/heads"
    )

    foreach ($branch in $branches) {
        if ([string]::IsNullOrWhiteSpace($branch)) {
            continue
        }

        if ($protectedBranches.Contains($branch)) {
            Write-Host "  keep branch: $branch"
            continue
        }

        if ($checkedOutBranches.Contains($branch)) {
            Write-Warn "  skip checked-out branch: $branch"
            continue
        }

        if ($WhatIf) {
            Write-Warn "  would delete branch: $branch"
            continue
        }

        Write-Warn "  delete branch: $branch"
        Invoke-Git -Repository $Repository -Arguments @("branch", "-D", "--", $branch) | ForEach-Object {
            Write-Host "    $_"
        }
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git was not found in PATH."
}

$repos = @(Get-GitRepositories -RootPath $Root)

if ($repos.Count -eq 0) {
    Write-Warn "No Git repositories found under: $Root"
    exit 0
}

Write-Info "Found $($repos.Count) Git repositories under: $Root"

foreach ($repo in $repos) {
    Write-Info ""
    Write-Info "Repository: $repo"

    if ($WhatIf) {
        Write-Warn "  would prune stale worktree records"
    }
    else {
        Invoke-Git -Repository $repo -Arguments @("worktree", "prune", "--verbose") | ForEach-Object {
            Write-Host "  $_"
        }
    }

    Remove-ExtraBranches -Repository $repo
}

Write-Info ""
if ($WhatIf) {
    Write-Info "Dry run completed. Re-run without -WhatIf to delete branches and prune stale worktree records."
}
else {
    Write-Info "Cleanup completed."
}
