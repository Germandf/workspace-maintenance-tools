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

function Get-CurrentBranch {
    param([string] $Repository)

    $branch = Invoke-Git -Repository $Repository -Arguments @("branch", "--show-current")
    if ([string]::IsNullOrWhiteSpace($branch)) {
        return $null
    }

    $branch.Trim()
}

function Test-CleanWorkingTree {
    param([string] $Repository)

    $status = Invoke-Git -Repository $Repository -Arguments @("status", "--porcelain")
    $null -eq $status -or $status.Count -eq 0
}

function Test-Remote {
    param(
        [string] $Repository,
        [string] $Remote
    )

    $remotes = Invoke-Git -Repository $Repository -Arguments @("remote")
    $remotes -contains $Remote
}

function Test-RemoteBranch {
    param(
        [string] $Repository,
        [string] $Remote,
        [string] $Branch
    )

    Invoke-Git -Repository $Repository -Arguments @("show-ref", "--verify", "--quiet", "refs/remotes/$Remote/$Branch")
    $LASTEXITCODE -eq 0
}

function Get-PreferredRemote {
    param([string] $Repository)

    if (Test-Remote -Repository $Repository -Remote "upstream") {
        return "upstream"
    }

    if (Test-Remote -Repository $Repository -Remote "origin") {
        return "origin"
    }

    $null
}

function Get-BehindAhead {
    param(
        [string] $Repository,
        [string] $Remote,
        [string] $Branch
    )

    $counts = Invoke-Git -Repository $Repository -Arguments @(
        "rev-list",
        "--left-right",
        "--count",
        "HEAD...$Remote/$Branch"
    )

    $parts = ($counts -join "").Trim() -split "\s+"
    [PSCustomObject] @{
        Ahead = [int] $parts[0]
        Behind = [int] $parts[1]
    }
}

function Update-MainOrMaster {
    param([string] $Repository)

    $branch = Get-CurrentBranch -Repository $Repository
    if ($branch -ne "main" -and $branch -ne "master") {
        Write-Warn "  skip: current branch is not main or master"
        return
    }

    if (-not (Test-CleanWorkingTree -Repository $Repository)) {
        Write-Warn "  skip: working tree is not clean"
        return
    }

    $remote = Get-PreferredRemote -Repository $Repository
    if (-not $remote) {
        Write-Warn "  skip: no upstream or origin remote"
        return
    }

    if ($WhatIf) {
        Write-Warn "  would fetch $remote"
    }
    else {
        Write-Host "  fetch $remote"
        Invoke-Git -Repository $Repository -Arguments @("fetch", $remote, "--prune") | ForEach-Object {
            Write-Host "    $_"
        }
    }

    if (-not (Test-RemoteBranch -Repository $Repository -Remote $remote -Branch $branch)) {
        Write-Warn "  skip: remote branch $remote/$branch does not exist"
        return
    }

    $behindAhead = Get-BehindAhead -Repository $Repository -Remote $remote -Branch $branch

    if ($behindAhead.Behind -eq 0 -and $behindAhead.Ahead -eq 0) {
        Write-Host "  already up to date with $remote/$branch"
        return
    }

    if ($behindAhead.Ahead -gt 0) {
        Write-Warn "  skip: local branch has $($behindAhead.Ahead) commit(s) not in $remote/$branch"
        return
    }

    if ($WhatIf) {
        Write-Warn "  would pull --ff-only $remote $branch ($($behindAhead.Behind) commit(s) behind)"
        return
    }

    Write-Warn "  pull --ff-only $remote $branch ($($behindAhead.Behind) commit(s) behind)"
    Invoke-Git -Repository $Repository -Arguments @("pull", "--ff-only", $remote, $branch) | ForEach-Object {
        Write-Host "    $_"
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
    Update-MainOrMaster -Repository $repo
}

Write-Info ""
if ($WhatIf) {
    Write-Info "Dry run completed. Re-run without -WhatIf to fetch and pull fast-forward updates."
}
else {
    Write-Info "Pull completed."
}
