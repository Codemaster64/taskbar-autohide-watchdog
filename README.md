# taskbar-autohide-watchdog

Windows 11 PowerShell script that keeps the taskbar auto-hiding and makes the bottom screen edge reliably reveal it.

- Re-applies auto-hide if the taskbar sits visible while the cursor is elsewhere (skipped while an app is flashing for attention).
- Reveals the taskbar when the cursor touches the bottom pixel row of any monitor; Windows' own slide animation is used first, and the script only forces it up if it hasn't appeared after ~0.3s.

```powershell
pwsh taskbar-autohide.ps1              # run in the foreground
pwsh taskbar-autohide.ps1 -Install     # run hidden at every logon (no admin needed)
pwsh taskbar-autohide.ps1 -Uninstall   # remove the logon task
```

The installed task runs on battery power, has no runtime limit, and retries up to
three times at one-minute intervals after a failure. Run `-Install` again after
updating to replace older task settings. Keep the installed script at that path.

Check installer settings without changing your scheduled task:
`pwsh -NoProfile -File test-install.ps1`.

Limits: auto-hide is a single global Windows setting, so every monitor's taskbar behaves the same; the stuck-visible check watches the primary taskbar only; the taskbar is assumed to be at the bottom.
