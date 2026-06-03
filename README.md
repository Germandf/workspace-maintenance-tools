# Workspace Maintenance Tools

Small PowerShell toolkit for running local workspace maintenance scripts from an arrow-key menu.

## Scripts

- `Run-DesktopScripts.ps1`: interactive menu. Stores the selected workspace path in `%APPDATA%\WorkspaceMaintenanceTools\config.json`.
- `Checkout-MainOrMaster-Repos.ps1`: checks out `main`, falling back to `master`, for primary repositories.
- `Clean-GitBranchesAndStaleWorktrees.ps1`: deletes local branches except `main` and `master`, and prunes stale worktree records.
- `Pull-MainOrMaster-Repos.ps1`: fast-forward pulls `main` or `master` from `upstream`, falling back to `origin`.
- `Kill-DotNetHost.ps1`: stops running .NET Host processes.

## Usage

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Run-DesktopScripts.ps1
```

The Git scripts accept `-Root` and `-WhatIf` directly when run individually.
