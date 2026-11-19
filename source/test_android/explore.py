"""Opens a session (or reuses one) and prints the visible labels — used once to learn the screens.

python -I test_android/explore.py <out_dir> [new|reuse] [click:<label>]... [type:<hint-or-label>=<text>]...
"""
import os
import re
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import appium_client as ac  # noqa: E402

out = sys.argv[1]
mode = sys.argv[2]
sid_file = os.path.join(out, "session.txt")
if mode == "new":
    s = ac.Session({
        "platformName": "Android",
        "appium:automationName": "UiAutomator2",
        "appium:app": os.path.abspath("build/app/outputs/flutter-apk/app-debug.apk"),
        "appium:autoGrantPermissions": True,
        "appium:newCommandTimeout": 900,
        "appium:language": "ar",
        "appium:locale": "EG",
    })
    open(sid_file, "w").write(s.id)
else:
    s = ac.Session.__new__(ac.Session)
    s.id = open(sid_file).read().strip()

for step in sys.argv[3:]:
    kind, _, arg = step.partition(":")
    if kind == "click":
        s.click(s.wait(ac.label(arg)))
    elif kind == "clickx":
        s.click(s.wait(arg))
    elif kind == "type":
        hint, _, text = arg.partition("=")
        el = s.wait(ac.label(hint)) if hint else s.wait("//android.widget.EditText")
        s.type(el, text)
    elif kind == "typen":  # typen:<n>=<text>  → الـ EditText رقم n (من 1)
        n, _, text = arg.partition("=")
        s.type(s.wait(f"(//android.widget.EditText)[{n}]"), text)
    elif kind == "key":
        import subprocess
        subprocess.run([os.path.expandvars(r"%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"), "shell", "input", "keyevent", arg])
    elif kind == "sleep":
        time.sleep(float(arg))
    time.sleep(1.2)

time.sleep(1.5)
src = s.source()
open(os.path.join(out, "last_source.xml"), "w", encoding="utf-8").write(src)
s.screenshot(os.path.join(out, "last.png"))
labels = []
for m in re.finditer(r'<([\w.]+)[^>]*?(?:text="([^"]*)")?[^>]*?content-desc="([^"]*)"', src):
    cls, txt, desc = m.group(1).split(".")[-1], m.group(2) or "", m.group(3) or ""
    if txt or desc:
        labels.append(f"{cls}: {desc or txt}"[:110])
print("\n".join(labels))
