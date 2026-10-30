"""Print our deviation from SumatraPDF 3.6.1 and check every change is registered.

Usage:  python .plan/tools/diff-vs-baseline.py
Exit 1 if an upstream file was modified but CHANGES.md never names it.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
TREE = os.path.join(ROOT, ".main", "upstream")
MAIN = os.path.join(ROOT, ".main")
BASELINE = os.path.join(ROOT, ".3rd", "sumatrapdf-3.6.1rel")
TREE_FILE = os.path.join(ROOT, ".main", "fork", "baseline-tree.txt")


def git(*args):
    return subprocess.run(["git", *args], cwd=MAIN, capture_output=True,
                          text=True, encoding="utf-8", errors="replace").stdout


tree = open(TREE_FILE, encoding="utf-8").read().strip()

# 1. classify against the frozen baseline tree using git's own status letters.
#    This replaces a scheme that read "untracked" out of git status: as soon as
#    our files are committed they stop being untracked, and that version then
#    mis-reported every new file as a modified upstream one (13 + 8 showed as 23).
#    The cross-check below now agrees with this: 15 upstream files modified.
#    Files created after the last commit are still untracked, so they are
#    merged in from git status below: a list that depends on staging order is a
#    list that silently misses something.
#    m13b: the whole upstream tree lives in upstream/, so git reports paths with
#    that prefix; strip it so every list below speaks baseline-relative paths.
#    A pure move is R100 (identical content) and must NOT count as a deviation;
#    a file we both moved and edited shows R<100 and lands in `changed`.
raw = git("diff", "--name-status", tree)
changed = {}
added = []
prefix = "upstream/"
for line in raw.splitlines():
    parts = line.split("	")
    if len(parts) < 2:
        continue
    status, path = parts[0], parts[-1]
    if path.startswith(prefix):
        path = path[len(prefix):]
    if status.startswith("R100"):
        continue
    if status.startswith("A"):
        added.append(path)
    else:
        changed[path] = status          # M = modified upstream, D = deleted upstream

# 2b. new files not committed yet (untracked, minus gitignored build output)
for l in git("status", "--porcelain", "-uall").splitlines():
    p = l[3:].rstrip("/")
    if l.startswith("??") and not p.startswith("out/") and not p.startswith("upstream/out/"):
        if p.startswith(prefix):
            p = p[len(prefix):]
        added.append(p)
added = sorted(set(added))

# 3. belt and braces: the read-only pristine copy must agree with the tree object.
#    m13b: the tree now lives under upstream/, so the two roots no longer align
#    for `diff -rq`; compare path by path from the baseline listing instead.
#    -z because some svg names contain non-ASCII that git would octal-quote.
if os.path.isdir(BASELINE):
    import filecmp
    ls = git("ls-tree", "-r", "--name-only", "-z", tree).split("\0")
    differ = []
    missing = []
    for p in ls:
        if not p:
            continue
        rel = p.split("/")
        a = os.path.join(BASELINE, *rel)
        b = os.path.join(TREE, *rel)
        if not os.path.isfile(b):
            missing.append(p)
            continue
        if not filecmp.cmp(a, b, shallow=False):
            differ.append(p)
    print(f"[cross-check] baseline copy vs upstream/: differing {len(differ)}   missing {len(missing)}")
    for p in missing:
        print("  missing:", p)

print(f"\n=== 改动的上游文件：{len(changed)} ===")
for p in sorted(changed):
    print("  ", p)
print(f"\n=== 我们新增的文件：{len(added)} ===")
for p in sorted(added):
    print("  ", p)

# 4. the gate: every changed upstream file must be named in CHANGES.md
changes_md = os.path.join(MAIN, "fork", "CHANGES.md")
if not os.path.isfile(changes_md):
    print("\nFAIL: CHANGES.md 不存在")
    sys.exit(1)
text = open(changes_md, encoding="utf-8").read()
unregistered = [p for p in changed if os.path.basename(p) not in text]
entries = len(re.findall(r"^###? ", text, re.M))
print(f"\nCHANGES.md 条目数：{entries}")
if unregistered:
    print("FAIL: 以下文件改了但没登记：")
    for p in unregistered:
        print("  -", p)
    sys.exit(1)
print("OK: 每个被改的上游文件都在 CHANGES.md 里有名字")

# 5. MODIFICATIONS.md's file table must be the *same set* as git's list, in both
#    directions: no upstream file we touched missing from the reader-facing doc,
#    and no file claimed there that we no longer touch. The claim is scoped to
#    that one section so licence prose (mupdf/COPYING etc.) can't be mistaken
#    for a modification.
MODS = os.path.join(MAIN, "fork", "MODIFICATIONS.md")
NLH = chr(10)
NLJ = " " * 6 + chr(10) + "      "
listed = git("ls-tree", "-r", "--name-only", tree).splitlines()
baseline_set = set(listed)
if os.path.isfile(MODS):
    mtxt = open(MODS, encoding="utf-8").read()
    start = mtxt.find("## 改动的上游文件")
    end = mtxt.find(NLH + "## ", start + 1)
    section = mtxt[start:end] if start >= 0 and end > start else ""
    claimed = {p.strip("` ") for p in re.findall(r"`([^`]+)`", section)}
    claimed = {p for p in claimed if p in baseline_set}
    missing = sorted(set(changed) - claimed)
    extra = sorted(claimed - set(changed))
    print(f"MODIFICATIONS.md 清单：声明 {len(claimed)} 个上游文件，git 读到 {len(changed)} 个")
    bad = []
    if missing:
        bad.append("清单里漏了（我们确实改了但没写）：" + NLJ + NLJ.join(missing))
    if extra:
        bad.append("清单里多写了（已不再改这个文件）：" + NLJ + NLJ.join(extra))
    if missing or extra:
        print("FAIL: MODIFICATIONS.md 与 git 的偏离清单不一致")
        for b in bad:
            print("  -", b)
        sys.exit(1)
    print("OK: MODIFICATIONS.md 的文件清单与 git 双向一致")
else:
    print("FAIL: MODIFICATIONS.md 不存在")
    sys.exit(1)
