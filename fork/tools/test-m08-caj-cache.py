"""m08 + m11 回归：CAJ 缓存的去重、命名、清单、回收，以及审计修掉的四条。

用法：python .plan/tools/test-m08-caj-cache.py
每条都跑真 exe（-bench 无界面模式），断言的是产物个数、index.txt 行数与日志里的
关键分支。T6-T9 各自的判据落在「旧代码一定会失败」的那一格。

注意：这个文件在 2026-10-30 被一次脚本改坏过（一条带 re.S 的正则跨段匹配吞掉了
T4-T7），下面是重建版；改它之前先复制一份快照，改完与快照对比删了哪几行。
"""
import ctypes
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
SRC_CAJ = os.path.join(ROOT, ".ex", "儿童青少年期内外化问题的共发及亲子关系和友谊质量的影响.caj")
EXE_SRC = os.path.join(ROOT, ".main", "upstream", "out", "rel64", "SumatraPDF.exe")
T = os.path.join(ROOT, ".temp", "m08")
TAB = chr(9)
NL = chr(10)

k32 = ctypes.windll.kernel32


def short(p):
    n = k32.GetShortPathNameW(p, None, 0)
    if n == 0:
        return None
    buf = ctypes.create_unicode_buffer(n)
    k32.GetShortPathNameW(p, buf, n)
    return buf.value


def exe_in_t():
    return os.path.join(T, "SumatraPDF-Q.exe")


def bench(path, dump=None, cwd=None):
    r = subprocess.run([exe_in_t(), "-bench", path, "loadonly"], capture_output=True,
                       cwd=cwd or T, text=True, encoding="utf-8", errors="replace", timeout=120)
    out = (r.stdout or "") + (r.stderr or "")
    if dump:
        open(dump, "w", encoding="utf-8").write(out)
    pages = re.search(r"page count: (\d+)", out)
    return out.count("EngineCaj: converted"), out.count("cache hit"), \
        (int(pages.group(1)) if pages else -1), out


def cache_dir():
    return os.path.join(T, "caj-cache")


def cache_files():
    d = cache_dir()
    return sorted(f for f in os.listdir(d) if f.lower().endswith(".pdf")) if os.path.isdir(d) else []


def tmp_files():
    d = cache_dir()
    return sorted(f for f in os.listdir(d) if f.lower().endswith(".tmp")) if os.path.isdir(d) else []


def index_path():
    return os.path.join(cache_dir(), "index.txt")


def index_lines():
    f = index_path()
    if not os.path.isfile(f):
        return []
    return [l for l in open(f, encoding="utf-8", errors="replace").read().splitlines() if l.strip()]


def index_keys():
    """srcNorm field of every line: the cache key, which must be a clean path."""
    out = []
    for l in index_lines():
        parts = l.split(TAB)
        if len(parts) >= 2:
            out.append(parts[1])
    return out


def reset():
    shutil.rmtree(T, ignore_errors=True)
    os.makedirs(T)
    shutil.copy2(EXE_SRC, exe_in_t())


def copy_src(name):
    d = os.path.join(T, name)
    shutil.copy2(SRC_CAJ, d)
    return d


fails = []

# ---------------------------------------------------------------------------
print("== T1: 同一个文件的四种拼法 -> 1 个 pdf、1 行清单、只转一次 ==")
reset()
c1, h1, p1, _ = bench(SRC_CAJ)
spell_short = short(SRC_CAJ)
spell_double = SRC_CAJ.replace("\\", "\\\\", 1)
spell_rel = os.path.relpath(SRC_CAJ, T)
for sp in (spell_short, spell_double, spell_rel):
    if not sp:
        continue
    c, h, p, _ = bench(sp)
    if p != 64:
        fails.append(f"T1: 拼法 {sp!r} 打不开（pages={p}）")
pdfs = cache_files()
print(f"  pdf={len(pdfs)} 清单={len(index_lines())} 首次 converted={c1} hit={h1}")
if len(pdfs) != 1:
    fails.append(f"T1: {len(pdfs)} 个缓存 pdf，期望 1 个")
if len(index_lines()) != 1:
    fails.append(f"T1: {len(index_lines())} 行清单，期望 1 行")
keys = index_keys()
want = os.path.normpath(SRC_CAJ).upper()
for k in keys:
    if any(ord(ch) < 32 for ch in k):
        fails.append(f"T1: 缓存键里有控制字符（编码被弄坏了）：{k!r}")
    elif len(k) < len(want) - 2 or want[:8] not in k[:8].upper():
        fails.append(f"T1: 缓存键不像规范化后的完整路径\n    got  {k!r}\n    want {want!r}")

# ---------------------------------------------------------------------------
print("== T2: 两个不同目录里的同名文件 -> 2 个 pdf，第二个带 __2 ==")
reset()
a2 = os.path.join(T, "aa.caj")
b2dir = os.path.join(T, "sub")
os.makedirs(b2dir, exist_ok=True)
b2 = os.path.join(b2dir, "aa.caj")
shutil.copy2(SRC_CAJ, a2)
shutil.copy2(SRC_CAJ, b2)
c2a, h2a, p2a, _ = bench(a2)
c2b, h2b, p2b, _ = bench(b2)
pdfs = cache_files()
print(f"  second: converted={c2b} hit={h2b} pages={p2b}")
print(f"  names={pdfs}")
if p2a != 64 or p2b != 64:
    fails.append(f"T2: 两个文件没都打开（{p2a} / {p2b}）")
if len(pdfs) != 2 or not any("__2" in x for x in pdfs):
    fails.append(f"T2: 期望 2 个 pdf 且第二个带 __2，实得 {pdfs}")

# ---------------------------------------------------------------------------
print("== T3: 清单被写坏 -> 仍然能打开 ==")
reset()
os.makedirs(cache_dir(), exist_ok=True)
open(index_path(), "w", encoding="utf-8").write(TAB.join(["garbage", "line"]) + NL + "notenough" + NL)
c3, h3, p3, _ = bench(SRC_CAJ)
print(f"  converted={c3} hit={h3} pages={p3} pdfs={cache_files()}")
if p3 != 64:
    fails.append(f"T3: 清单损坏后打不开（pages={p3}）")

# ---------------------------------------------------------------------------
print("== T4: 过期条目被回收，新鲜的不能被牵连 ==")
reset()
f4a = copy_src("keep-me.caj")
f4b = copy_src("gone.caj")
bench(f4a)
bench(f4b)
lines = index_lines()
aged = []
for l in lines:
    parts = l.split(TAB)
    if len(parts) == 5 and "gone" in parts[0]:
        parts[4] = "0"          # lastUse = 1970 -> 早已过期
    aged.append(TAB.join(parts))
open(index_path(), "w", encoding="utf-8").write(NL.join(aged) + NL)
c4, h4, p4, _ = bench(f4a)
pdfs = cache_files()
print(f"  回收后剩下的 pdf={pdfs}")
if not any("keep-me" in x for x in pdfs):
    fails.append(f"T4: 新鲜的条目被误删了：{pdfs}")
if any("gone" in x for x in pdfs):
    fails.append(f"T4: 过期条目没被回收，仍留着 {pdfs}")
if any("gone" in l for l in index_lines()):
    fails.append(f"T4: 清单里仍留着已回收的条目：{index_lines()}")
if tmp_files():
    fails.append(f"T4: 缓存目录里留下临时文件：{tmp_files()}")

# ---------------------------------------------------------------------------
print("== T5: 重复打开 20 次仍然只有 1 个 pdf / 1 行清单 ==")
reset()
for _ in range(20):
    bench(SRC_CAJ)
print(f"  pdf={len(cache_files())} 清单={len(index_lines())}")
if len(cache_files()) != 1 or len(index_lines()) != 1:
    fails.append(f"T5: {len(cache_files())} 个 pdf / {len(index_lines())} 行清单（20 次打开之后）")

# ---------------------------------------------------------------------------
print("== T6: 同一路径、mtime 变了 -> 必须真的重转（m11 R2）==")
reset()
src6 = copy_src("样本六.caj")
bench(src6)
st = os.stat(src6)
os.utime(src6, (st.st_atime, st.st_mtime + 120))
c6, h6, p6, out6 = bench(src6, os.path.join(T, "t6.txt"))
print(f"  第二次：converted={c6} hit={h6} pages={p6}")
if c6 != 1 or h6 != 0:
    fails.append(f"T6: 源文件变了却没重转（converted={c6} hit={h6}）——旧代码只写日志不改产物")
if p6 != 64:
    fails.append(f"T6: 重转后打不开（pages={p6}）")

# ---------------------------------------------------------------------------
print("== T7: 缓存 pdf 的头被写坏 -> 必须重转（m11 R4）==")
reset()
src7 = copy_src("样本七.caj")
bench(src7)
pdfs = cache_files()
if not pdfs:
    fails.append("T7: 第一次没产生缓存")
else:
    victim = os.path.join(cache_dir(), pdfs[0])
    with open(victim, "r+b") as f:
        f.write(b"NOTAPDF")
    c7, h7, p7, _ = bench(src7, os.path.join(T, "t7.txt"))
    print(f"  改坏头部后：converted={c7} hit={h7} pages={p7}")
    if h7 != 0 or c7 != 1:
        fails.append(f"T7: 坏头缓存仍被命中（converted={c7} hit={h7}）")
    if p7 != 64:
        fails.append(f"T7: 重转后打不开（pages={p7}）")

# ---------------------------------------------------------------------------
print("== T8: 清单里放一个越界名字 -> 该行被拒，目录外文件不许被删（m11 R5）==")
reset()
src8 = copy_src("src8.caj")
os.makedirs(cache_dir(), exist_ok=True)
evil = os.path.join(T, "evil.pdf")
open(evil, "wb").write(b"x")
hostile = TAB.join([os.path.join("..", "evil.pdf"), "SOMENORM", "1", "2", "0"]) + NL
open(index_path(), "w", encoding="utf-8").write(hostile)
c8, h8, p8, out8 = bench(src8, os.path.join(T, "t8.txt"))
print(f"  打开：converted={c8} hit={h8} pages={p8}  目录外文件仍在={os.path.exists(evil)}")
if "ignoring malformed index line" not in out8:
    fails.append("T8: 越界的清单行没被拒绝")
if not os.path.exists(evil):
    fails.append("T8: 缓存目录外的文件被删了——清单成了任意删除的入口")
if p8 != 64:
    fails.append(f"T8: 坏清单让文件打不开（pages={p8}）")
for l in index_lines():
    if TAB.join([os.path.join("..", "evil.pdf")]) in l:
        fails.append(f"T8: 越界行被写回了清单：{index_lines()}")

# ---------------------------------------------------------------------------
print("== T9: 转换失败之后不许留悬垂条目（m11 R3）==")
reset()
bad9 = os.path.join(T, "bad9.caj")
open(bad9, "wb").write(b"CAJ" + bytes([0]) + os.urandom(4096))
src9 = copy_src("src9.caj")
cbad, hbad, pbad, _ = bench(bad9, os.path.join(T, "t9bad.txt"))
print(f"  坏输入：converted={cbad} pages={pbad}（期望打不开且不崩）")
c9, h9, p9, _ = bench(src9, os.path.join(T, "t9.txt"))
print(f"  再开好文件：converted={c9} hit={h9} pages={p9} 清单行数={len(index_lines())}")
if p9 != 64:
    fails.append(f"T9: 转换失败后再开别的 CAJ 不正常（pages={p9}）——悬垂条目被读到了")
if len(index_lines()) != 1:
    fails.append(f"T9: 清单行数={len(index_lines())}，期望只有好文件那 1 行")
if os.path.isfile(index_path()) and "bad9" in open(index_path(), encoding="utf-8", errors="replace").read():
    fails.append("T9: 失败的那条仍留在清单里")

print()
if fails:
    print("FAIL:")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("ALL PASS")
