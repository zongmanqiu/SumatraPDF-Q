Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class U32 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc c, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc c, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rt, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  public static string Text(IntPtr h){ var b=new StringBuilder(512); GetWindowTextW(h,b,b.Capacity); return b.ToString(); }
  public static string Class(IntPtr h){ var b=new StringBuilder(256); GetClassNameW(h,b,b.Capacity); return b.ToString(); }
  public static int[] Rect(IntPtr h){ R r; GetWindowRect(h, out r); return new int[]{r.L,r.T,r.Rt,r.B}; }
  public static System.Collections.Generic.List<IntPtr> Children(IntPtr p){
    var l=new System.Collections.Generic.List<IntPtr>();
    EnumChildWindows(p, delegate(IntPtr h, IntPtr x){ l.Add(h); return true; }, IntPtr.Zero);
    return l; }
  public static System.Collections.Generic.List<IntPtr> Top(int pid){
    var l=new System.Collections.Generic.List<IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr x){ int p; GetWindowThreadProcessId(h,out p);
      if(p==pid && IsWindowVisible(h) && Text(h).Length>0) l.Add(h); return true; }, IntPtr.Zero);
    return l; }
}
"@

# DERIVE: repo root = three levels up from fork/tools
$ROOT = (Get-Item (Join-Path $PSScriptRoot "..\..\..")).FullName
$T = "$ROOT\.temp\m04t"
$EXE = "$ROOT\.main\upstream\out\rel64\SumatraPDF.exe"
$CAJ = "$ROOT\.ex\儿童青少年期内外化问题的共发及亲子关系和友谊质量的影响.caj"
$SET = Join-Path $T "SumatraPDF-settings.txt"
$WM_COMMAND = 0x0111; $BM_CLICK = 0x00F5; $BM_GETCHECK = 0x00F0; $WM_CLOSE = 0x0010

if (Test-Path $T) { Remove-Item $T -Recurse -Force }
New-Item -ItemType Directory -Force -Path $T | Out-Null
Copy-Item $EXE (Join-Path $T "SumatraPDF-Q.exe") -Force

function ReadKey($k) {
  if (-not (Test-Path $SET)) { return "<no file>" }
  $l = Select-String -Path $SET -Pattern ("^" + $k + " = ") | Select-Object -First 1
  if ($l) { return $l.Line } else { return "<absent>" }
}

$fails = @()

# 发布的产物名就是 SumatraPDF-Q.exe，所以这里连「改名」本身一起验：
# PE 的 FileDescription 是任务管理器「进程」页读到的名字，而 ProductName / LegalCopyright
# 属于内部与上游声明，必须保持原样。
$vi = (Get-Item $EXE).VersionInfo
"0) FileDescription=$($vi.FileDescription)  ProductName=$($vi.ProductName)  LegalCopyright=$($vi.LegalCopyright)"
if ($vi.FileDescription -ne "SumatraPDF-Q") { $fails += "FileDescription 不是 SumatraPDF-Q（读到的是 $($vi.FileDescription)）" }
if ($vi.ProductName -ne "SumatraPDF") { $fails += "内部 ProductName 被改动了：$($vi.ProductName)" }
if ($vi.LegalCopyright -notlike "*GPLv3*") { $fails += "上游版权声明没保留：$($vi.LegalCopyright)" }
if ($vi.FileVersion -ne "3.6.1Q2") { $fails += "文件版本不是 3.6.1Q1（读到 $($vi.FileVersion)）" }

$p = Start-Process -FilePath (Join-Path $T "SumatraPDF-Q.exe") -ArgumentList "`"$CAJ`"" -PassThru -WorkingDirectory $T `
     -RedirectStandardOutput (Join-Path $T "app.log") -RedirectStandardError (Join-Path $T "app.err")
Start-Sleep -Seconds 6
$main = [U32]::Top($p.Id) | Select-Object -First 1
if (-not $main) { "FAIL: 主窗口没起来"; Stop-Process -Id $p.Id -Force; exit 1 }
"1) 主窗口: $([U32]::Text($main))"
if (([U32]::Text($main)) -notlike "*SumatraPDF-Q*") { $fails += "窗口标题没有 SumatraPDF-Q（对外名没生效）" }

[void][U32]::PostMessageW($main, $WM_COMMAND, [IntPtr]319, [IntPtr]::Zero)
Start-Sleep -Seconds 3
$dlg = [U32]::Top($p.Id) | Where-Object { [U32]::Text($_) -like "*选项*" } | Select-Object -First 1
if (-not $dlg) { "FAIL: 选项页没打开"; Stop-Process -Id $p.Id -Force; exit 1 }
$dr = [U32]::Rect($dlg)
$dlgW = $dr[2]-$dr[0]; $dlgH = $dr[3]-$dr[1]
"2) 选项页窗口矩形 L=$($dr[0]) T=$($dr[1]) R=$($dr[2]) B=$($dr[3])  尺寸 ${dlgW}x${dlgH}"

$kids = [U32]::Children($dlg)
$checks = @($kids | Where-Object { [U32]::Class($_) -eq "Button" -and [U32]::Text($_) -eq "" })
$btns   = @($kids | Where-Object { [U32]::Class($_) -eq "Button" -and [U32]::Text($_) -ne "" })
$edits  = @($kids | Where-Object { [U32]::Class($_) -eq "Edit" })
$combos = @($kids | Where-Object { [U32]::Class($_) -eq "ComboBox" -or [U32]::Class($_) -eq "Combo Box" })
$labels = @($kids | Where-Object { [U32]::Class($_) -eq "Static" -and [U32]::Text($_) -ne "" })
"3) 勾选框=$($checks.Count) 编辑框=$($edits.Count) 下拉=$($combos.Count) 标签=$($labels.Count) 按钮=$($btns.Count)"
# structural, not a hard-coded row count: every row is exactly one label plus
# one control, so this keeps working when the table is edited
if ($labels.Count -ne ($checks.Count + $edits.Count + $combos.Count)) {
  $fails += "标签数 $($labels.Count) != 控件数 $($checks.Count + $edits.Count + $combos.Count)"
}
if ($labels.Count -lt 8) { $fails += "只剩 $($labels.Count) 项，可能表被删坏了" }

# the app measures its own label column; a zero or tiny reading means the font
# was not selected while measuring, which shows up on screen as clipped text
$log = Join-Path $T "app.log"
if (Test-Path $log) {
  $m = Select-String -Path $log -Pattern "SettingsPage: measured" | Select-Object -First 1
  if ($m) { "5a) $($m.Line.Trim())" } else { $fails += "日志里没有 measured 行" }
}
  # 选项区背景必须跟 PDF 外围背景同色，不再是系统灰
  $cb = Select-String -Path $log -Pattern "SettingsPage: bg=" | Select-Object -First 1
  if (-not $cb) { $fails += "日志里没有 bg= 行（背景色没走主题参数）" } else { "5e) $($cb.Line.Trim())" }
  # 「颜色到底是不是参数驱动」不在这里断言：那要改参数重启才看得出来，
  # 由 .plan/tools/test-options-theme-colors.ps1 三态量（Light / MainWindowBackground / Dark）$labW = ($labels | ForEach-Object { $r=[U32]::Rect($_); $r[2]-$r[0] } | Measure-Object -Maximum).Maximum
$labH = ($labels | ForEach-Object { $r=[U32]::Rect($_); $r[3]-$r[1] } | Measure-Object -Maximum).Maximum
"5c) 标签控件最大宽 $labW 高 $labH"

# the reported bug: buttons below the visible area
foreach ($b in $btns) {
  $r = [U32]::Rect($b)
  if ($r[3] -gt $dr[3] -or $r[2] -gt $dr[2] -or $r[1] -lt $dr[1]) {
    $fails += "按钮「$([U32]::Text($b))」超出窗口可视范围: $($r -join ',') vs 窗口 $($dr -join ',')"
  }
}
$lowest = ($kids | ForEach-Object { [U32]::Rect($_)[3] } | Measure-Object -Maximum).Maximum
"4) 最底控件底边 $lowest  vs 窗口底边 $($dr[3])  ->  $([bool]($lowest -le $dr[3]))"
if ($lowest -gt $dr[3]) { $fails += "有控件被裁掉" }

# pair each checkbox with the label on its own row that is closest on its left.
# Matching on y alone ties across two columns and grabs the neighbour's label.
function Get-LabelFor($ctrl, $labels) {
  $cr = [U32]::Rect($ctrl)
  $bestR = -999999; $best = ""
  foreach ($s in $labels) {
    $sr = [U32]::Rect($s)
    if ($sr[2] -gt $cr[0]) { continue }                       # must sit left of the control
    if ([math]::Abs($sr[1] - $cr[1]) -gt 12) { continue }     # same row
    if ($sr[2] -gt $bestR) { $bestR = $sr[2]; $best = [U32]::Text($s) }
  }
  return $best
}
$labelOf = @{}
foreach ($b in $checks) { $labelOf[$b.ToInt64()] = Get-LabelFor $b $labels }
"5) 勾选框标签: $(($checks | ForEach-Object { $labelOf[$_.ToInt64()] }) -join ' / ')"
$distinct = ($checks | ForEach-Object { $labelOf[$_.ToInt64()] } | Sort-Object -Unique)
if ($distinct.Count -ne $checks.Count) { $fails += "有 $((($checks.Count) - ($distinct.Count))) 个勾选框配到了同一个标签（布局或配对有问题）" }

# geometry: nothing may overlap
$all = @($labels) + @($checks) + @($edits) + @($combos) + @($btns)
for ($a = 0; $a -lt $all.Count; $a++) {
  $ra = [U32]::Rect($all[$a])
  for ($b = $a + 1; $b -lt $all.Count; $b++) {
    $rb = [U32]::Rect($all[$b])
    $ox = [math]::Min($ra[2], $rb[2]) - [math]::Max($ra[0], $rb[0])
    $oy = [math]::Min($ra[3], $rb[3]) - [math]::Max($ra[1], $rb[1])
    if ($ox -gt 2 -and $oy -gt 2) {
      $fails += "控件重叠: '$([U32]::Text($all[$a]))$($ra[0]),$($ra[1])' 与 '$([U32]::Text($all[$b]))$($rb[0]),$($rb[1])' 交叠 ${ox}x${oy}"
    }
  }
}
"5b) 重叠检查完成（$($all.Count) 个控件两两比对）"

# 用户给的原话是「取消按钮上面的大部分位置都是空的」。机械化的说法：
# 按钮横着压过去，必须有一半以上落在某一行的标签文字上（标签是唯一确定会画墨的地方，
# 勾选框只有控件矩形左侧那一枚方框）。旧版这里 0% —— 按钮整个压在勾选框矩形右侧
# 那 77 px 的透明区上。
foreach ($b in $btns) {
  $r = [U32]::Rect($b)
  $bw = $r[2] - $r[0]
  # union of label x-intervals overlapping this button (labels share the same column)
  $cov = 0
  foreach ($s in $labels) {
    $sr = [U32]::Rect($s)
    $ox = [math]::Min($r[2], $sr[2]) - [math]::Max($r[0], $sr[0])
    if ($ox -gt $cov) { $cov = $ox }
  }
  $pct = [math]::Round(100.0 * $cov / $bw)
  "5d) 按钮「$([U32]::Text($b))」$($r[0])..$($r[2]) 与标签列最大横向重叠 $cov px（$pct% 宽）"
  if ($pct -lt 50) {
    $fails += "按钮「$([U32]::Text($b))」上方 $pct% 有字，其余是空白（判据：重叠须 ≥50% 按钮宽）"
  }
}

$tab = $null
foreach ($b in $checks) { if ($labelOf[$b.ToInt64()] -eq "文档以标签页打开（需重启）") { $tab = $b; break } }
if (-not $tab) { $fails += "找不到 UseTabs 勾选框（标签文案没带「需重启」？）" }

$before = ReadKey "UseTabs"
"6) 改前 $before"
$s0 = [U32]::SendMessageW($tab, $BM_GETCHECK, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()
[void][U32]::SendMessageW($tab, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Milliseconds 400
$s1 = [U32]::SendMessageW($tab, $BM_GETCHECK, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()
"7) 点击勾选框 $s0 -> $s1"
if ($s0 -eq $s1) { $fails += "勾选框没响应点击" }

$ok = $btns | Where-Object { [U32]::Text($_) -eq "确定" } | Select-Object -First 1
if (-not $ok) { $fails += "找不到确定按钮" } else {
  [void][U32]::SendMessageW($ok, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
}
Start-Sleep -Seconds 2
$after = ReadKey "UseTabs"
"8) 改后 $after"
if ($before -eq $after) { $fails += "值没写进文件" }
$still = [U32]::Top($p.Id) | Where-Object { [U32]::Text($_) -like "*选项*" }
if ($still) { $fails += "点确定后页面没关" }

# cancel must not write: flip again then cancel
[void][U32]::PostMessageW($main, $WM_COMMAND, [IntPtr]319, [IntPtr]::Zero)
Start-Sleep -Seconds 2
$dlg2 = [U32]::Top($p.Id) | Where-Object { [U32]::Text($_) -like "*选项*" } | Select-Object -First 1
if ($dlg2) {
  $k2 = [U32]::Children($dlg2)
  $c2 = @($k2 | Where-Object { [U32]::Class($_) -eq "Button" -and [U32]::Text($_) -eq "" })
  $t2 = $null
  $lab2 = @($k2 | Where-Object { [U32]::Class($_) -eq "Static" -and [U32]::Text($_) -ne "" })
  foreach ($b in $c2) { if ((Get-LabelFor $b $lab2) -eq "文档以标签页打开（需重启）") { $t2 = $b; break } }
  if ($t2) { [void][U32]::SendMessageW($t2, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero) }
  $cancel = @($k2 | Where-Object { [U32]::Class($_) -eq "Button" -and [U32]::Text($_) -eq "取消" }) | Select-Object -First 1
  [void][U32]::SendMessageW($cancel, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
  Start-Sleep -Seconds 2
  $afterCancel = ReadKey "UseTabs"
  "9) 取消后 $afterCancel（应与第 8 步相同）"
  if ($afterCancel -ne $after) { $fails += "取消却写了盘" }
}

# 更新检查必须整体关掉：默认值 checkForUpdates=false 只封自动路径，ShouldCheckForUpdate()
# 对 UserInitiated 直接放行，而 CmdCheckUpdate=323 在菜单和命令面板里都有。
# 断言的是这轮插入的那行日志——它在全仓只有一处来源，代码删掉就打不出来。
[void][U32]::PostMessageW($main, $WM_COMMAND, [IntPtr]323, [IntPtr]::Zero)
Start-Sleep -Seconds 2
$uc = Select-String -Path $log -Pattern "StartAsyncUpdateCheck: disabled in this fork" | Select-Object -First 1
if ($uc) { "9b) 手动检查更新已被拦下: $($uc.Line.Trim())" } else { $fails += "点了检查更新却没拦下（日志里没有 disabled in this fork）" }
if (Select-String -Path $log -Pattern "update-check-rel|Checking for update" | Select-Object -First 1) {
  $fails += "日志里出现官方更新检查的痕迹，说明网络路径没封住"
}
[void][U32]::PostMessageW($main, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Seconds 3
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; "10) 主窗口未自行退出（已强制结束）" } else { "10) 程序正常退出" }

""
if ($fails.Count) { "RESULT: FAIL"; $fails | ForEach-Object { "  - $_" }; exit 1 }
"RESULT: PASS"
