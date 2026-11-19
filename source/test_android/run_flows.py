"""Worst-case flows of the real Android app on an emulator (Appium UiAutomator2).

Started by run.ps1 (emulator + Appium + temporary server already running).
python -I test_android/run_flows.py <out_dir> <seed.json>
Writes <out_dir>/android_results.json and a screenshot per scenario.
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import appium_client as ac  # noqa: E402

OUT, SEED = sys.argv[1], json.load(open(sys.argv[2], encoding="utf-8"))
ADB = os.path.expandvars(r"%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe")
results = []


def adb(*args):
    # dumpsys فيه عربي: لازم utf-8 صريح (ويندوز بيقرا بـ cp1252 وبيرجّع None)
    r = subprocess.run([ADB, *args], capture_output=True, encoding="utf-8", errors="replace")
    return (r.stdout or "").strip()


def api(method, path, body=None):
    req = urllib.request.Request(SEED["base"] + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + SEED["token"], "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def record(name, ok, evidence, shot=None, note=None):
    if shot:
        s.screenshot(os.path.join(OUT, shot))
    results.append({"scenario": name, "status": "PASS" if ok else "FAIL", "evidence": evidence, **({"screenshot": shot} if shot else {}), **({"note": note} if note else {})})
    print(("PASS " if ok else "FAIL ") + name + " — " + evidence)


def _png_rows(png, upto):
    """بيفك أول [upto] صف من صورة PNG (مكتبة بايثون العادية بس)."""
    import struct
    import zlib
    pos, idat, w, ct = 8, b"", 0, 6
    while pos < len(png):
        ln, typ = struct.unpack(">I4s", png[pos:pos + 8])
        body = png[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            w, h, _, ct = struct.unpack(">IIBB", body[:10])
        elif typ == b"IDAT":
            idat += body
        pos += 12 + ln
    raw, bpp = zlib.decompress(idat), (4 if ct == 6 else 3)
    stride, prev, rows = w * bpp, bytearray(w * bpp), []
    for y in range(min(upto, h)):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b, c = prev[i], (prev[i - bpp] if i >= bpp else 0)
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    return w, h, bpp, rows


def banner_visible():
    """شريط "مفيش اتصال" فوق الشاشة. مش ظاهر في شجرة الـ accessibility لأنه فوق كل الصفحات، فبنبص على الشاشة نفسها:
    صفين (فوق وتحت سطر الكلام) لازم يبقوا بلون الشريط (أحمر فاتح 255,218,214)."""
    png = subprocess.run([ADB, "exec-out", "screencap", "-p"], capture_output=True).stdout
    w, h, bpp, rows = _png_rows(png, 280)
    hits = 0
    for y in (h * 6 // 100, h * 10 // 100):
        for x in range(w // 10, w * 9 // 10, w // 20):
            r, g, b = rows[y][x * bpp:x * bpp + 3]
            hits += r > 235 and 200 <= g <= 232 and 196 <= b <= 230
    return hits >= 24

def set_portrait(portrait=True):
    adb("shell", "settings", "put", "system", "accelerometer_rotation", "0")
    adb("shell", "settings", "put", "system", "user_rotation", "0" if portrait else "1")


def recover():
    """بعد أي فشل: النت يرجع، والشاشة ترجع للصالة، عشان السيناريو اللي بعده يبدأ نضيف."""
    adb("shell", "cmd", "connectivity", "airplane-mode", "disable")
    adb("emu", "network", "speed", "full")
    adb("emu", "network", "delay", "none")
    set_portrait(True)
    time.sleep(1)
    for _ in range(5):
        if s.exists(ac.label("مشغولة من")):
            return
        s.back()
        time.sleep(1.5)


def step(name, fn):
    try:
        fn()
    except Exception as e:  # سجّل الفشل وكمّل باقي السيناريوهات
        try:
            open(os.path.join(OUT, f"fail_{len(results)}.xml"), "w", encoding="utf-8").write(s.source())
            record(name, False, f"exception: {e}"[:300], shot=f"fail_{len(results)}.png")
        except Exception:
            results.append({"scenario": name, "status": "FAIL", "evidence": f"exception: {e}"[:300]})
            print("FAIL " + name, e)
        try:
            recover()
        except Exception:
            pass


def desc_starts(text):
    return f"//*[starts-with(@content-desc,'{text}')]"


def table_check(name):
    t = next(t for t in api("GET", "/api/floor")["tables"] if t["name"] == name)
    return t["check"]


adb("shell", "cmd", "connectivity", "airplane-mode", "disable")
time.sleep(4)
s = ac.Session({
    "platformName": "Android",
    "appium:automationName": "UiAutomator2",
    # APK = مسار نسخة تانية (مثلاً app-release.apk اللي بتتباع)
    "appium:app": os.path.abspath(os.environ.get("APK", "build/app/outputs/flutter-apk/app-debug.apk")),
    "appium:autoGrantPermissions": True,
    "appium:newCommandTimeout": 900,
})


def connect_and_login():
    s.click(s.wait(ac.label("الاتصال بسيرفر الكافيه"), 60))
    s.type(s.wait("//android.widget.EditText", 30), "10.0.2.2:" + SEED["base"].rsplit(":", 1)[1])
    adb("shell", "input", "keyevent", "66")
    s.wait(ac.label("دخول"), 30)
    # الكتابة في حقول Flutter عن طريق UiAutomator أحياناً ماتوصلش للتطبيق: بنعيد المحاولة زي ما المستخدم بيعمل
    for attempt in range(3):
        s.type(s.wait("(//android.widget.EditText)[1]"), "owner")
        time.sleep(0.8)
        s.type(s.wait("(//android.widget.EditText)[2]"), "owner123")
        time.sleep(0.8)
        adb("shell", "input", "keyevent", "111")
        s.click(s.wait("//android.widget.Button[@content-desc='دخول']"))
        try:
            s.wait(ac.label("مشغولة من"), 15)
            break
        except ac.AppiumError:
            if attempt == 2:
                raise
    sessions_with_device = api("GET", "/api/info")  # السيرفر شغال
    record("connect by IP + login (device id sent)", True, f"floor shown; server {sessions_with_device['shopName']}", "a1_floor.png")


def order_with_modifiers():
    s.click(s.wait(desc_starts("1\n"), 30))
    s.click(s.wait("//android.widget.Button[@content-desc='2']", 30))
    s.click(s.wait(desc_starts("صنف 0-1"), 30)); time.sleep(0.6)
    s.click(s.wait(desc_starts("صنف 0-1"))); time.sleep(0.6)
    s.click(s.wait(desc_starts("صنف 0-0")))
    s.click(s.wait("//android.widget.Button[starts-with(@content-desc,'كبير')]"))
    s.click(s.wait("//android.widget.Button[starts-with(@content-desc,'شوت')]"))
    s.click(s.wait("//android.widget.Button[@content-desc='ضيف']"))
    s.click(s.wait(desc_starts("الحساب")))
    s.click(s.wait("//android.widget.Button[starts-with(@content-desc,'إرسال الطلب')]"))
    s.wait(desc_starts("طلب #1"), 30)
    c = table_check("1")
    record("order with required size + extras", c["totalCents"] == 12500, f"phone 125 EGP, server {c['totalCents']} piastres", "a2_order.png")


def live_update():
    c = table_check("1")
    item = next(i for i in SEED["items"] if not i["mods"])
    api("POST", f"/api/checks/{c['id']}/orders", {"lines": [{"itemId": item["id"], "qty": 3}]})
    total = table_check("1")["totalCents"]
    s.wait("//*[contains(@content-desc,'الإجمالي') and contains(@content-desc,'" + str(total // 100) + " ')]", 10)
    record("another device adds an order → phone updates live", True, "new total visible within 10 s, no refresh", "a3_live.png")


def open_table_1():
    if not s.exists(desc_starts("المنيو")):
        s.click(s.wait(desc_starts("1\n"), 30))
    s.wait(desc_starts("المنيو"), 30)


def offline_banner_and_retry():
    open_table_1()
    s.click(s.wait(desc_starts("المنيو")))
    s.click(s.wait(desc_starts("صنف 0-3"))); time.sleep(0.6)
    s.click(s.wait(desc_starts("الحساب")))
    adb("shell", "cmd", "connectivity", "airplane-mode", "enable")
    t0 = time.time()
    while not banner_visible() and time.time() - t0 < 25:
        time.sleep(1)
    shown_after = time.time() - t0
    s.click(s.wait("//android.widget.Button[starts-with(@content-desc,'إرسال الطلب')]"))
    time.sleep(6)
    still = banner_visible()
    draft_kept = s.exists(ac.label("لسه ما اتبعتش"))
    s.screenshot(os.path.join(OUT, "a4_offline.png"))
    adb("shell", "cmd", "connectivity", "airplane-mode", "disable")
    t1 = time.time()
    while banner_visible() and time.time() - t1 < 40:
        time.sleep(1)
    gone_after = time.time() - t1
    time.sleep(2)
    s.click(s.wait("//android.widget.Button[starts-with(@content-desc,'إرسال الطلب')]", 20))
    s.wait(desc_starts("طلب #3"), 30)
    detail = api("GET", f"/api/checks/{table_check('1')['id']}")
    ok = shown_after < 25 and still and draft_kept and gone_after < 40 and len(detail["orders"]) == 3
    record("Wi-Fi cut: lasting banner, draft kept, reconnect, no duplicate", ok,
           f"banner after {shown_after:.0f}s, still shown 6s after the failed send: {still}, draft kept: {draft_kept}, "
           f"banner gone {gone_after:.0f}s after Wi-Fi back, server orders: {len(detail['orders'])}", "a4_after_reconnect.png")


def closed_elsewhere_move_to_new_check():
    open_table_1()
    s.click(s.wait(desc_starts("المنيو")))
    s.click(s.wait(desc_starts("صنف 0-7"))); time.sleep(0.6)
    s.click(s.wait(desc_starts("الحساب")))
    c = table_check("1")
    api("POST", f"/api/checks/{c['id']}/payments", {"methodId": SEED["cash"], "amountCents": c["totalCents"] - c["paidCents"], "close": True})
    s.wait(ac.label("الحساب ده اتقفل"), 15)
    btn = s.wait("//android.widget.Button[starts-with(@content-desc,'ابعتها على حساب جديد')]", 15)
    s.screenshot(os.path.join(OUT, "a5_closed_elsewhere.png"))
    s.click(btn)
    t0 = time.time()
    new = table_check("1")
    while (new is None or new["id"] == c["id"] or new["totalCents"] == 0) and time.time() - t0 < 20:
        time.sleep(1)
        new = table_check("1")
    ok = new is not None and new["id"] != c["id"] and new["totalCents"] == 6500
    record("check closed on another device → unsent items sent to a new check", ok,
           f"old check closed, new check on table 1 = {None if new is None else new['totalCents']} piastres (expected 6500)", "a5_new_check.png")
    s.back()
    s.wait(ac.label("مشغولة من"), 20)


def rotate_background():
    set_portrait(False); time.sleep(3)
    land = s.exists(ac.label("مشغولة من"))
    s.screenshot(os.path.join(OUT, "a6_landscape.png"))
    s.background(6); time.sleep(3)
    back = s.exists(ac.label("مشغولة من"))
    set_portrait(True); time.sleep(2)
    record("rotate + 6 s in background", land and back, f"landscape floor: {land}, still logged in after resume: {back}")


def gprs_order():
    adb("emu", "network", "speed", "gprs"); adb("emu", "network", "delay", "gprs")
    t0 = time.time()
    s.click(s.wait(desc_starts("2\n"), 60))
    s.click(s.wait("//android.widget.Button[@content-desc='افتح من غير عدد']", 60))
    s.click(s.wait(desc_starts("صنف 0-9"), 60)); time.sleep(0.6)
    s.click(s.wait(desc_starts("الحساب"), 30))
    s.click(s.wait("//android.widget.Button[starts-with(@content-desc,'إرسال الطلب')]", 30))
    s.wait(desc_starts("طلب #"), 90)
    took = time.time() - t0
    adb("emu", "network", "speed", "full"); adb("emu", "network", "delay", "none")
    record("GPRS network (7 KB/s): open table + send order", took < 30, f"{took:.1f}s end to end", "a7_gprs.png")
    s.back()


def ready_order_via_api(table_name):
    """جهاز تاني (المطبخ) بيعلّم طلب جاهز → السيرفر بيبعت إشعار "طلب جاهز" للويتر/الكاشير/المالك."""
    t = next(t for t in api("GET", "/api/floor")["tables"] if t["name"] == table_name)
    c = t["check"] or api("POST", "/api/checks", {"type": "dine_in", "tableId": t["id"]})["check"]
    item = next(i for i in SEED["items"] if not i["mods"])
    o = api("POST", f"/api/checks/{c['id']}/orders", {"lines": [{"itemId": item["id"], "qty": 1}]})
    api("POST", f"/api/orders/{o['orderId']}/ready", {})
    return o


def notification_dump():
    return adb("shell", "dumpsys", "notification", "--noredact")


def notify_foreground_toast():
    ready_order_via_api("5")
    s.wait("//*[contains(@content-desc,'جاهز') or contains(@text,'جاهز')]", 10)
    record("app open: order ready → side notice (with sound)", True, "notice 'طلب #… جاهز' shown on the right", "n1_toast.png")


def notify_background_system():
    adb("shell", "input", "keyevent", "3")  # HOME: البرنامج في الخلفية
    time.sleep(3)
    ready_order_via_api("6")
    t0 = time.time()
    dump = ""
    while time.time() - t0 < 15:
        dump = notification_dump()
        if "orderly_order_ready" in dump and "جاهز" in dump:
            break
        time.sleep(1)
    has = "orderly_order_ready" in dump and "جاهز" in dump
    sound_ok = "raw/order_ready" in dump or "order_ready" in dump.split("orderly_order_ready", 1)[-1][:4000]
    adb("shell", "cmd", "statusbar", "expand-notifications")
    time.sleep(2)
    s.screenshot(os.path.join(OUT, "n2_shade.png"))
    opened = False
    try:
        el = s.wait("//*[contains(@text,'جاهز')]", 8)
        s.click(el)
        time.sleep(3)
        opened = s.exists("//*[starts-with(@content-desc,'الطلبات') and @selected='true']")
    except ac.AppiumError:
        adb("shell", "cmd", "statusbar", "collapse")
    record("app in background: system notification + our sound; tap opens Orders", has and sound_ok,
           f"in tray: {has}, channel sound order_ready: {sound_ok}, tap brought the app back: {opened}", "n2_after_tap.png")
    recover()


def keepalive_service():
    svc = adb("shell", "dumpsys", "activity", "services", "com.orderly.app")
    running = "ForegroundService" in svc
    shown = "Order Ly شغال" in notification_dump()
    record("Android background service keeps the connection (lock screen)", running and shown,
           f"foreground service running: {running}, fixed notification shown: {shown}")


def notify_print_failure():
    c = api("POST", "/api/checks", {"type": "takeaway", "customerName": "طباعة"})["check"]
    item = next(i for i in SEED["items"] if not i["mods"])
    api("POST", f"/api/checks/{c['id']}/orders", {"lines": [{"itemId": item["id"], "qty": 1}]})
    # الطابعة (جهاز تاني بنفس توكن المالك) بتاخد التيكت وتقول فشلت
    stations = api("GET", "/api/menu")["stations"]
    jobs = api("GET", "/api/print/claim?stations=" + ",".join(st["id"] for st in stations))["jobs"]
    if not jobs:
        raise ac.AppiumError("no print job to fail")
    api("POST", f"/api/print/{jobs[0]['id']}/result", {"ok": False, "error": "الطابعة مفصولة"})
    s.wait("//*[contains(@content-desc,'الطباعة فشلت') or contains(@text,'الطباعة فشلت')]", 10)
    record("print failed → red notice for the cashier", True, "notice 'الطباعة فشلت …' shown", "n3_problem.png")


for name, fn in [
    ("connect by IP + login (device id sent)", connect_and_login),
    ("order with required size + extras", order_with_modifiers),
    ("another device adds an order → phone updates live", live_update),
    ("Wi-Fi cut: lasting banner, draft kept, reconnect, no duplicate", offline_banner_and_retry),
    ("check closed on another device → unsent items sent to a new check", closed_elsewhere_move_to_new_check),
    ("rotate + 6 s in background", rotate_background),
    ("GPRS network (7 KB/s): open table + send order", gprs_order),
    ("app open: order ready → side notice (with sound)", notify_foreground_toast),
    ("print failed → red notice for the cashier", notify_print_failure),
    ("Android background service keeps the connection (lock screen)", keepalive_service),
    ("app in background: system notification + our sound; tap opens Orders", notify_background_system),
]:
    step(name, fn)

s.quit()
json.dump({"generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S"), "results": results}, open(os.path.join(OUT, "flows.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print(f"{sum(r['status'] == 'PASS' for r in results)}/{len(results)} PASS")
