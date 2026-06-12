# Workspace Maintenance Tools

Small PowerShell toolkit for running local workspace maintenance scripts from an arrow-key menu.

## Scripts

- `Invoke-WorkspaceMaintenance.ps1`: interactive menu. Stores the selected workspace path in `%APPDATA%\WorkspaceMaintenanceTools\config.json`.
- `Install-WorkspaceMaintenanceShortcuts.ps1`: installs PowerShell profile shortcuts so the menu can be opened from any terminal.
- `Checkout-MainOrMaster-Repos.ps1`: checks out `main`, falling back to `master`, for primary repositories.
- `Clean-GitBranchesAndStaleWorktrees.ps1`: deletes local branches except `main` and `master`, and prunes stale worktree records.
- `Pull-MainOrMaster-Repos.ps1`: fast-forward pulls `main` or `master` from `upstream`, falling back to `origin`.
- `Kill-DotNetHost.ps1`: stops running .NET Host processes.

## Usage

Run the menu directly from the repository:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-WorkspaceMaintenance.ps1
```

## Install shortcuts

After cloning the repository, run this once from the repository folder.

To choose your own command name:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-WorkspaceMaintenanceShortcuts.ps1 -Name gertools
```

Then open a new terminal and run it from any folder:

```powershell
gertools
```

If you do not pass `-Name`, the installer creates the default commands:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-WorkspaceMaintenanceShortcuts.ps1
```

The installer adds shortcuts to both PowerShell profile locations:

- `%USERPROFILE%\Documents\PowerShell\profile.ps1` for PowerShell 7+ (`pwsh`)
- `%USERPROFILE%\Documents\WindowsPowerShell\profile.ps1` for Windows PowerShell 5.1 (`powershell.exe`)

Then open a new terminal and run either command from any folder:

```powershell
workspace-maintenance
```

or the shorter alias:

```powershell
wm
```

You can also install a custom command plus a short alias:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-WorkspaceMaintenanceShortcuts.ps1 -Name gertools -ShortCommandName gt
```

To use the shortcuts in the current terminal without reopening it, reload your profile:

```powershell
. $PROFILE
```

The Git scripts accept `-Root` and `-WhatIf` directly when run individually.
