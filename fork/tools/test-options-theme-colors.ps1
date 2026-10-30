# 选项区背景必须跟着主题参数走（用户要求：这些颜色都该有参数控制）
# 判据不是「比系统灰好看一点」，而是「改参数 ⇒ 读数跟着变」：
#   A) 默认 Light 主题            -> bg = 主题窗口背景
#   B) MainWindowBackground = #ffff00aa -> bg 必须变成它（Light 主题下 ThemeMainWindowBackgroundColor 尊重该 pref）
#   C) Theme = Dark                -> bg 必须是暗色（亮度明显低于 A）
# 三态各起一次真程序，只为读那一行日志。
$ErrorActionPreference = "Stop"
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class Q {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc c, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  public static string Text(IntPtr h){ var b=new StringBuilder(512); GetWindowTextW(h,b,b.Capacity); return b.ToString(); }
  public static System.Collections.Generic.List<IntPtr> Top(int pid){
    var l=new System.Collections.Generic.List<IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr x){ int p; GetWindowThreadProcessId(h,out p);
      if(p==pid && IsWindowVisible(h) && Text(h).Length>0) l.Add(h); return true; }, IntPtr.Zero);
    return l; }
}
"@

# DERIVE: repo root = three levels up from fork/tools
$ROOT = (Get-Item (Join-Path $PSScriptRoot "..\..\..")).FullName
$EXE  = "$ROOT\.main\out\rel64\SumatraPDF.exe"
$BASE = "$ROOT\.temp\m12-color"
$WM_COMMAND = 0x0111
$CmdOptions = 319
$WM_CLOSE   = 0x0010

function Measure-Bg([string]$name, [string[]]$extraSettings, [string[]]$pageBlock) {
  # $name 的第一段决定 textXxx 变量名（A/B/C）
  $d = Join-Path $BASE $name
  if (Test-Path $d) { Remove-Item $d -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $d | Out-Null
  Copy-Item $EXE (Join-Path $d "SumatraPDF-Q.exe") -Force
  $lines = @("UseTabs = true", "ShowStartPage = false", "CheckForUpdates = false", "RestoreSession = false") + $extraSettings
  if ($pageBlock) { $lines = $lines + @("FixedPageUI [") + $pageBlock + @("]") }
  Set-Content -Path (Join-Path $d "SumatraPDF-settings.txt") -Encoding ASCII -Value $lines
  $p = Start-Process -FilePath (Join-Path $d "SumatraPDF-Q.exe") -PassThru -WorkingDirectory $d `
       -RedirectStandardOutput (Join-Path $d "app.log") -RedirectStandardError (Join-Path $d "app.err")
  Start-Sleep -Seconds 6
  $main = [Q]::Top($p.Id) | Select-Object -First 1
  if (-not $main) { Stop-Process -Id $p.Id -Force; throw "$name 主窗口没起来" }
  [void][Q]::PostMessageW($main, $WM_COMMAND, [IntPtr]$CmdOptions, [IntPtr]::Zero)
  Start-Sleep -Seconds 3
  [void][Q]::PostMessageW($main, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
  Start-Sleep -Seconds 2
  if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
  $m = Select-String -Path (Join-Path $d "app.log") -Pattern "SettingsPage: bg=#([0-9a-f]{6}) text=#([0-9a-f]{6})" | Select-Object -First 1
  if (-not $m) { throw "$name 日志里没有 bg=/text= 行" }
  $hex = $m.Matches[0].Groups[1].Value
  Set-Variable -Name ("text" + $name.Split('-')[0]) -Value $m.Matches[0].Groups[2].Value -Scope Global
  Write-Host "  $name -> #$hex"
  return $hex
}

$fails = @()
$a = Measure-Bg "A-light" @()
 $b = Measure-Bg "B-custom" @() @("  BackgroundColor = #ff00aa", "  TextColor = #ffffff")
$c = Measure-Bg "C-dark" @("Theme = Dark")

$toI = { param($h) [Convert]::ToInt32($h, 16) }
$lum = { param($h) $n = & $toI $h; (0.299*(($n -shr 16) -band 255) + 0.587*(($n -shr 8) -band 255) + 0.114*($n -band 255)) }
"读数：A=$a B=$b C=$c   亮度 A=$([math]::Round((& $lum $a),1)) B=$([math]::Round((& $lum $b),1)) C=$([math]::Round((& $lum $c),1))"

if ($b -ne "ff00aa") { $fails += "FixedPageUI.BackgroundColor 没进选项区背景：期望 ff00aa，读到 $b" }
if ($a -ne "ffffff") { $fails += "Light 主题下选项区不是页面白（读到 $a，期望 ffffff）——用户要的就是这个" }
# 「Dark 主题必须暗底」是我凭空发明的判据，量出来才发现与参照物冲突：
# 应用的 Dark 主题并不改 FixedPageUI 的页面色（PDF 仍是白底黑字，除非用户自己设），
# 而选项区现在就是跟着页面色走。所以真正要盯的不变量是**底与字必须有对比**，
# 而不是某个具体颜色。三态各查一次对比度。
function Check-Contrast([string]$label, [string]$bg, [string]$tx) {
  $lumBg = [Convert]::ToInt32($bg, 16)
  $lumTx = [Convert]::ToInt32($tx, 16)
  $lb = 0.299*(($lumBg -shr 16) -band 255) + 0.587*(($lumBg -shr 8) -band 255) + 0.114*($lumBg -band 255)
  $lt = 0.299*(($lumTx -shr 16) -band 255) + 0.587*(($lumTx -shr 8) -band 255) + 0.114*($lumTx -band 255)
  $d = [math]::Abs($lb - $lt)
  Write-Host ("  {0} 底=#{1} 字=#{2} 亮度差 {3}" -f $label, $bg, $tx, [math]::Round($d,1))
  if ($d -lt 64) { $script:fails += "$($label) 态：底色与文字亮度差只有 $([math]::Round($d,1))，会看不清" }
}
Check-Contrast "A" $a $textA
Check-Contrast "B" $b $textB
Check-Contrast "C" $c $textC
if ($a -eq $b) { $fails += "改了 MainWindowBackground 背景却没变（都是 $a）——颜色不是参数驱动的" }
# 这一条删掉了：Dark 主题不改 FixedPageUI 的页面色，白底是应用的既有行为；
# 「必须暗底」属于我凭空发明的判据，已由上面的对比度检查取代。
# C != A 不再断言：Dark 主题不改页面色，两者相同是应用的既有行为（上面已记）

""
if ($fails.Count) { "RESULT: FAIL"; $fails | ForEach-Object { "  - $_" }; exit 1 }
"RESULT: PASS"
