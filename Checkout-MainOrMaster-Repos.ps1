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

function Test-LocalBranch {
    param(
        [string] $Repository,
        [string] $Branch
    )

    Invoke-Git -Repository $Repository -Arguments @("show-ref", "--verify", "--quiet", "refs/heads/$Branch")
    $LASTEXITCODE -eq 0
}

function Get-CurrentBranch {
    param([string] $Repository)

    $branch = Invoke-Git -Repository $Repository -Arguments @("branch", "--show-current")
    if ([string]::IsNullOrWhiteSpace($branch)) {
        return "(detached HEAD)"
    }

    $branch.Trim()
}

function Set-MainOrMasterBranch {
    param([string] $Repository)

    $targetBranch = $null
    if (Test-LocalBranch -Repository $Repository -Branch "main") {
        $targetBranch = "main"
    }
    elseif (Test-LocalBranch -Repository $Repository -Branch "master") {
        $targetBranch = "master"
    }

    if (-not $targetBranch) {
        Write-Warn "  skip: no local main or master branch"
        return
    }

    $currentBranch = Get-CurrentBranch -Repository $Repository
    if ($currentBranch -eq $targetBranch) {
        Write-Host "  already on $targetBranch"
        return
    }

    if ($WhatIf) {
        Write-Warn "  would checkout $targetBranch from $currentBranch"
        return
    }

    Write-Warn "  checkout $targetBranch from $currentBranch"
    Invoke-Git -Repository $Repository -Arguments @("checkout", $targetBranch) | ForEach-Object {
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
    Set-MainOrMasterBranch -Repository $repo
}

Write-Info ""
if ($WhatIf) {
    Write-Info "Dry run completed. Re-run without -WhatIf to checkout main or master."
}
else {
    Write-Info "Checkout completed."
}
