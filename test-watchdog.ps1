$ErrorActionPreference = 'Stop'
# Run the actual timer callback against a stuck bar, without changing Windows.
Add-Type @'
public static class Tb {
  public static bool Near, Stuck = true;
  public static int Nudges;
  public static bool InBottom(int depth) { return depth > 1 && Near; }
  public static int Thickness() { return 48; }
  public static bool Visible() { return true; }
  public static bool StuckVisible() { return Stuck; }
  public static void Nudge() { Nudges++; }
  public static void Show() {}
  public static void Hide() {}
}
'@
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/taskbar-autohide.ps1", [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw $errors[0] }
$call = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'Add_Tick' }, $true)
$tick = $call.Arguments[0].ScriptBlock.GetScriptBlock()
$flash = @{ Flashing = @() }; $revealed = $false; $edge = 0; $stuck = 0; $nudged = $false
1..120 | ForEach-Object { . $tick }
if ([Tb]::Nudges -ne 1) { throw "Repeated resets while unattended: $([Tb]::Nudges)" }
# A brief hide after the reset must not re-arm a repeating bounce.
[Tb]::Stuck = $false; . $tick; [Tb]::Stuck = $true
1..60 | ForEach-Object { . $tick }
if ([Tb]::Nudges -ne 1) { throw 'Brief hiding re-armed reset loop.' }
# User interaction permits a later, independent recovery.
[Tb]::Near = $true; [Tb]::Stuck = $false; . $tick
[Tb]::Near = $false; [Tb]::Stuck = $true
1..30 | ForEach-Object { . $tick }
if ([Tb]::Nudges -ne 2) { throw 'Recovery did not re-arm after user interaction.' }
'PASS: no unattended reset loop; user interaction re-arms recovery'
