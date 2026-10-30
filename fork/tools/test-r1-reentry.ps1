# R1 回归：多窗口下选项页必须是单例
#
# 缺陷形状：SettingsPage 用全局 gPage + 自己泵消息，而 SumatraPDF 合法支持多主窗口
# （CmdNewWindow=242）。旧版在窗口 2 再开一次会造出第二个页面窗口并把 gPage 覆盖掉，
# 之后点第一个页面的任何按钮就是空指针崩溃。
# 所以这里不真去点（不赌 Windows 的错误对话框会不会弹），只数「选项」窗口个数：
#   旧版 = 2（红），新版 = 1（绿）。
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class U32 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc c, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
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
$T   = "$ROOT\.temp\m11-r1"
$EXE = "$ROOT\.main\upstream\out\rel64\SumatraPDF.exe"
$WM_COMMAND = 0x0111
$CmdNewWindow = 242
$CmdOptions   = 319

if (Test-Path $T) { Remove-Item $T -Recurse -Force }
New-Item -ItemType Directory -Force -Path $T | Out-Null
Copy-Item $EXE (Join-Path $T "SumatraPDF-Q.exe") -Force

$p = Start-Process -FilePath (Join-Path $T "SumatraPDF-Q.exe") -PassThru -WorkingDirectory $T `
     -RedirectStandardOutput (Join-Path $T "app.log") -RedirectStandardError (Join-Path $T "app.err")
Start-Sleep -Seconds 6
$wins = @([U32]::Top($p.Id))
if ($wins.Count -lt 1) { "FAIL: 主窗口没起来"; Stop-Process -Id $p.Id -Force; exit 1 }
"1) 主窗口数: $($wins.Count)"

[void][U32]::PostMessageW($wins[0], $WM_COMMAND, [IntPtr]$CmdNewWindow, [IntPtr]::Zero)
Start-Sleep -Seconds 3
$wins = @([U32]::Top($p.Id))
"2) 发 CmdNewWindow 后主窗口数: $($wins.Count)"
if ($wins.Count -lt 2) { "FAIL: 没能开出第二个主窗口（这条回归的前提不成立）"; Stop-Process -Id $p.Id -Force; exit 1 }

# 窗口 1 开选项页；再在窗口 2 开一次
[void][U32]::PostMessageW($wins[0], $WM_COMMAND, [IntPtr]$CmdOptions, [IntPtr]::Zero)
Start-Sleep -Seconds 2
[void][U32]::PostMessageW($wins[1], $WM_COMMAND, [IntPtr]$CmdOptions, [IntPtr]::Zero)
Start-Sleep -Seconds 2
$pages = @([U32]::Top($p.Id) | Where-Object { [U32]::Text($_) -like "*选项*" })
"3) 选项页窗口数: $($pages.Count)   （判据：必须恰好 1 个）"

$fails = @()
if ($pages.Count -ne 1) { $fails += "第二次打开没有复用已有页面，造出了 $($pages.Count) 个选项页窗口" }
$stillEnabled = @($wins | Where-Object { [U32]::IsWindowEnabled($_) -and [U32]::Text($_) -notlike "*选项*" })
"4) 未被禁用的主窗口: $($stillEnabled.Count) 个（页面打开时主窗口应被禁用，仅记录不断言）"

Stop-Process -Id $p.Id -Force
Start-Sleep -Seconds 1
""
if ($fails.Count) { "RESULT: FAIL"; $fails | ForEach-Object { "  - $_" }; exit 1 }
"RESULT: PASS"
