# SumatraPDF-Q 修改说明（相对官方 SumatraPDF 3.6.1）



这份文件回答一个问题：**我们到底动了官方代码的哪些地方**——逐文件清单、每处的目的、

以及官方更新时该怎么跟进。工程细节与实测读数在 [CHANGES.md](CHANGES.md)，

用户视角的版本历史在 [HISTORY.md](HISTORY.md)。



一句话原则：**只做两件事（CAJ 直开、选项页），改动面越小越好，且每一处都能单独撤销。**

本清单与 `git diff` 的实际结果由门禁 `tools/diff-vs-baseline.py` 双向核对

（清单里不许漏文件，也不许留下已经不存在的文件）。



---



## 改动的上游文件（19 个）

> 下表与门禁输出里的路径都是**基线相对路径**；在仓库里它们位于 `upstream/` 下
> （m13b 起，整个上游树收进 `upstream/`；我们的文档与 `tools/` 门禁在仓库根目录）。



| 文件 | 改了什么 | 属于 |

| --- | --- | --- |

| `src/utils/GuessFileType.h`、`src/utils/GuessFileType.cpp` | 新增 `kindFileCaj`；扩展名表加 `.caj`，签名表加 `CAJ\0` 魔数 | CAJ |

| `src/EngineAll.h` | 4 个 CAJ 相关函数声明（是否支持该类型、创建引擎等） | CAJ |

| `src/EngineCreate.cpp` | 两处分支：识别到 CAJ 类型、以及为它创建引擎 | CAJ |

| `src/Settings.h` | 默认值改动 **+ 一个新增配置项**：`checkForUpdates`/`restoreSession` 仍由 true 改 false；另新增 `cajCacheMaxAgeDays` 字段与其 `Int` 元数据（默认 7），驱动「CAJ 缓存清理」下拉 | 便携 / CAJ |

| `src/RegistryInstaller.cpp` | 文件关联的支持列表加 `.caj` | CAJ |

| `vs2022/SumatraPDF.vcxproj` | `ENABLE_CAJ` 宏、`cajshim.lib;ntdll.lib` 与库目录（仅 x64）；新加的 `.cpp` 条目；三个含中文的文件各自带 `/utf-8` | 构建 |

| `vs2022/unrar.vcxproj` | `cmddata.cpp` 单文件 `/source-charset:.1252`——在中文码页（GBK）机器上，那个文件行尾的一字节会让下一行被吞进注释里，官方源码在本机直接编不过 | 构建 |

| `premake5.files.lua` | 源文件列表加 `EngineCaj.*`、`SettingsPage.*` | 构建 |

| `src/SumatraPDF.cpp` | ① 选项页入口：一行把 `Dialog_Settings(...)` 换成 `ShowSettingsPageDialog(...)`（原版实现完整保留可回退）；② `CrashHandlerCanUseNet()` 返回 false（崩溃报告不再上传官方）；③ 两个窗口标题常量改用对外名 | 选项页 / 改版必要 |

| `src/UpdateCheck.cpp` | `StartAsyncUpdateCheck()` 顶部加总闸：本改版不检查官方更新（手动路径原本绕过 pref，只改默认值封不住）。**原逻辑一行未删** | 改版必要 |

| `src/Version.h` | 新增 `kAppDisplayName` / `kAppDisplayNameW`（对外可见名）；新增 `VER_QUALIFIER`（自有版本号，当前 Q2） | 署名 / 版本 |

| `src/SumatraPDF.rc` | `FileDescription` 用对外名（任务管理器读这一格）；`ProductName`、`LegalCopyright`、`CompanyName` **保持上游原样** | 署名 |

| `src/HomePage.cpp` | 「帮助 → 关于」的静态表里追加三行：`author` 邱宗满、`repository` Gitee、`mirror` GitHub。上游五行文本与链接一字未动 | 署名 |

| `src/Caption.h`、`src/Caption.cpp` | 新增 `GetCaptionBand()`：标题栏带子的位置与高度改问 DWM（`DWMWA_CAPTION_BUTTON_BOUNDS`），标签条在带内由贴底改为居中 ⇒ 修「多标签时标签比右侧按钮低 11px」 | 外观 |
| `readme.md` | 整篇换成改版说明（做什么、仓库与下载地址、许可、关于官方原版）；官方链接与作者归属保留在最后一节 | 门面 |
| `.gitignore` | 排除 `out/`（含 cajshim 的 Rust 静态库，约 1.9 GB）；布局收拢轮新增，排除规则任意深度生效 | 构建 |
| `vs2022/SumatraPDF-dll.vcxproj` | 与 `SumatraPDF.vcxproj` 同因：含中文的源文件各自带 `/utf-8`，否则 GBK 码页下中文串乱码；dll 工程此前漏补 | 构建 |



## 我们新增的文件（12 个，全部不碰官方同名文件）



| 文件 | 作用 |

| --- | --- |

| `src/EngineCaj.cpp` | CAJ 的核心：规范化缓存键、产物命名、`index.txt` 清单、过期回收、调用转换、把产物交给 MuPDF 引擎 |

| `src/SettingsPage.cpp` / `.h` | 选项页：descriptor 表驱动生成控件，字段按 INI 名字查 `StructInfo` 名字表（不写 `offsetof`） |

| `ext/cajshim/Cargo.toml` / `Cargo.lock` / `src/lib.rs` | Rust 侧薄封装：把 `caj2pdf-core` 编成 staticlib，导出三个 `extern "C"` 函数；每个入口都在 `catch_unwind` 里，Rust 分配的内存不跨过边界；`Cargo.lock` 锁定依赖版本 |

| `cmd/build-cajshim.ts` | 单独一步编 Rust 静态库（`RUSTFLAGS=-C target-feature=+crt-static`，与 C++ 侧 `/MT` 对齐） |

| `CHANGES.md` / `HISTORY.md` / `readme` 之外的本文 | 偏离账、版本历史、修改说明 |

| `tools/` | `baseline-tree.txt` 基线 tree 快照 + 7 枚核对门禁（脚本自定位仓库根，不含本机路径）；三份文档在仓库根目录 | 门禁 |

| `LICENSE` / `LICENSE.MuPDF` | GPLv3 全文与 MuPDF 的 AGPLv3 全文，分别与 `upstream/COPYING`、`upstream/mupdf/COPYING` 逐字一致（`tools/diff-vs-baseline.py` 3b 查等；`.build/` 发行夹随 exe 附两份 + README.md） | 许可 |



## 官方更新时怎么跟进



1. 先看偏离面：`git diff --name-status <基线tree>`，或跑 `fork/tools/diff-vs-baseline.py`

   （它会逐文件实名列出，并检查每个改动都在 `CHANGES.md` 里登记过）。

2. 上游最常动的三处，冲突概率从低到高：`vs2022/*.vcxproj`（我们手加的宏与库目录不在 premake 里，

   **重新生成工程会静默丢掉**——这是已知风险，记在 `CHANGES.md` 与 `HISTORY.md`）、

   `src/Settings.h`（字段表顺序变化不影响我们，因为选项页按 INI **名字**查字段，不写偏移）、

   `src/HomePage.cpp`（关于页那张表如果上游加了行，我们的三行照旧追加即可）。

3. 坐标一律用符号名定位，不用行号——行号会随注释漂移。



## 许可



见 [readme.md 的许可一节](readme.md)：本改版按 **(A)GPLv3** 分发（内嵌的 MuPDF 是 AGPLv3，

静态链进同一个 exe），上游全部版权声明与 `AUTHORS` 原样保留，CAJ 解码库 caj2pdf-core 为 MIT。

