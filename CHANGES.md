# CHANGES · 我们对 SumatraPDF 3.6.1 的全部修改

基线：GitHub tag `3.6.1rel`（commit `16c59fde8`），`CURR_VERSION 3.6.1`。
基线快照的 git tree：`0899981cbf84be2f59999e370f86c737f2d3565f`（见 `.plan/baseline-tree.txt`）。
对账：`git diff 0899981c -- .`（基线 commit 补上后）或 `diff -rq ../.3rd/sumatrapdf-3.6.1rel .`

规则：一处偏离一条。**坐标写符号名，不写行号**（行号会随注释漂移，且没有门禁读它）。每条都要能单独撤销。

---

## 一、CAJ 支持（目标 B）

### 1. `ext/unrar/cmddata.cpp` 的源码码页（构建修复，非功能）

- 文件：`vs2022/unrar.vcxproj`，`ClCompile Include="..\ext\unrar\cmddata.cpp"` 那一项
- 原：自闭合项，无编译选项 → 现：加 `/source-charset:.1252`
- 为什么：那行 `//` 注释以字节 `0xFE` 结尾。项目不设 charset 旗标，cl.exe 按系统 ANSI 码页读源码；中文系统 CP936 下 `0xFE` 是合法双字节首字节，吞掉换行，把下一行 `uint Flags;` 并进注释 ⇒ `error C2065`。上游 CI 是 CP1252，复现不了。
- 证据：改前单编 unrar rc=1 + 1×C2065 + 1×C4819；改后 rc=0、**0 C4819**、出 `unrar.lib`。
- 撤销：改回自闭合项。

### 2. 新增 vendored Rust 解码库（新文件，不进 diff 面）

- 目录：`ext/cajshim/`（`Cargo.toml` / `Cargo.lock` / `src/lib.rs`），依赖 crates.io 的 `caj2pdf-core 0.8.1`（**MIT**）
- 导出 3 个 `extern "C"`：`caj_convert_file(src,dst)`、`caj_last_error(buf,len)`、`caj_shim_version()`
- 边界纪律：Rust 分配的一律 Rust 释放；C++ 只传路径与调用方自有缓冲；每个入口 `catch_unwind` 包住（MuPDF 用 `setjmp`，异常不得越过边界）
- 构建：`cmd/build-cajshim.ts` 跑 `cargo build --release --locked --target-dir out/cajshim`，并设 `RUSTFLAGS=-C target-feature=+crt-static`
  - **必须 crt-static**：SumatraPDF 是 `/MT`（`premake5.lua` 的 `staticruntime "On"`），Rust 默认动态 CRT，混用会两堆两状态。
  - 撤销：删 `ext/cajshim/` 与 `cmd/build-cajshim.ts`。

### 3. `src/EngineCaj.cpp`（新文件，主要实现）

- `IsEngineCajSupportedFileType(kind)` / `CreateEngineCajFromFile(path, pwdUI)`，声明在 `EngineAll.h`
- 流程：算规范化键 → 查 `caj-cache\index.txt` → 未命中就进程内转换 → **把缓存 PDF 交给 `CreateEngineMupdfFromFile(pdfPath, kindFilePDF, dpi, pwdUI)` 并返回那个引擎**
- 关键设计：返回的是真的 EngineMupdf（`engine->kind == kindEngineMupdf`），所以书签/搜索/缩略图/批注/打印/暗色全部按 PDF 白拿，我们不实现 `EngineBase` 的 31 个纯虚。

**缓存布局**（全在 `GetPathInAppDataDirTemp("caj-cache")` 下，便携时即 exe 同级）：

```
caj-cache\index.txt                     缓存名 ⇥ 规范化源路径 ⇥ 源大小 ⇥ 源mtime ⇥ lastUse
caj-cache\<原文件名>.pdf                 名字就是源文件换后缀；撞名追加 __2 / __3
```

- **键 = `path::NormalizeTemp` 后经 WCHAR 大写的路径**。规范化会折叠 8.3 短名与 `..`；大写是因为 Windows 路径大小写不敏感。实测同一份 caj 用 4 种拼法（规范全路径 / 小写盘符 / 8.3 短名 / 含 `..`）只产生 **1 份缓存、1 行索引、1 次转换**。
  - ⚠️ 折叠必须走 `CharUpperBuffW`。先用 `CharUpperBuffA` 时它按 GBK 把 UTF-8 中文路径的字节当双字节首字节改写，索引里存成 `…的影?CAJj`。去重当时仍然“通过”纯属损坏是确定性的——所以补了一条断言：索引里的键必须等于 `normpath(源).upper()`，不含 U+FFFD。
- **消歧用 `__2` 不用 `~2`**：`~` 会让 `GetFullPathNameW` 对缓存文件做 8.3 短名展开。
- **`lastUse` 自己记**，不用文件访问时间：Win10+ 系统盘默认不更新 atime，拿它判龄会把天天读的那篇当垃圾清掉。
- 清理：每进程一次，删 `lastUse` 超 `kCajCacheMaxAgeDays`(=30) 的条目及其文件，并删索引里已无条目的**超龄孤儿** pdf。索引损坏/缺行 ⇒ 当未命中处理，**不许因为索引坏了就打不开文件**（实测 T3 通过）。
- 转换失败当场删除半成品并回滚该索引行。

**过程中修掉的两个自身缺陷**（都有栈/输出为证）：

1. `str::Str::LendData()` 是「借出」不是「交出所有权」，我对它调了 `str::Free` ⇒ `SaveIndex` 里双重释放，打开同名第二个文件时直接崩溃（栈顶 `_free_base ← SaveIndex ← CreateEngineCajFromFile`）。改用 `AsByteSlice()`，根本不经手所有权。
2. 定义了 `FreeEntries()` 却没调用，`/W4 + TreatWarningAsError` 下 C4505 直接编不过 ⇒ 删掉死代码。

- 副作用（已知且接受）：`ctrl->GetFilePath()` 是缓存 PDF ⇒ 批注与另存为写进缓存 PDF，**绝不会把 PDF 写回 `.caj`**；代价是资源管理器监视的是缓存文件，外部改 `.caj` 不触发自动重载（重开会因 mtime 变了而重转）。另存为默认名现在就是 `原文件名.pdf`。
- 撤销：删该文件并回退下面 4-6 各条。

### 4-6. 三处上游文件的最小接入

| 文件 | 符号 | 改动 |
| --- | --- | --- |
| `src/utils/GuessFileType.h` | `kindFileCaj` | 加 `extern Kind kindFileCaj;` |
| `src/utils/GuessFileType.cpp` | `kindFileCaj`、`DEF_EXT_KIND`、`FILE_SIGS` | 定义 `Kind kindFileCaj = "fileCaj";`；扩展名表加 `V(".caj", kindFileCaj)`；魔数表加 `V(0, "CAJ\x00", kindFileCaj)`。**扩展名与内容两条轨都要落**：样本文件名是 `.caj` 而内部记录名是 `.NH`。签名必须写 `"CAJ\x00"`（宏按 `sizeof(SIG)-1` 取长，写 `"CAJ"` 只匹配 3 字节） |
| `src/EngineCreate.cpp` | `IsSupportedFileType`、`CreateEngineForKind` | 各加一条 `IsEngineCajSupportedFileType` 分支 |
| `src/SumatraPDF.cpp` | `GetFileFilterTemp` 的 `fileFormats[]` | 在 DjVu 后加 `{_TRA("CAJ documents"), "*.caj", true}`，用 `#ifdef ENABLE_CAJ` 包 |
| `src/RegistryInstaller.cpp` | `gSupportedExts` | 末尾追加 `.caj\0` |

### 7. 工程文件接线（`vs2022/SumatraPDF.vcxproj`）

- `Release\|x64` 与 `Debug\|x64` 两组：`ENABLE_CAJ` 预处理器定义、`cajshim.lib;ntdll.lib` 依赖、`..\out\cajshim\release` 库目录
- `ClCompile Include="..\src\EngineCaj.cpp"`
- `ntdll.lib` 是必须的：Rust std 在 Windows 上用 `NtReadFile`/`NtWriteFile` 做文件 IO，MSVC 工程默认不链 ntdll
- 只有 x64 定义 `ENABLE_CAJ`；其它架构走文件末尾的 no-op 分支
- `premake5.files.lua` 的 `sumatra_files()` 里也登记了 `"EngineCaj.*"`，但**我们的流程不跑 premake**（见第 1 条的教训）

---

## 二、便携形态：实测后**不改代码**

`IsRunningInPortableMode()` / `GetAppDataDirTemp()`（`src/AppTools.cpp`）实测够用：`HasBeenInstalled()` 只有当注册表 `Uninstall\SumatraPDF` 的 `InstallLocation` 解析出来与我们同一个文件才算「已安装」，所以放任意目录的副本必然走便携，配置与缓存落在 exe 同级。实测：从空的 `.build/` 目录运行，只生成 `SumatraPDF-settings.txt` 与 `caj-cache\`。

保留的上游例外（认为合理）：exe 在 Program Files 或同级不可写时回退 `%LOCALAPPDATA%`。⇒ 落地为回归断言（m06），不是一行偏离。

---

## 三、便携首启默认值（`src/Settings.h` 两行）

`src/Settings.h` 的 `gGlobalPrefsFields[]` 里两个 `SettingType::Bool` 的默认值由 `true` 改为 `false`：

| 字段 | 行内符号 | 为什么改 |
| --- | --- | --- |
| `checkForUpdates` | `offsetof(GlobalPrefs, checkForUpdates)` | `src/UpdateCheck.cpp:43-48` 写死了 `https://www.sumatrapdfreader.org/update-check-rel.txt` 与官方 `Installer64/32` 地址。我们这个改版若开着它，会提示用户**下载官方版覆盖自己**，CAJ 与设置全没。这不是偏好问题，是正确性问题 |
| `restoreSession` | `offsetof(GlobalPrefs, restoreSession)` | 用户实测抱怨：退出再开「一口气自动打开若干文件」。便携查看器首启不该恢复上次会话 |

- 两项都**仍可用户在 `SumatraPDF-settings.txt` 里改回**，我们只是换默认值，不是锁死。
- ⚠️ **`src/Settings.h` 是 `cmd/gen-settings.ts` 的生成物**。2026-10-30 实测该生成器在本机跑不通：`cmd/util.ts:74 findVsRoot()` 抛 `couldn't find Visual Studio installation`（本机是装在 `D:\ruanjian\msvc-build-tools` 的 Build Tools），且失败前已往 `Settings.h` 写进 642 行空行差异。所以走的是**手改生成物**这条路，并当场把文件还原过（`git diff` 回到 9 文件 +31/−9 才继续）。⇒ 若哪天修好了生成器并重新生成，这两行必须重新施加，和 `unrar.vcxproj` 那条同属一类风险，m06 门禁要断言。
- 撤销：把这两个 `false` 改回 `true`。

---

## 四、选项设置页（目标 A）

### 12. `src/SettingsPage.cpp` / `src/SettingsPage.h`（新文件，主要实现）

- `ShowSettingsPageDialog(HWND parent)`：**单页单栏，9 项设置**，不碰 `.rc`、不碰 `resource.h`。当前清单以 `SettingsPage.cpp` 的 `gDescs[]` 为准，收窄过程见 12e / 12f。
- 范围砍过三轮：59 → 20 → 11 → **9**。判据是 12e 那条（菜单/工具栏/鼠标已能改的一律不放）。**颜色、电子书、漫画、CHM、批注、TeX、DPI、主题、菜单/工具栏开关全部不做**。
- 每行 `{ INI 字段名, 显示名, 控件类型, 生效方式 }`；需重启的项把「（需重启）」直接烘进标签，不搞 toast。控件类型现只有 `Check`/`Edit` 两种（`Combo` 随下拉项一起删了）。
- **字段按 INI 名字查，不按 `offsetof`**：`FindField()` 让名字串与 `fields[]` 同步前进（注释行名字是空串，必须成对走）。上游换顺序不会让控件指错值。
- 只在值真变了时写 `gGlobalPrefs` 并置 dirty，确定后调既有 `SaveSettings()`；取消一个字节都不写（已测）。

### 12b. 上一版被否掉的三个 UI 缺陷（都已修，且都有成因）

| 症状 | 根因 | 修法 |
| --- | --- | --- |
| 底部按钮看不见、窗口高度不对 | 窗口尺寸按 `DpiScale(parent, 562×486)` 给的是**外框**，控件却按**客户区**坐标摆 ⇒ 最后一行和按钮掉到可视区外 | 先算客户区，再用 `AdjustWindowRectEx` 反推外框尺寸 |
| 背景一片脏、看着没刷新 | `WM_CTLCOLORSTATIC` 返回了 `NULL_BRUSH` ⇒ 静态文字不擦底，露出上一批像素 | 返回 `GetSysColorBrush(COLOR_BTNFACE)`，并处理 `WM_ERASEBKGND`、注册类设 `hbrBackground` |
| 换分组后下面一堆不变 | 重建子窗口后没 `InvalidateRect` | 已加；且这轮**直接取消分组切换**，从源头去掉这条路径 |

### 12d. 标签文字被遮（用户第二轮反馈）：改成按字体量取列宽

上一版把标签列写死 `kLabelDx = 168` 像素。实测最长标签「每个文档记住阅读状态（需重启）」用应用字体量出来是 **180 像素**，**差 12 像素**，而 `SS_LEFTNOWORDWRAP` 的行为就是直接裁掉 —— 所以不是「窗口不够宽」的观感问题，是写死像素必然错。

现在 `ComputeLayout()` 用 `GetAppFont()` + `GetTextExtentPoint32W` 现场量：列宽 = 最长标签 + 6 像素内边距；控件列宽 = 最宽的下拉候选项 + 箭头按钮宽度；行高 = 字体行高 + 内边距。窗口再按客户区经 `AdjustWindowRectEx` 反推外框。

实测读数（程序自己打进日志，`SettingsPage: measured` 一行，验证脚本会断言它存在）：
`labelDx=186 ctrlDx=151 rowDy=27 colDx=365 client=726x330`，窗口外框从 660×359 变 **742×369**。

留了那行 logf 是有意的：量错字体（比如忘了 `SelectObject`）不会报错，只会表现为「文字又被裁了」，有读数才能一眼看出是 0 还是 180。

代价：以后加更长的标签不需要改任何布局数字，自动变宽。

### 12e. 入选判据（第三轮收窄，20 项 → 11 项）

用户给的规则是「**菜单里已经能改的，不要放进度页**」。这条不是印象判断，是查了命令表和菜单结构得出的：

| 被删的项 | 它在菜单里的入口 |
| --- | --- |
| `Theme` | 设置 → 主题（`CmdSetTheme` / `CmdSelectNextTheme`） |
| `ShowMenubar` | `CmdToggleMenuBar` |
| `ShowToolbar` | 查看 → 工具栏（`CmdToggleToolbar`） |
| `UiLanguage` | 设置 → 更改语言（`CmdChangeLanguage`） |
| `DefaultDisplayMode` | 查看 → 单页/双页/书签视图（`CmdSinglePageView` 等） |
| `SidebarDx` | 鼠标直接拖侧栏边界 |
| `ShowStartPage` / `ShowToc` / `DefaultZoom` / `CheckForUpdates` | 语义与保留项重叠或价值低，按「挑重要的」删掉 |

反过来，留下的 **11 项在 `Commands.h` 里找不到任何对应命令**，只能改 INI：`UseTabs`、`RestoreSession`、`RememberOpenedFiles`、`ReuseInstance`、`FullPathInTitle`、`ToolbarSize`、`SmoothScroll`、`EscToExit`、`RememberStatePerDocument`、`ReloadModifiedDocuments`、`LazyLoading`。

⇒ **以后往这页加东西，先回答一句：菜单/工具栏/鼠标操作里有没有入口。有就不加。**

页面因此从 742×369 缩到 **620×261**（10 个勾选框 + 1 个编辑框，24 个控件零重叠，按钮在可视区内，改一项存盘只变那一行、取消不写盘 —— 全部实测 PASS）。**这 11 项在下一轮又被删掉 2 项、布局从两栏改成单栏，见 12f。**

顺带把验证脚本里写死的「标签数 == 20」改成结构断言（`标签数 == 勾选框+编辑框+下拉`），否则每次改表都要跟着改测试。

### 12f. 第四轮：11 项 → 9 项，两栏改单栏（2026-10-30）

用户点名删两项：`ToolbarSize`（工具栏图标高度）、`EscToExit`（Esc 退出程序）。剩下 9 项全是勾选框，于是布局同时改成**一列**——9 行分两栏必然出现一栏 5 行一栏 4 行的参差，而单栏把窗口宽度交给「最宽标签 + 控件」这一条，反而更窄。

代码面（只动 `SettingsPage.cpp`，`.rc`/`resource.h` 仍零改动）：

- `PageLayout` 删掉 `colGap`/`colDx`/`rowsPerCol` 三个字段，`LabelRowsPerPage()` 整个删除；行坐标变成 `x = margin`、`y = margin + i * rowDy`，控件 x 为 `margin + labelDx + margin`。
- `CtlKind` 从 `{Check, Edit, Combo}` 收成 `{Check, Edit}`，`SettingDesc::comboItems` 与 `kDisplayModes`/`kThemes`/`kZooms` 三张候选表一起删。**留着 `Edit` 分支**：加一项 `Int`/`String` 设置的成本仍是一行 descriptor，删了它就得重新写回来。
- 窗口 620×261 → **328×342**（实测外框读数）。

这轮 9 项：`UseTabs`、`RestoreSession`、`RememberOpenedFiles`、`ReuseInstance`、`FullPathInTitle`、`SmoothScroll`、`RememberStatePerDocument`、`ReloadModifiedDocuments`、`LazyLoading`。

实测（`.plan/tools/verify-settings-page.ps1`，PASS）：9 标签 / 9 勾选框 / 0 编辑框 / 2 按钮；20 个控件两两零重叠；最底控件底边 667 ≤ 窗口底边 687；`measured labelDx=186` 与「标签控件最大宽 186」两个读数相等 ⇒ 没有文字被截；改 UseTabs → 确定 → 只有那一行变化，取消 → 文件不动。

**顺手修的却是脚本自己的缺陷**：打印窗口尺寸那行写成 `$(($dr[2]-$dr[0]))x(($dr[3]-$dr[1]))`，PowerShell 把 `$dr[3]-$dr[1]` 当成变量减法的切片解析，输出的是表达式原文而不是数字 —— 高度那一格从来没读到过。改成先赋 `$dlgW`/`dlgH` 再插值。**读数量具自己把读数吐成乱码，比产品出错更危险**：它看起来是绿的。

门禁 `check-settings-descriptors.py` 也跟着改了：它原先自己列一份「Check/Combo/Edit 各允许什么字段类型」，产品删掉 `Combo` 之后两边就分叉了 —— 有人写一行 `CtlKind::Combo` 会过门禁、到编译才炸。现在白名单从产品的 `enum class CtlKind` 现场解析，锚点找不到就直接 FAIL。三枚实弹红证（临时把一行写成 `CtlKind::Combo` / 把 `SmoothScroll`（Bool）配成 `Edit` / 删掉 enum 声明）分别翻出「产品代码里不存在」「控件是 Edit，字段却是 Bool」「cannot parse 'enum class CtlKind'」，每次还原后与快照 md5 相同。

### 12g. 按钮上方那片空白（12f 之后的第五轮，2026-10-30）

用户验收：「取消按钮上面的大部分位置都是空的，建议两个按钮向左移动一点」。

**没按字面做**（把按钮坐标往左挪一个魔数），因为空白不是按钮摆错了，是**控件列被量宽了**：`ctrlDx` 当时对所有控件类型统一给 90 px，那是给编辑框/下拉框准备的需求，而这一页现在 9 项全是勾选框 —— 无标题的 `BS_AUTOCHECKBOX` 只画左侧一枚方框（100% DPI 下约 13 px），右侧 **77 px 是完全透明的**。按钮按窗口右缘对齐，于是整个压在透明区上，看上去就是「头顶一片空」。改坐标只会把空白挪到别处，窗口照样宽 312。

修法（仍只在 `SettingsPage.cpp`）：新增 `CtrlDxForKind()`，控件列宽改成**按表里在用的控件类型取最大值**：`Check → DpiScale(24)`，`Edit → DpiScale(90)`，`ComputeLayout` 里与标签宽同一次遍历求出。于是 `clientDx` 从 312 → **246**（窗口 328×342 → **262×342**），右对齐的两个按钮自动左移 66 px，正好落到内容列右缘 —— 没有为按钮单独写任何新坐标。

**判据先于修改立好**（`verify-settings-page.ps1` 新增 5d）：把「上方是空的」翻译成像素 —— 每个按钮的横向区间与标签列的最大重叠须 ≥ 50% 按钮宽（标签是唯一确定画墨的地方，勾选框那一枚方框不算）。拿**还没重编译的旧 exe** 跑新判据：`取消 0%`、`确定 93%` —— 一条红一条不红，说明这格真有分辨力（只有「取消」被误判的话就写宽了）。改完再跑：`取消 59%`、`确定 100%`，PASS。

### 12c. 验证

`.plan/tools/verify-settings-page.ps1`（起真程序、真点、真存盘）现在断言四件事，全 PASS：

- 结构断言 `标签数 == 勾选框 + 编辑框 + 下拉`（当前读数：9 = 9 + 0 + 0，另有 2 个按钮），另断言标签数不少于 8，防止表被删坏；
- **控件两两矩形零重叠**（当前 20 个控件；这条是「不丑」的可机检替身）；
- 最底控件底边 ≤ 窗口底边（当前 667 ≤ 687），按钮不被裁；
- 日志里必须有 `SettingsPage: measured` 那行，且 `labelDx` 读数与脚本自己量到的「标签控件最大宽」相等 —— 字体没被选中时产品不报错，只表现为屏幕上的截字；
- 按钮横向压过标签列的重叠 ≥50% 按钮宽（12g，「按钮上方是空白」的像素化判据）；
- 点 UseTabs → 确定 → 配置文件里只有那一行变了；再点一次 → 取消 → 文件不动。

配对标签与控件时踩过一次坑：**当时是两栏布局**，只按 y 最近匹配会抓到邻栏的标签（表现是 5 个勾选框配到同一个标签）。改成「同一行内取最靠右且整体在控件左侧的标签」。**注意这是验证脚本的缺陷，不是产品的** —— 重叠检查当时就是绿的。12f 改单栏之后只按 y 匹配不会再跨栏串味，但这条更严的规则留着，它对任何栏数都成立。

### 13. 三处上游文件的最小接入（都是本来就在改的那三个）

| 文件 | 改动 |
| --- | --- |
| `src/SumatraPDF.cpp` | 加 `#include "SettingsPage.h"`；`ShowOptionsDialog` 里把 `Dialog_Settings(hwnd, gGlobalPrefs)` 换成 `ShowSettingsPageDialog(hwnd)`（**一行**，原版 `Dialog_Settings` 完整保留可回退） |
| `vs2022/SumatraPDF.vcxproj` | `ClInclude SettingsPage.h` + `ClCompile SettingsPage.cpp`，且该 `.cpp` 单独加 `/utf-8` |
| `premake5.files.lua` | `sumatra_files()` 加 `"SettingsPage.*"`（同前：我们不跑 premake） |

### 14. ⚠️ 这个文件必须带 `/utf-8`，否则中文标签编译失败

`SettingsPage.cpp` 含大量中文字面量。上游所有源文件都是 **CRLF 无 BOM 且不含真非 ASCII 文本**，所以从没遇到过这事：

- cl.exe 无 BOM 时按系统 ANSI 码页（本机 CP936）读源码 ⇒ 中文 UTF-8 序列被误判，报 `C2001 常量中有换行符`、`C3872 '0x3002' 不允许在标识符中使用`（0x3002 是中文句号「。」）。
- **只加 BOM 不够**：那修好的是源码字符集，执行字符集仍是 GBK，窄字符串会被转成 GBK 字节，而我们要交给按 UTF-8 解释的 `ToWStrTemp` ⇒ 界面显示乱码。所以必须 `/utf-8`（= source + execution 都 UTF-8）。
- 撤销：删掉那行 `AdditionalOptions`，同时把文件里的中文换成英文。

### 15. 其它踩过的坑（同文件内）

- `FieldInfo` / `StructInfo` / `SettingType` 定义在 `utils/SettingsUtil.h`，而 `Settings.h` **不引入它**（`GlobalPrefs.cpp` 自己引的）⇒ 必须显式包含。
- 那张表还包在 `#ifdef INCLUDE_SETTINGSSTRUCTS_METADATA`（`Settings.h:528-873`）里 ⇒ 用之前要 `#define` 它，跟 `GlobalPrefs.cpp:10` 一样。
- 可增长的字符串是 `str::Str`（`AppendFmt` / `AsByteSlice` / `StealData`），**不是**全局那个 `Str`；`LendData()` 是借出不是交出所有权（在 m08 里已经因此崩过一次）。
- 数字解析用 `ParseInt(s)` 和 `str::Parse(s, "%f", &v)`，没有 `str::ToInt` / `str::ToFloat`。

### 16. 验证方式（两份，都在 `.plan/tools/`）

- **文本门禁** `check-settings-descriptors.py`：解析 `Settings.h` 的名字串与字段表，逐行核对 descriptor 的名字存在、类型与控件匹配。**一秒，不需要编译**。它第一跑就翻红抓到 `GradientColors` 其实是 `ColorArray`（数组不进页面，已删）。
- **端到端** `verify-settings-page.ps1`：见 12c。
- 挂 `SumatraUnitTests.cpp` 这条路**已回退**：那个文件同时属于 `test_util.exe`，它不链 `SettingsPage.cpp`，会 LNK2001。文本门禁覆盖了同样的检查且更便宜。

---

## 五、对外名字与「关于」页署名（目标 A 的收尾，2026-10-30）

用户定的形状：**能看见的地方用新名字，看不见的地方一律保持原样**。可见面三个：文件名、窗口标题、任务管理器里的进程名；署名两行：Author = 邱宗满，Repository = Gitee/GitHub 各一条可点链接。

### 17. 对外名只有两个字面量：`Version.h` 新增 `kAppDisplayName` / `kAppDisplayNameW`

`src/Version.h`（在 `kAppName` 之后新增两行）：

```c
#define kAppDisplayName  "SumatraPDF-Q"
#define kAppDisplayNameW L"SumatraPDF-Q"
```

为什么放 `Version.h` 而不是就地写字面量：任务管理器那一格走的是 `.rc` 里的 `VS_VERSION_INFO`，而 `.rc` 只 include `resource.h` 和 `Version.h` —— 想「一处定义、三处生效」就只能放这儿。**代价要记账：`Version.h` 从此进偏离面（改的上游文件 10 → 12）。**

两条为什么不能合成一条：`TEXT(kAppDisplayName)` 这类宏内部是 `L##x` 记号粘贴，参数是宏名时会粘成 `LkAppDisplayName` 而不是 `L"SumatraPDF-Q"`。所以窄/宽各写一条，接受这一处相邻重复。

### 18. `src/SumatraPDF.cpp:99-100`：标题改用对外名

```c
constexpr const char* kSumatraWindowTitle = kAppDisplayName;      // 原为 "SumatraPDF"
constexpr const WCHAR* kSumatraWindowTitleW = kAppDisplayNameW;   // 原为 L"SumatraPDF"
```

这两个常量只被标题路径用（`:1081`/`:1084` 拼窗口标题、`:1511`、`:2442` `HwndSetText`），**不是**窗口类名、不是注册表键 —— 这是能安全改名的关键事实，逐个 grep 确认过。

### 19. `src/SumatraPDF.rc:47`：`FileDescription` 换成 `kAppDisplayName`，其余四项不动

```
VALUE "FileDescription", kAppDisplayName     // 原 kAppName —— 任务管理器「进程」页读这个
VALUE "ProductName",     kAppName            // 保持 SumatraPDF（内部）
VALUE "LegalCopyright",  kCopyrightStr       // 保持上游 GPLv3 声明，一字不动
VALUE "CompanyName",     kPublisherStr       // 保持 Krzysztof Kowalczyk
```

**为什么非改不可**：Windows 任务管理器的应用行读的是 PE 里的 `FileDescription`，不是文件名。只把文件改名而不改这里，那一格仍显示 `SumatraPDF`。两条路都覆盖，才不必赌系统到底读哪个。`.rc` 顶部有 `#pragma code_page(1252)`，本次改动全 ASCII，无编码风险。

### 20. 文件名：不改构建目标名，发布时改名（`SumatraPDF-Q.exe`）

没有在 `.vcxproj` 里设 `TargetName`。理由是实测过的连带面：`out/rel64/SumatraPDF.exe` 这个名字被 `.plan/tools/verify-settings-page.ps1`、`test-m08-caj-cache.py` 和我们的构建脚本引用，改产出名会把这些一起牵动，而收益为零——用户看到的只有 `.build/` 里那一个文件。

**改名安全性（这条是实测，不是推理）**：便携配置文件名是硬编码字面量 `SumatraPDF-settings.txt`（`src/AppSettings.cpp:81`），不随 exe 名变；`-bench` 用 `SumatraPDF-Q.exe` 跑，日志仍读到 `LoadSettings('...\.build\SumatraPDF-settings.txt')` 且 CAJ 缓存命中。⇒ 换名零副作用。
**已知连带**：`src/PreviewPipe.cpp:42` 用 `GetPathInExeDirTemp("SumatraPDF.exe")` 回找主程序——那是 PdfPreview2.dll 的路径，我们的产品不发布 shell 扩展，所以不触发；若哪天附带预览器，那行必须同步改。

### 21. `src/HomePage.cpp:101-106`：「关于」页加三行

```c
{"author",     "邱宗满", nullptr},
{"repository", "Gitee",  "https://gitee.com/qiuzongman/SumatraPDF-Q"},
{"mirror",     "GitHub", "https://github.com/zongmanqiu/SumatraPDF-Q"},
```

- **`Repository` 为什么是两行**：`AboutLayoutInfoEl` 一行只带一个 `url`（`HomePage.cpp:84-94` 的结构体），所以「两个仓库各自可点」在现有结构下**只能两行**，不改绘制逻辑就不有一格里放两个链接。第二行左标签用 `mirror`（GitHub 确实是自动同步的镜像），避免同一列出现两个 `repository`。
- 上游五行（website/manual/forums/programming/licenses）**文本与 URL 都没动**，只追加。`{"author", ..., nullptr}` 的 `nullptr` 让该行不走链接分支（`:290` `hasUrl = CanAccessDisk() && el->url`）⇒ 不上色不加下划线，正是「作者名」该有的样子（先例是上游自己的 `{"a note", "Pre-release version...", nullptr}`）。
- 尺寸不用手工调：`minRect.dy` 按行数累加（`:373-377`），宽由最左/最右文本量出（`:367`）⇒ 三行自动长高加宽。
- **`HomePage.cpp` 从此必须带 `/utf-8`**：这文件原本是**纯 ASCII**（实测 non-ascii 字节数 0），加了中文就必须给该文件加 `/utf-8`（`vs2022/SumatraPDF.vcxproj` 的 `ClCompile HomePage.cpp` 条目），否则就是 14 号那条坑的重演。写入过程中我自己踩了一次转义层：python 里写 `b'é±'` 这类字节转义被解成码点再按 UTF-8 编码，落盘成了 `c3a9 c282 c2b1…` 的双编码串——当场用字节级替换修回并核对（现在文件里是 `e982b1 e5ae97 e6bba1`，9 个非 ASCII 字节，CRLF 1082、无混合行尾、无 BOM）。
- **这一格当时标为未验证，现已验收**（用户 2026-10-30 目测「很正常」）：关于页右列字体是 **`Arial Black`**、左列是 `Arial`（`src/HomePage.h:8-11`），两者本身都不含中日韩字形，「邱宗满」靠 GDI 的字体链接画出来了。我先前那两次离屏探针不可信（第一版被 P/Invoke 的 ANSI 序列化把中文先 GBK 了一遍；加 `CharSet.Unicode` 后连 SimSun 对照格也读回 0px）——**是量具有问题，不是产品有问题**，选项页能显示也确实不能当作这条路径的证据，最终结论来自像素。

### 22. 本轮的偏离面变化（机器读数）

改的上游文件 **10 → 13**（`diff-vs-baseline.py` 的实名读数，不是估的）：本轮新增 `src/Version.h`、`src/SumatraPDF.rc`、`src/HomePage.cpp` 三个。`vs2022/SumatraPDF.vcxproj` 只是同文件里多了一条 `HomePage.cpp` 的 `/utf-8`，不另计数。新文件仍是 8 个。门禁 `diff-vs-baseline.py` 逐个实名核对并把每个基名要求在本文出现。

## 六、自有版本号、版本历史、禁止与官方通信（2026-10-30）

### 23. 版本号用上游留给重编译器的钩子：`src/Version.h` 的 `VER_QUALIFIER`

```c
#ifndef VER_QUALIFIER
#define VER_QUALIFIER Q1
#endif
```

紧挨在 `CURR_VERSION`/`CURR_VERSION_COMMA` 之后（必须在 `#ifndef PRE_RELEASE_VER` 那段之前，宏是使用点之后才展开不了的）。

- 规则：`3.6.1` 永远指官方基线，`Q1/Q2/...` 是我们在同一基线上反复修改的自有序号 ⇒ 版本串 `3.6.1Q1` 同时回答「切的哪版官方」和「我们改到第几轮」。
- **这是上游明确为改版准备的机制**（`Version.h` 原注释："VER_QUALIFIER allows people who recompile SumatraPDF to add a distinguishing string"），不是我们发明的格式。
- 取值必须是**可直接粘贴的记号**：宏走 `QM2(x, y)` → `_QUOTEME(x##y)`，`##` 之前不展开参数，所以只能贴 `Q1` 这类纯字母数字；写成 `-Q1` 或 `"Q1"` 会得到错误的串。这条约束由门禁 `check-release-version.py` 判。
- **没用 `PRE_RELEASE_VER`**：那条路会把 `UPDATE_CHECK_VER` 改成修订号，并且 `HomePage.cpp` 的条件行会在关于页多出「Pre-release version, for testing only!」——我们不是预发布。
- 数值型 `FILEVERSION`（`VER_RESOURCE = CURR_VERSION_COMMA,0`）保持 `3.6.1.0`：只改字符串那一层。这样任何按数字比较版本的系统仍视其为 3.6.1 家族，代价是 `Q1` 不进数字位——版本号语义放在字符串里，够用。

### 24. `src/UpdateCheck.cpp:620`：更新检查在本改版里整体关掉

`StartAsyncUpdateCheck()` 顶部插一段闸门，**原逻辑一行没删**（纯插入，升级时 diff 干净）：

```c
static bool gAllowOfficialUpdateCheck = false;

void StartAsyncUpdateCheck(MainWindow* win, UpdateCheck updateCheckType) {
    if (!gAllowOfficialUpdateCheck) { ...ShowNotification(...); logf("...: disabled in this fork"); return; }
    ... 上游原样 ...
```

- **为什么默认值 `checkForUpdates = false` 不够**（这是本轮的关键发现）：`ShouldCheckForUpdate()` 里有一句 `if (updateCheckType == UpdateCheck::UserInitiated) return true;`（`:190`）——**手动路径完全绕过 pref**。而 `CmdCheckUpdate = 323` 既在菜单里（`Menu.cpp:533`、`:961`）也在命令面板里（`CommandPalette.cpp:89`），所以只改默认值时，用户点一下仍然会被官方 `update-check-rel.txt`（`UpdateCheck.cpp:46`）喂一个官方包，装下来就把 CAJ 和选项页整个抹掉。⇒ 必须封在 `StartAsyncUpdateCheck` 这个两个调用点共同的入口上。
- **为什么写成变量而不是 `return;`**：直接 `return` 会使其后原代码成为 unreachable code（C4702），本仓警告即错误。变量闸门让语句级常量折叠不发生，原码留在原地。
- 手动触发时给的是**看得见的回答**（复用上游现成的 `ShowNotification` + `NotificationCreateArgs`，同文件 `:626-634` 就是这套写法），不是一个点了没反应的死菜单项。文案是中文 ⇒ **`UpdateCheck.cpp` 从此必须带 `/utf-8`**（已加进 `.vcxproj`）。

### 25. `src/SumatraPDF.cpp:6659`：崩溃报告不再上传官方

```c
bool CrashHandlerCanUseNet() {
    return false;          // 原为 HasPermission(Perm::InternetAccess)
}
```

审「还有哪些路径连官方」时挖出来的：`CrashHandler.cpp:36-38` 把崩溃 POST 到 `www.sumatrapdfreader.org/uploadcrash/sumatrapdf-crashes`，`:438` 还从官方下 PDB。而 `InstallCrashHandler(...)` 在**每个非 ASan 构建**里都装（`SumatraStartup.cpp:2113-2118`）。改这个函数的理由：它是上游自己留的网络总闸（`:428` 已有 `!CrashHandlerCanUseNet()` 的跳过分支与日志），且**这个文件本来就在我们的偏离面里**（不用新增文件）。
**代价要明写**：`SaveCrashInfo(d)` 在 `:447` 位于网络闸门之后，所以关掉网络后那条人类可读的崩溃文本**不再落盘**（`.dmp` 由异常过滤器另行写，仍在）。真要给用户收崩溃报告时，得把 `SaveCrashInfo` 提到闸门之前——那是 `CrashHandler.cpp` 进偏离面的理由，本轮不做。

### 26. 门面文件：`RELEASES.md`（新）与 `readme.md` 顶部 banner

- `RELEASES.md`＝**用户视角**的版本历史（版本号规则、每版做了什么、已知问题、下载与许可）。它和 `CHANGES.md` 不重复：后者是逐文件的偏离账（给维护者/升级用），前者是给下载者看的。
- `readme.md` 顶部加了 fork banner（连同 24 的 `src/UpdateCheck.cpp`，**上游文件 13 → 15**，`diff-vs-baseline.py` 与对 `.3rd` 的 `diff -rq` 两个来源同读数）。理由：Gitee/GitHub 仓库首页渲染的就是 `readme.md`，不改它，访客进来读到的是官方版介绍与官方下载链接。原内容（徽章、官方介绍、官方链接）整体保留在 banner 之下。

### 27. 三处版本号必须有机器判等：`.plan/tools/check-release-version.py`

`src/Version.h` 的 `VER_QUALIFIER`、`RELEASES.md` 最新条目标题、`readme.md` 首行——三处写的是同一个数，以前只靠注释互指。新门禁逐处读出并判等，另断言 `RELEASES.md` 的「版本对应关系」表里有这一行，以及记号形状合法（24/23 那条粘贴约束）。本轮实跑读数：`Version.h : 基线 3.6.1 + 修订 Q1 => 3.6.1Q1`，三处一致。

顺带修了账具自己的一个洞：`diff-vs-baseline.py` 原先把「我们新增的文件」等同于「git 未跟踪」，**提交之后那些文件就不再未跟踪了**，于是新文件清单塌成 1 个、上游改动虚报成 23 个（15 改 + 8 新被混在一起）。现改成按 git 的状态字母分流（`A`＝新增、`M/D`＝改了上游），并把「上次提交之后新建、还没跟踪」的文件从 `git status` 并进来——只靠提交顺序才全的清单，就是一张会静默漏东西的清单。

## 已知未完成（不是缺陷清单，是下一轮的活）
6. ~~关于页「邱宗满」能否出墨~~ **已验收**（用户 2026-10-30 目测：正常）。Arial Black 本身无中日韩字形，实测由 GDI 字体链接画出；我的离屏探针两次不可信，已记入原因，不要再为此改那行字体。

1. 转换失败时用户看到的是通用「不支持」，不是 `caj_last_error` 那句带字节偏移的定位信息。
2. `.kdh` / `.nh` / `.c8` 未注册（上游矩阵里它们是 experimental）。
3. 资源管理器预览/缩略图处理器未做（m03 明确排除；要它就得带 `PdfPreview2.dll` 并注册，与单 exe 冲突）。
4. 选项页按用户 2026-10-30 的决定**收窄到 9 项、单栏**（判据见 12e，最后一轮见 12f），其余（颜色 / 电子书 / 漫画 / CHM / 批注 / TeX / DPI / 主题 / 菜单工具栏开关 / 逐项恢复默认 / `CajCacheCleanup` 档位）**明确不做**，不是待办。
5. 基线 commit 仍欠着（本机 git 未配身份）。

## 已修（从旧「未完成」清单里划掉的）

- **另存为默认名**：m08 把缓存文件名改成「源文件名换后缀」后，`ctrl->GetFilePath()` 就是 `论文.pdf`，另存为默认名自然正确。
- **目标 A 选项设置页**：m04 已落地 59 行 / 9 组，读写与存盘端到端验证通过。
