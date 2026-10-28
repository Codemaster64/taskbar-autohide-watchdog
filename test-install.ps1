$ErrorActionPreference = 'Stop'
$capture = @{ Settings = $null }
# Exercise the real installer without replacing the user's scheduled task.
function Register-ScheduledTask {
    param($TaskName, $Action, [switch]$Force, $Trigger, $Settings)
    $capture.Settings = $Settings
}
function Start-ScheduledTask { param($TaskName) }
& "$PSScriptRoot/taskbar-autohide.ps1" -Install
$installedSettings = $capture.Settings
if (-not $installedSettings) { throw 'Installer uses default task settings (battery stops and 72h limit).' }
if ($installedSettings.ExecutionTimeLimit -ne 'PT0S') { throw 'Watchdog has a runtime limit.' }
if ($installedSettings.DisallowStartIfOnBatteries -or $installedSettings.StopIfGoingOnBatteries) { throw 'Battery power disables watchdog.' }
if ($installedSettings.RestartCount -lt 1) { throw 'Watchdog does not restart after failure.' }
'PASS: persistent watchdog task settings'
