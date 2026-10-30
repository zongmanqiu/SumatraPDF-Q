# SumatraPDF-Q — 能直接打开 CAJ 论文的 SumatraPDF 改版

**[⬇️ 下载最新版 3.6.1Q1（Gitee Releases）](https://gitee.com/qiuzongman/SumatraPDF-Q/releases)**
 ｜ **[GitHub Releases（镜像）](https://github.com/zongmanqiu/SumatraPDF-Q/releases)**
 ｜ [Gitee 主仓](https://gitee.com/qiuzongman/SumatraPDF-Q)
 ｜ [GitHub 镜像](https://github.com/zongmanqiu/SumatraPDF-Q)

> 下载页里取 `SumatraPDF-Q.exe` 这一个文件即可，**不需要安装、不写注册表**；
> 配置和缓存都生成在它旁边。

SumatraPDF 3.6.1 的非官方改版，作者**邱宗满**，与官方项目没有隶属关系。只做了两件事，
其余功能、界面、快捷键全部与官方一致：

**1. 双击就能打开 CAJ（知网私有电子论文格式）**

- 不用转换器、不用另存、不用命令行——转换库直接编在 exe 里。
- 打开之后，书签目录、全文搜索、缩略图侧栏、批注、打印都跟 PDF 一样能用。
- 想留一份 PDF 版本，直接「另存为」即可。
- 已看过的文件会缓存（exe 旁边的 `caj-cache/`，文件名就是原文件名换后缀），再开时秒开；
  30 天没再读过的自动回收。64 页论文实测：首次转换约 0.3 秒，之后打开约 5 毫秒。

**2. 把「只能手改配置文件」的设置做成选项页（设置 → 选项）**

- 9 个开关：文档以标签页打开、启动时恢复上次文件、记住打开过的文件、新文件交给已运行实例、
  标题栏显示完整路径、平滑滚动、每个文档记住阅读状态、文件改动时自动重载、大文档延迟加载。
- 判据是硬的：**凡是在菜单、工具栏或鼠标操作上能改的，这里一个都不放**（例如界面主题在
  「设置 → 主题」里就有）。需要重启才生效的，标签上直接写「（需重启）」。

**另外两条为"改版"必须做的事**

- 单文件便携：只有一个 exe，没有旁挂 dll。配置文件是 exe 旁边的 `SumatraPDF-settings.txt`，
  用记事本改也行。
- **不检查官方更新、也不把崩溃报告发给官方**。官方更新包会把本改版覆盖掉，CAJ 与选项页
  功能会无声消失；本改版的 bug 也不该记到官方账上。要升级请回到上面的下载页。

## 版本

版本号规则：`<官方基线>Q<修订>`。`3.6.1` 表示切自官方 3.6.1，`Q1` 是我们自己的第 1 个修订
（因为会在同一官方基线上反复修改，需要一个不掺混的序号）。当前版本 **3.6.1Q1**，
会显示在「帮助 → 关于」和 exe 属性页里。逐版本记录见 [HISTORY.md](HISTORY.md)。

## 许可

继承上游许可，**不放宽**：

- 本改版整体按 **GNU GPLv3** 分发，全文见 [COPYING](COPYING)；
  上游部分工具代码为 Simplified BSD，见 [COPYING.BSD](COPYING.BSD)。
- 内嵌 MuPDF 为 **AGPLv3**（见 `mupdf/COPYING`），CAJ 解码库
  [caj2pdf-core](https://github.com/rwv/caj2pdf-rust) 为 **MIT**。
- 上游全部版权声明与 [AUTHORS](AUTHORS) 原样保留；本改版的署名与仓库地址加在
  「帮助 → 关于」页里。逐文件的改动清单见 [CHANGES.md](CHANGES.md)。

## 关于官方原版

本改版基于官方 [SumatraPDF 3.6.1](https://github.com/sumatrapdfreader/sumatrapdf)。
官方项目与作者（Krzysztof Kowalczyk 及贡献者）是全部核心功能的来源：
官网 <https://www.sumatrapdfreader.org>、手册 <https://www.sumatrapdfreader.org/manual>。
如果你不需要 CAJ、也想用官方最新的 3.7 系列，请直接用官方版。

**问题反馈请发到本仓库**（Gitee 主仓的 issue），官方讨论区收到的反馈我们无法处理。
