# m09 量具：标签条与标题栏按钮的真实几何（不改产品，纯外部读数）
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class P {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc c, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc c, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern int GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int idx);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT v, int size);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int v, int size);
  [DllImport("dwmapi.dll")] public static extern int DwmExtendFrameIntoClientArea(IntPtr h, ref MARGINS m);
  [StructLayout(LayoutKind.Sequential)] public struct PT { public int x, y; }
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(PT p);
  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
  // 从最深层子窗口往上问 WM_NCHITTEST，遇 HTTRANSPARENT(-1) 继续问父窗口——和系统行为一致
  public static int HitTest(IntPtr start, int sx, int sy) {
    IntPtr h = start;
    for (int i = 0; i < 8 && h != IntPtr.Zero; i++) {
      IntPtr lp = (IntPtr)(((sy & 0xffff) << 16) | (sx & 0xffff));
      int r = SendMessageW(h, 0x0084, IntPtr.Zero, lp).ToInt32();
      if (r != -1) return r;
      h = GetParent(h);
    }
    return -999;
  }
  public struct RECT { public int Left, Top, Right, Bottom; }
  public struct MARGINS { public int l, r, t, b; }
  public static string Text(IntPtr h){ var b=new StringBuilder(512); GetWindowTextW(h,b,b.Capacity); return b.ToString(); }
  public static string Class(IntPtr h){ var b=new StringBuilder(256); GetClassNameW(h,b,b.Capacity); return b.ToString(); }
  public static RECT Rect(IntPtr h){ RECT r; GetWindowRect(h, out r); return r; }
  [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr h, ref MONITORINFOEX m);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, int flags);
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFOEX {
    public int cbSize; public RECT rcMonitor; public RECT rcWork; public int dwFlags;
    [MarshalAsAttribute(UnmanagedType.ByValTStr, SizeConst=32)] public string szDevice;
  }
  public static int WorkTop(IntPtr h) {
    MONITORINFOEX mi = new MONITORINFOEX(); mi.cbSize = System.Runtime.InteropServices.Marshal.SizeOf(typeof(MONITORINFOEX));
    if (!GetMonitorInfo(MonitorFromWindow(h, 0), ref mi)) return -99999;
    return mi.rcWork.Top;
  }
  public static int HitTestOne(IntPtr h, int x, int y){ IntPtr lp=(IntPtr)(((y & 0xffff)<<16)|(x & 0xffff)); return SendMessageW(h, 0x0084, IntPtr.Zero, lp).ToInt32(); }
  public static System.Collections.Generic.List<IntPtr> KidsAll(IntPtr p){
    var l=new System.Collections.Generic.List<IntPtr>();
    EnumChildWindows(p, delegate(IntPtr h, IntPtr x){ l.Add(h); return true; }, IntPtr.Zero);
    return l; }
  public static System.Collections.Generic.List<IntPtr> Kids(IntPtr p){
    var l=new System.Collections.Generic.List<IntPtr>();
    EnumChildWindows(p, delegate(IntPtr h, IntPtr x){ if (IsWindowVisible(h)) l.Add(h); return true; }, IntPtr.Zero);
    return l; }
  public static System.Collections.Generic.List<IntPtr> Top(int pid){
    var l=new System.Collections.Generic.List<IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr x){ int p; GetWindowThreadProcessId(h,out p);
      if(p==pid && IsWindowVisible(h) && Text(h).Length>0) l.Add(h); return true; }, IntPtr.Zero);
    return l; }
}
"@

$ErrorActionPreference = "Stop"   # 判据里任何异常都必须终止：上一版 foreach 抛了却仍报 PASS
# DERIVE: repo root = three levels up from fork/tools
$ROOT = (Get-Item (Join-Path $PSScriptRoot "..\..\..")).FullName
$T   = "$ROOT\.temp\m09t"
$EXE = "$ROOT\.main\upstream\out\rel64\SumatraPDF.exe"
$CAJ = "$ROOT\.ex\儿童青少年期内外化问题的共发及亲子关系和友谊质量的影响.caj"
$PDF = "$ROOT\.build\caj-cache\儿童青少年期内外化问题的共发及亲子关系和友谊质量的影响.pdf"

if (Test-Path $T) { Remove-Item $T -Recurse -Force }
New-Item -ItemType Directory -Force -Path $T | Out-Null
Copy-Item $EXE (Join-Path $T "SumatraPDF-Q.exe") -Force
# 要标签条就必须 useTabs = true
Set-Content -Path (Join-Path $T "SumatraPDF-settings.txt") -Encoding UTF8 -Value @(
  "UseTabs = true", "ShowStartPage = false", "CheckForUpdates = false", "RestoreSession = false",
  "ShowMenubar = true", "ShowToolbar = true", "TabWidth = 300", "Theme = Light"
)

$p = Start-Process -FilePath (Join-Path $T "SumatraPDF-Q.exe") -ArgumentList "`"$CAJ`"","`"$PDF`"" `
     -PassThru -WorkingDirectory $T
Start-Sleep -Seconds 7
$main = [P]::Top($p.Id) | Select-Object -First 1
if (-not $main) { "FAIL: 主窗口没起来"; Stop-Process -Id $p.Id -Force; exit 1 }
[void][P]::MoveWindow($main, 420, 240, 900, 620, $true)
Start-Sleep -Seconds 2
$fr = [P]::Rect($main)
"frame      : $($fr.Left),$($fr.Top) - $($fr.Right),$($fr.Bottom)   ($($fr.Right-$fr.Left)x$($fr.Bottom-$fr.Top))  DPI=$([P]::GetDpiForWindow($main))"

$capBtn = New-Object P+RECT
$r = [P]::DwmGetWindowAttribute($main, 5, [ref]$capBtn, [Runtime.InteropServices.Marshal]::SizeOf($capBtn))
"DWMWA_CAPTION_BUTTON_BOUNDS(=5) rc=$r  window-relative: top=$($capBtn.Top) bottom=$($capBtn.Bottom) 高=$(($capBtn.Bottom-$capBtn.Top)) left=$($capBtn.Left) right=$($capBtn.Right)"
$bt = 0
$r2 = [P]::DwmGetWindowAttribute($main, 37, [ref]$bt, 4)
"DWMWA_VISIBLE_FRAME_BORDER_THICKNESS(=37) rc=$r2 值=$bt"
"SM_CYFRAME=$( [P]::GetSystemMetrics(33) ) SM_CXPADDEDBORDER=$( [P]::GetSystemMetrics(92) ) => frameThickness=$([P]::GetSystemMetrics(33)+[P]::GetSystemMetrics(92))"
"DWMWA_EXTENDED_FRAME_BOUNDS:"
$ef = New-Object P+RECT
$r3 = [P]::DwmGetWindowAttribute($main, 9, [ref]$ef, [Runtime.InteropServices.Marshal]::SizeOf($ef))
"   rc=$r3 top=$($ef.Top) vs frame top=$($fr.Top)  => 可见顶边内缩 $(($ef.Top-$fr.Top)) px"

$tab = $null; $band = $null
foreach ($k in [P]::Kids($main)) {
  $c = [P]::Class($k)
  $q = [P]::Rect($k)
  "{0,-22} y={1}..{2} 高={3}  距 frame 顶 {4}px" -f $c, $q.Top, $q.Bottom, ($q.Bottom-$q.Top), ($q.Top-$fr.Top)
  if ($c -eq "SysTabControl32") { $tab = $q }
  if ($c -eq "CustomCaption")   { $band = $q }
}
  $fails = @()
if (-not $tab) { $fails += "没找到标签条窗口（SysTabControl32）——标签模式没开起来？" }
if (-not $band) { $fails += "没找到 CustomCaption" }
if ($r -ne 0) { $fails += "DWMWA_CAPTION_BUTTON_BOUNDS 调用失败 rc=$r，判据不成立" }
if ($tab -and $r -eq 0) {
  # 按钮带与标签条都用「相对 frame 顶」的坐标比较
  $btnTop = $fr.Top + $capBtn.Top;  $btnBot = $fr.Top + $capBtn.Bottom
  $bandTopAbs = $band.Top; $bandBotAbs = $band.Bottom
  $btnMid = [math]::Round(($btnTop + $btnBot) / 2.0, 1)
  $tabMid = [math]::Round(($tab.Top + $tab.Bottom) / 2.0, 1)
  $dTop   = $tab.Top - $btnTop
  $dMid   = [math]::Abs($tabMid - $btnMid)
  $padTop = $tab.Top - $bandTopAbs; $padBot = $bandBotAbs - $tab.Bottom
  "6) 按钮带 y=$btnTop..$btnBot 中心 $btnMid ；标签条 y=$($tab.Top)..$($tab.Bottom) 中心 $tabMid"
  "   中心差 $dMid px；带内余量 上 $padTop / 下 $padBot px"
  # 判据只有两条，而且是量出来之后想清楚的：
  #  1) 中心必须与按钮带对齐（缺陷原状是低 11px）
  #  2) 带内上下余量必须对称（贴底对齐时是 上6/下0，视觉上就是「标签头顶一大片空」）
  # 不写「标签顶边 == 按钮顶边」：标签高 24 而 DWM 报的带高 30，居中必然上下各 3px，
  # 那条判据与「居中对齐」在数学上不可能同时成立。
  if ($dMid -gt 2) { $fails += "标签与标题栏按钮垂直中心差 $dMid px（>2px）" }
  if ([math]::Abs($padTop - $padBot) -gt 1) { $fails += "标签在带内不对称：上 $padTop px / 下 $padBot px" }
  if ($band) {
    $inBandTop = $tab.Top - $band.Top
    $inBandBot = $band.Bottom - $tab.Bottom
    "   带内余量：上 $inBandTop px / 下 $inBandBot px（贴底对齐时上=带高-标签高、下=0）"
  }
}
# 最大化走的是旧代码里另一条分支（scale=1.f），必须单独量一次
# 可见顶边 = extended frame bounds 的顶 - frame 的顶
# 命中测试只走**我们自己的窗口树**：这台桌面与并行的其它 AI 会话共用，
# WindowFromPoint 会命中别的进程的窗口（我就被一个 Chrome_RenderWidgetHostHWND 骗过两次）。
# 常量取自 SDK winuser.h：HTCLIENT=1 HTCAPTION=2 HTTOP=12 HTTRANSPARENT=-1。
$HTTOP = 12; $HTTRANSPARENT = -1
$efb = New-Object P+RECT
$ref = [P]::DwmGetWindowAttribute($main, 9, [ref]$efb, [Runtime.InteropServices.Marshal]::SizeOf($efb))
$visTop = if ($ref -eq 0) { $efb.Top - $fr.Top } else { 0 }
"5a) extendedFrameBounds rc=$ref top=$($efb.Top) => 可见顶边在 frame 内 $visTop px"

function Get-OurDeepest($frame, $kids, $x, $y) {
  $best = $frame
  foreach ($k in $kids) {
    $r = [P]::Rect($k)
    if ($x -ge $r.Left -and $x -lt $r.Right -and $y -ge $r.Top -and $y -lt $r.Bottom) {
      # 取面积最小的包含者 = 最深的子窗口
      if (([P]::Rect($best).Right - [P]::Rect($best).Left) * ([P]::Rect($best).Bottom - [P]::Rect($best).Top) -gt (($r.Right-$r.Left) * ($r.Bottom-$r.Top))) {
        $best = $k
      }
    }
  }
  return $best
}
function HitTestOurs($frame, $kids, $x, $y) {
  $h = Get-OurDeepest $frame $kids $x $y
  for ($i = 0; $i -lt 8; $i++) {
    if ($h -eq $null -or $h -eq [IntPtr]::Zero) { break }
    $r = [P]::HitTestOne($h, $x, $y)
    if ($r -ne $HTTRANSPARENT) { return $r }
    if ($h -eq $frame) { break }
    $h = [P]::GetParent($h)
  }
  return -999
}
$allKids = [P]::KidsAll($main)
$gx = $tab.Left + 24
$baseY = $fr.Top + $visTop
foreach ($d in @(2, 4, 6)) {
  $gy = $baseY + $d
  $who = Get-OurDeepest $main $allKids $gx $gy
  $htd = HitTestOurs $main $allKids $gx $gy
  $cls = [P]::Class($who)
  "5b) 标签条上方 depth=${d}px (x=$($gx - $fr.Left), 我们的窗口=$cls): 最终命中码=$htd  期望 HTTOP=$HTTOP"
  if ($htd -ne $HTTOP) { $fails += "顶部 ${d}px 处不能拖动缩放：命中码 $htd，期望 HTTOP=$HTTOP（在 $cls 上）" }
}
$gy12 = $baseY + 12
$ht12 = HitTestOurs $main $allKids $gx $gy12
$who12 = Get-OurDeepest $main $allKids $gx $gy12
"5c) depth=12px (在 $([P]::Class($who12)) 上): 命中码=$ht12  期望非 HTTOP（再深就必须能点标签/拖窗口）"
if ($ht12 -eq $HTTOP) { $fails += "顶部缩放区太深：depth=12px 仍是 HTTOP，会挡住标签点击" }

$SW_MAXIMIZE = 3
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class S2 { [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); }
"@
[S2]::ShowWindow($main, $SW_MAXIMIZE) | Out-Null
Start-Sleep -Seconds 2
$fr2 = [P]::Rect($main)
$capBtn2 = New-Object P+RECT
$r5 = [P]::DwmGetWindowAttribute($main, 5, [ref]$capBtn2, [Runtime.InteropServices.Marshal]::SizeOf($capBtn2))
$tab2 = $null; $band2 = $null
foreach ($k in [P]::Kids($main)) {
  $c = [P]::Class($k)
  if ($c -eq "SysTabControl32") { $tab2 = [P]::Rect($k) }
  if ($c -eq "CustomCaption")   { $band2 = [P]::Rect($k) }
}
if ($r5 -eq 0 -and $tab2 -and $band2) {
  $btnTop2 = $fr2.Top + $capBtn2.Top; $btnBot2 = $fr2.Top + $capBtn2.Bottom
  # 最大化时按钮带有一部分在屏幕外，判据只能按**可见部分**算中心，
  # 否则量的是一条肉眼看不见的边（我第一版就是这么误报 5px 的）
  $workTop2 = [P]::WorkTop($main)
  if ($btnTop2 -lt $workTop2) { $btnTop2 = $workTop2 }
  $btnMid2 = [math]::Round(($btnTop2 + $btnBot2) / 2.0, 1)
  $tabMid2 = [math]::Round(($tab2.Top + $tab2.Bottom) / 2.0, 1)
  $dMid2 = [math]::Abs($tabMid2 - $btnMid2)
  $pT2 = $tab2.Top - $band2.Top; $pB2 = $band2.Bottom - $tab2.Bottom
  $workTop = [P]::WorkTop($main)
  $clip = $workTop - $tab2.Top
  "7) 最大化：可见按钮带 y=$btnTop2..$btnBot2 中心 $btnMid2 ；标签条 y=$($tab2.Top)..$($tab2.Bottom) 中心 $tabMid2  => 中心差 $dMid2 px，带内 上 $pT2 / 下 $pB2"
  "   工作区顶边 $workTop，标签顶 $($tab2.Top)  => 被裁掉 $clip px（判据：必须 0）"
  if ($dMid2 -gt 2) { $fails += "最大化态：中心差 $dMid2 px（>2px）" }
  if ($clip -gt 0) { $fails += "最大化态：标签条顶部被屏幕边缘裁掉 $clip px" }
} else {
  "7) 最大化态量不到（rc=$r5 tab=$([bool]$tab2) band=$([bool]$band2)）——不记为通过"
  $fails += "最大化态没能量到"
}
$SW_RESTORE = 9
[S2]::ShowWindow($main, $SW_RESTORE) | Out-Null
Start-Sleep -Seconds 1

Stop-Process -Id $p.Id -Force
""
if ($fails.Count) { "RESULT: FAIL"; $fails | ForEach-Object { "  - $_" }; exit 1 }
"RESULT: PASS"
