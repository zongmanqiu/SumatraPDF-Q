"""Gate: the fork revision must say the same thing in three places.

  src/Version.h   #define VER_QUALIFIER  Q1     <- what the binary actually prints
  HISTORY.md      ## 3.6.1Q1 — <date>          <- the newest history entry
  readme.md       # ...（非官方改版 · 3.6.1Q1）  <- what a visitor reads first

Text-level, no build needed, so it can run on every edit. Drift here is silent:
a binary labelled Q1 with a history file headed Q2 is exactly the kind of record
that makes an upgrade impossible to reason about.

Usage:  python .plan/tools/check-release-version.py
"""
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
VERSION_H = os.path.join(ROOT, ".main", "upstream", "src", "Version.h")
HISTORY = os.path.join(ROOT, ".main", "HISTORY.md")
README = os.path.join(ROOT, ".main", "README.md")

vtxt = open(VERSION_H, encoding="utf-8", errors="replace").read()
rtxt = open(HISTORY, encoding="utf-8", errors="replace").read()
mtxt = open(README, encoding="utf-8", errors="replace").read()

base = re.search(r"#define\s+CURR_VERSION\s+(\d+\.\d+\.\d+)", vtxt)
qual = re.search(r"#define\s+VER_QUALIFIER\s+(\S+)", vtxt)
if not base or not qual:
    sys.exit("cannot read CURR_VERSION / VER_QUALIFIER from src/Version.h")
base, qual = base.group(1), qual.group(1)

fails = []

# VER_QUALIFIER is pasted onto the version digits by QM2(), so it must be a bare
# token: no quotes, no punctuation, no whitespace. "Q1" ok, "-Q1" or '"Q1"' are not.
if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", qual):
    fails.append(f"VER_QUALIFIER={qual!r} 不是可直接粘贴的记号（要形如 Q1，不能带引号或标点）")

version = f"{base}{qual}"

# the newest entry is the first "## <version>" heading in HISTORY.md
heads = re.findall(r"^##\s+(\d+\.\d+\.\d+[A-Za-z0-9]*)\s*[（(—-]", rtxt, re.M)
if not heads:
    sys.exit("HISTORY.md 里找不到 '## <版本号>（日期）' 这样的标题")
newest = heads[0]
print(f"Version.h : 基线 {base} + 修订 {qual}  =>  {version}")
print(f"HISTORY.md 最新条目: {newest}   （共 {len(heads)} 条: {', '.join(heads)}）")
if newest != version:
    fails.append(f"HISTORY.md 最新条目是 {newest}，与 Version.h 的 {version} 不一致")

# the landing page must state the current version near the top (the download line).
# pecia's own README keeps the number out of the title, so the check is a window,
# not "line 1": a doc that buries its version below the fold fails.
head_lines = mtxt.splitlines()[:12]
print("readme.md 前 12 行里有版本号:", any(version in l for l in head_lines))
if not any(version in l for l in head_lines):
    fails.append(f"readme.md 开头 12 行内没出现 {version}")

# a table row mapping our version back to the official base must exist too
if not re.search(rf"\|\s*{re.escape(version)}\s*\|", rtxt):
    fails.append(f"HISTORY.md 的「版本对应关系」表里没有 {version} 这一行")

print()
if fails:
    print("FAIL:")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print(f"OK: 三处版本号一致 = {version}")
