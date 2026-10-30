# SumatraPDF-Q（邱宗满的非官方改版 · 3.6.1Q1）

本仓库是官方 [SumatraPDF](https://github.com/sumatrapdfreader/sumatrapdf) 3.6.1 的**改版**，与官方项目没有隶属关系。
只做两件事：**直接打开 CAJ（知网）文件**、**把只能手改配置文件才生效的设置做成选项页**。
为的是以后官方更新时还能低成本跟进，所以改动面保持最小：

- 逐文件的偏离清单：[CHANGES.md](CHANGES.md)（由门禁强制与代码对齐）
- 版本规则与版本历史：[RELEASES.md](RELEASES.md)
- 下载：Gitee <https://gitee.com/qiuzongman/SumatraPDF-Q>（源仓库） · GitHub <https://github.com/zongmanqiu/SumatraPDF-Q>（自动同步镜像）
- 许可：继承上游 GPLv3（部分代码 Simplified BSD；内嵌 MuPDF 为 AGPLv3、CAJ 解码库 caj2pdf-core 为 MIT），上游全部版权声明原样保留。
- 本改版**不检查官方更新**（官方包会覆盖掉 CAJ 与选项页功能），也**不把崩溃报告上传到官方服务器**。

---

[![Build](https://github.com/sumatrapdfreader/sumatrapdf/actions/workflows/build.yml/badge.svg?branch=master)](https://github.com/sumatrapdfreader/sumatrapdf/actions/workflows/build.yml)
## SumatraPDF Reader

SumatraPDF is a multi-format (PDF, EPUB, MOBI, CBZ, CBR, FB2, CHM, XPS, DjVu) reader
for Windows under (A)GPLv3 license, with some code under BSD license (see
AUTHORS).

More Information:
* [Website](https://www.sumatrapdfreader.org/free-pdf-reader)
* [Manual](https://www.sumatrapdfreader.org/manual)
* [Developer Information](https://www.sumatrapdfreader.org/docs/Contribute-to-SumatraPDF)
