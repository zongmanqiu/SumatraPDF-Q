"""Gate: every row of the options-page descriptor table must resolve, by INI
name, to a top-level settings field whose type matches the control we build.

Text-level on purpose: no build and no debug exe, so it can run on every edit.
A typo or an upstream field rename fails here instead of silently editing the
wrong value in the UI.

Usage:  python .plan/tools/check-settings-descriptors.py
"""
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
SETTINGS = os.path.join(ROOT, ".main", "upstream", "src", "Settings.h")
PAGE = os.path.join(ROOT, ".main", "upstream", "src", "SettingsPage.cpp")

STRINGISH = {"String", "Color"}
NUMERIC = {"Int", "Float"}


def field_rows(text, array_name):
    """Every FieldInfo row in order, INCLUDING Comment rows: the name blob is
    index-locked to this array, so skipping comments misaligns everything."""
    i = text.find(array_name + "[]")
    if i < 0:
        return None
    seg = text[i:text.find("};", i)]
    out = []
    for body in re.findall(r"\{([^{}]*)\}", seg):
        ty = re.search(r"SettingType::(\w+)", body)
        out.append(ty.group(1) if ty else "?")
    return out


def top_level_schema(text):
    i = text.find("gGlobalPrefsFields[]")
    if i < 0:
        sys.exit("cannot parse gGlobalPrefsFields")
    m = re.search(r"static const StructInfo gGlobalPrefsInfo\s*=\s*\{[^{}]*?,\s*(\d+),\s*gGlobalPrefsFields", text)
    if not m:
        sys.exit("cannot find gGlobalPrefsInfo")
    count = int(m.group(1))
    seg = text[m.start():text.find("};", m.start())]
    # the name blob is written as C escapes: in the file text the separators are
    # the two characters backslash and zero, not a NUL byte
    blob = "".join(re.findall(r'"([^"]*)"', seg))
    names = blob.split("\\0")
    rows = field_rows(text, "gGlobalPrefsFields")
    if rows is None:
        sys.exit("cannot parse the field array")
    if len(rows) != count:
        sys.exit(f"parsed {len(rows)} field rows but fieldCount says {count}")
    if len(names) < count:
        sys.exit(f"name blob has {len(names)} entries but fieldCount says {count}")
    out = {}
    for idx, ty in enumerate(rows):
        if names[idx]:
            out[names[idx]] = ty
    return out


text = open(SETTINGS, encoding="utf-8", errors="replace").read()
schema = top_level_schema(text)

ptxt = open(PAGE, encoding="utf-8", errors="replace").read()
i = ptxt.find("gDescs[] = {")
if i < 0:
    sys.exit("cannot find gDescs[]")
seg = ptxt[i:ptxt.find("};\n", i)]
rows = re.findall(r'\{\s*"([^"]+)"\s*,\s*"[^"]*"\s*,\s*CtlKind::(\w+)\s*,\s*ApplyKind::(\w+)', seg)

cap = re.search(r"PageRow rows\[([^\]]+)\]", ptxt)
capacity = cap.group(1) if cap else "?"

# the product's own enum is the only allowed set of control kinds, so the gate
# cannot drift ahead of it (a row using a removed kind must fail here, not at
# compile time)
kinds_m = re.search(r"enum class CtlKind\s*\{([^}]*)\}", ptxt)
if not kinds_m:
    sys.exit("cannot parse 'enum class CtlKind' in SettingsPage.cpp")
CTL_KINDS = {k.strip() for k in kinds_m.group(1).split(",") if k.strip()}
STR2NUM = {"Check": {"Bool"}, "Edit": STRINGISH | NUMERIC, "Combo": STRINGISH}

print(f"Settings.h 顶层可命名设置项：{len(schema)}")
print(f"descriptor 行数：{len(rows)}   页面容量：rows[{capacity}]   控件类型：{'/'.join(sorted(CTL_KINDS))}")

fails = []
if len(rows) < 6:
    fails.append(f"只解析出 {len(rows)} 行 descriptor，表可能被改坏")
if capacity != "dimof(gDescs)" and capacity.isdigit() and int(capacity) < len(rows):
    fails.append(f"页面只放得下 {capacity} 行，却有 {len(rows)} 项")

seen = set()
for name, ctl, apply in rows:
    if name in seen:
        fails.append(f"{name}: descriptor 里重复")
    seen.add(name)
    ty = schema.get(name)
    if ty is None:
        fails.append(f"{name}: Settings.h 里没有这个 INI 字段名（改名或写错了）")
        continue
    if apply not in {"Now", "Restart"}:
        fails.append(f"{name}: 生效方式 {apply} 不认识")
    if ctl not in CTL_KINDS:
        fails.append(f"{name}: 控件类型 CtlKind::{ctl} 在产品代码里不存在")
    elif ty not in STR2NUM.get(ctl, set()):
        fails.append(f"{name}: 控件是 {ctl}，字段却是 {ty}")

print()
if fails:
    print("FAIL:")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print(f"OK: {len(rows)} 行全部解析成功，类型与控件匹配")
