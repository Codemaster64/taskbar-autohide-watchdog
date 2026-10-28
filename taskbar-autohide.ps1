# Keeps the Windows taskbar auto-hiding: if it sits visible while the cursor is
# elsewhere, re-apply the auto-hide state so Explorer hides it again. Also forces it up
# whenever the cursor touches the bottom pixel row of a monitor.
#   pwsh tools\taskbar-autohide.ps1              run in the foreground
#   pwsh tools\taskbar-autohide.ps1 -Install     run hidden at every logon
#   pwsh tools\taskbar-autohide.ps1 -Uninstall   remove the logon task
param([switch]$Install, [switch]$Uninstall)

$task = 'TaskbarAutoHideWatchdog'
if ($Uninstall) { Unregister-ScheduledTask $task -Confirm:$false; return }
if ($Install) {
    $a = New-ScheduledTaskAction -Execute (Get-Process -Id $PID).Path `
        -Argument "-NoProfile -WindowStyle Hidden -File `"$PSCommandPath`""
    # -User scopes the trigger to this account; an any-user logon trigger needs admin.
    # This is a continuous watchdog: Task Scheduler defaults stop it on battery
    # power or after 72 hours, leaving no process to repair the taskbar.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
    Register-ScheduledTask $task -Action $a -Force `
        -Settings $settings `
        -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME) | Out-Null
    Start-ScheduledTask $task
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class Tb {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct APPBARDATA {
    public int cbSize; public IntPtr hWnd; public uint msg, edge; public RECT rc; public IntPtr lParam; }
  [DllImport("user32")] static extern IntPtr FindWindow(string c, string t);
  [DllImport("user32")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32")] static extern bool GetCursorPos(out POINT p);
  [DllImport("shell32")] static extern IntPtr SHAppBarMessage(uint m, ref APPBARDATA d);

  // True when the taskbar is showing but the cursor is not on/near it.
  public static bool Visible() {
    RECT r;
    if (!GetWindowRect(FindWindow("Shell_TrayWnd", null), out r)) return false;
    // A hidden bar keeps its full size but slides off-screen leaving ~2px, so measure the
    // part that overlaps the primary monitor, not the window size.
    var sb = System.Windows.Forms.Screen.PrimaryScreen.Bounds;
    int vw = Math.Min(r.R, sb.Right) - Math.Max(r.L, sb.Left);
    int vh = Math.Min(r.B, sb.Bottom) - Math.Max(r.T, sb.Top);
    return Math.Min(vw, vh) > 10;
  }
  public static bool StuckVisible() {
    RECT r; POINT p;
    if (!GetWindowRect(FindWindow("Shell_TrayWnd", null), out r) || !GetCursorPos(out p)) return false;
    bool shown = Visible();
    bool near = p.X >= r.L - 8 && p.X <= r.R + 8 && p.Y >= r.T - 8 && p.Y <= r.B + 8;
    return shown && !near;
  }
  static void SetState(int s) {
    var d = new APPBARDATA(); d.cbSize = Marshal.SizeOf(d); d.lParam = (IntPtr)s;
    SHAppBarMessage(0x0A, ref d);                        // ABM_SETSTATE
  }
  // State flags: 1 = auto-hide, 2 = always-on-top (Win11 keeps 2 set either way).
  public static void Nudge() { SetState(2); SetState(3); }
  public static void Show() { SetState(2); }   // auto-hide off: bar slides up and stays
  public static void Hide() { SetState(3); }   // auto-hide back on

  // Cursor position vs the bottom strip of any monitor: depth 1 = the last pixel row.
  // ponytail: assumes the taskbar is at the bottom, which is where this is for.
  public static bool InBottom(int depth) {
    POINT p; if (!GetCursorPos(out p)) return false;
    foreach (var s in System.Windows.Forms.Screen.AllScreens) {
      var b = s.Bounds;
      if (p.X >= b.Left && p.X < b.Right && p.Y >= b.Bottom - depth && p.Y < b.Bottom) return true;
    }
    return false;
  }
  public static int Thickness() {
    RECT r; GetWindowRect(FindWindow("Shell_TrayWnd", null), out r);
    return Math.Max(r.B - r.T, 48);
  }
}

// Tracks windows flashing for attention via the shell hook (the taskbar is meant to stay
// shown for those). Windows has no "is anything flashing" query, only this notification.
public class Flash : System.Windows.Forms.NativeWindow {
  [DllImport("user32")] static extern uint RegisterWindowMessage(string s);
  [DllImport("user32")] static extern bool RegisterShellHookWindow(IntPtr h);
  readonly uint shellHook = RegisterWindowMessage("SHELLHOOK");
  public readonly System.Collections.Generic.HashSet<long> Flashing = new System.Collections.Generic.HashSet<long>();
  public Flash() { CreateHandle(new System.Windows.Forms.CreateParams()); RegisterShellHookWindow(Handle); }
  protected override void WndProc(ref System.Windows.Forms.Message m) {
    if (m.Msg == shellHook) {
      long w = (long)m.LParam;
      switch ((int)m.WParam) {
        case 0x8006: Flashing.Add(w); break;                              // HSHELL_FLASH
        case 4: case 0x8004: case 2: Flashing.Remove(w); break;           // activated / destroyed
      }
    }
    base.WndProc(ref m);
  }
}
'@ -ReferencedAssemblies System.Windows.Forms, System.Windows.Forms.Primitives, System.Drawing.Primitives, System.Collections, System.Runtime.InteropServices

$flash = [Flash]::new()
$stuck = 0
$nudged = $false
# ponytail: ticks every 100ms (edge reveal needs to feel instant); only nudges after 3s
# of stuck-visible with nothing flashing, so a taskbar the user is using (cursor near it)
# or an app is flagging is never touched. Only sees flashes that start after this script
# does; the stuck check watches the primary taskbar only.
$revealed = $false
$edge = 0
$timer = [System.Windows.Forms.Timer]::new()
$timer.Interval = 100
$timer.Add_Tick({
    # One recovery per user interaction. If Explorer immediately shows the bar
    # again, repeating SETSTATE every three seconds makes it bounce indefinitely.
    # A brief hide caused by our own reset must not re-arm recovery.
    if ([Tb]::InBottom([Tb]::Thickness() + 8)) { $script:nudged = $false }
    # Cursor on the bottom pixel: let Windows slide the bar up itself (smooth); only if it
    # hasn't appeared after ~300ms force it up, and keep it up until the cursor leaves.
    if (-not $script:revealed) {
        if ([Tb]::InBottom(1) -and -not [Tb]::Visible()) { $script:edge++ } else { $script:edge = 0 }
        if ($script:edge -ge 3) { [Tb]::Show(); $script:revealed = $true; $script:edge = 0 }
    }
    if ($script:revealed) {
        if (-not [Tb]::InBottom([Tb]::Thickness() + 8)) { [Tb]::Hide(); $script:revealed = $false }
        $script:stuck = 0
        return
    }
    if ($flash.Flashing.Count -eq 0 -and [Tb]::StuckVisible()) { $script:stuck++ } else { $script:stuck = 0 }
    if ($script:stuck -ge 30 -and -not $script:nudged) {
        [Tb]::Nudge(); $script:nudged = $true; $script:stuck = 0
    }
})
$timer.Start()
[System.Windows.Forms.Application]::Run()
