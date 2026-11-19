"""Tiny Appium (W3C WebDriver) client using only the Python standard library.

Used by run_flows.py. Talks to a local Appium server (UiAutomator2 driver).
Flutter widgets show up through Android accessibility: buttons/texts carry their label
in content-desc or text, text fields are android.widget.EditText.
"""
import base64
import json
import time
import urllib.error
import urllib.request

APPIUM = "http://127.0.0.1:4723"
W3C_ELEMENT = "element-6066-11e4-a52e-4f735466cecf"


class AppiumError(Exception):
    pass


def _call(method, path, body=None, timeout=120):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(APPIUM + path, data=data, method=method, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read() or b"{}").get("value")
    except urllib.error.HTTPError as e:
        raise AppiumError(f"{method} {path}: {e.code} {e.read()[:400]!r}") from None


class Session:
    def __init__(self, caps):
        v = _call("POST", "/session", {"capabilities": {"alwaysMatch": caps}}, timeout=600)
        self.id = v["sessionId"]

    def _p(self, path):
        return f"/session/{self.id}{path}"

    def quit(self):
        try:
            _call("DELETE", self._p(""))
        except Exception:
            pass

    def find_all(self, xpath):
        return [e[W3C_ELEMENT] for e in _call("POST", self._p("/elements"), {"using": "xpath", "value": xpath})]

    def wait(self, xpath, timeout=30):
        end = time.time() + timeout
        while time.time() < end:
            found = self.find_all(xpath)
            if found:
                return found[0]
            time.sleep(0.5)
        raise AppiumError(f"not found within {timeout}s: {xpath}")

    def exists(self, xpath):
        return bool(self.find_all(xpath))

    def click(self, el):
        _call("POST", self._p(f"/element/{el}/click"), {})

    def type(self, el, text):
        self.click(el)
        _call("POST", self._p(f"/element/{el}/clear"), {})
        _call("POST", self._p(f"/element/{el}/value"), {"text": text})

    def attr(self, el, name):
        return _call("GET", self._p(f"/element/{el}/attribute/{name}"))

    def source(self):
        return _call("GET", self._p("/source"))

    def screenshot(self, path):
        with open(path, "wb") as f:
            f.write(base64.b64decode(_call("GET", self._p("/screenshot"))))

    def back(self):
        _call("POST", self._p("/back"), {})

    def shell(self, command, args=()):
        return _call("POST", self._p("/execute/sync"), {"script": "mobile: shell", "args": [{"command": command, "args": list(args)}]})

    def rotate(self, orientation):
        _call("POST", self._p("/orientation"), {"orientation": orientation})

    def background(self, seconds):
        _call("POST", self._p("/execute/sync"), {"script": "mobile: backgroundApp", "args": [{"seconds": seconds}]})


def label(text):
    """XPath for any element whose text or content-desc contains [text]."""
    t = text.replace("'", "&apos;")
    return f"//*[contains(@content-desc,'{t}') or contains(@text,'{t}')]"
