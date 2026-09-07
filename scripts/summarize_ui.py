# -*- coding: utf-8 -*-
"""Print clickable uiautomator nodes for model-driven taps."""
import sys
import re
import xml.etree.ElementTree as ET

path = sys.argv[1]
max_w = int(sys.argv[2]) if len(sys.argv) > 2 else 1080
max_h = int(sys.argv[3]) if len(sys.argv) > 3 else 1920

raw = open(path, "rb").read()
# strip NULs / illegal
raw = raw.replace(b"\x00", b"")
text = raw.decode("utf-8", "ignore")
try:
    root = ET.fromstring(text)
except ET.ParseError:
    print("XML_PARSE_FAIL")
    sys.exit(2)

bnd_re = re.compile(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]")
rows = []
for node in root.iter("node"):
    clickable = node.attrib.get("clickable", "false") == "true"
    enabled = node.attrib.get("enabled", "true") != "false"
    cls = node.attrib.get("class", "")
    is_edit = "EditText" in cls
    if not enabled:
        continue
    if not clickable and not is_edit:
        continue
    b = node.attrib.get("bounds", "")
    m = bnd_re.match(b)
    if not m:
        continue
    l, t, r, btm = map(int, m.groups())
    w, h = r - l, btm - t
    if w <= 0 or h <= 0:
        continue
    # skip full-screen overlays
    if w >= max_w - 20 and h >= max_h - 80:
        continue
    cx, cy = (l + r) // 2, (t + btm) // 2
    label = (
        node.attrib.get("text", "")
        or node.attrib.get("content-desc", "")
        or node.attrib.get("resource-id", "").split("/")[-1]
        or cls.split(".")[-1]
    )
    rows.append(
        {
            "score": (2 if clickable else 0)
            + (3 if any(k in (label + cls).lower() for k in (
                "login", "sign", "注册", "登录", "登入", "同意", "允许", "开始",
                "进入", "继续", "确定", "手机", "密码", "获取验证码", "submit",
            )) else 0)
            + (1 if is_edit else 0),
            "cx": cx,
            "cy": cy,
            "w": w,
            "h": h,
            "text": node.attrib.get("text", "")[:80],
            "desc": node.attrib.get("content-desc", "")[:80],
            "rid": node.attrib.get("resource-id", ""),
            "cls": cls.split(".")[-1],
            "clickable": clickable,
            "edit": is_edit,
            "bounds": b,
        }
    )

rows.sort(key=lambda x: (-x["score"], x["cy"], x["cx"]))
print(f"CLICKABLES {len(rows)}")
for i, r in enumerate(rows[:40], 1):
    flags = []
    if r["edit"]:
        flags.append("EDIT")
    if r["clickable"]:
        flags.append("TAP")
    print(
        f"{i:02d}  ({r['cx']:4d},{r['cy']:4d})  {r['w']:4d}x{r['h']:<4d}  "
        f"{','.join(flags):7s}  {r['cls']:16s}  "
        f"text={r['text']!r}  desc={r['desc']!r}  id={r['rid']}"
    )
