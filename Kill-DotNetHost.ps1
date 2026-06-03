$ErrorActionPreference = 'Continue'

$dotNetHostProcesses = Get-Process -ErrorAction SilentlyContinue |
    Where-Object {
        try {
            $_.MainModule.FileVersionInfo.FileDescription -eq '.NET Host'
        }
        catch {
            $false
        }
    }

if (-not $dotNetHostProcesses) {
    Write-Host 'No .NET Host processes found.'
    exit 0
}

$dotNetHostProcesses |
    Select-Object Id, ProcessName, Path |
    Format-Table -AutoSize

$dotNetHostProcesses | Stop-Process -Force

Write-Host "Stopped $($dotNetHostProcesses.Count) .NET Host process(es)."
