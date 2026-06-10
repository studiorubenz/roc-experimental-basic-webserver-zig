"""HTTP battery for examples/app — the codified version of the manual
curl playbook (see IO-PORT-PLAN.md). Start the server first:

    ./build.sh app          # then, in another shell:
    python3 tests/test_http.py [port]

Asserts routing, encoding/escaping, and — via the /system page — every
platform effect (Env, Utc, Sleep, Random, File, Dir, Cmd) end to end.
"""

import re
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
BASE = f"http://localhost:{PORT}"
failures = []


def fetch(path, method="GET", data=None, headers=None):
    req = urllib.request.Request(
        BASE + path, data=data, method=method, headers=headers or {}
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as err:
        return err.code, err.read().decode("utf-8", "replace")


def check(name, condition, detail=""):
    print(f"  {'OK ' if condition else 'FAIL'} {name}" + (f" — {detail}" if not condition and detail else ""))
    if not condition:
        failures.append(name)


print("routing & encoding:")
status, body = fetch("/")
check("GET / is 200", status == 200)
status, body = fetch("/hello/J%C3%B6rg%20%26%20S%C3%B6hne")
check("URL decoding + HTML escaping", status == 200 and "Jörg &amp; Söhne" in body, body[:120])
status, body = fetch("/echo?msg=hi+there")
check("query string echo", status == 200 and "hi there" in body)
status, body = fetch("/echo", method="POST", data=b"msg=posted+%3Cb%3E")
check("POST form echo, escaped", status == 200 and "posted &lt;b&gt;" in body)
status, body = fetch("/headers", headers={"X-Probe": "roundtrip42"})
check("request header roundtrip", status == 200 and "roundtrip42" in body)
status, body = fetch("/api/hello/Johnny")
check("JSON endpoint", status == 200 and '"hello": "Johnny"' in body)
status, _ = fetch("/nope")
check("404 for unknown route", status == 404)
status, _ = fetch("/x", method="OPTIONS")
check("OPTIONS is 204", status == 204)

print("platform effects via /system:")
status, body = fetch("/system")
check("GET /system is 200", status == 200)
rows = dict(re.findall(r"<th>(.*?)</th><td>(.*?)</td>", body))
check("File roundtrip (write/read/append/delete + NotFound)",
      "OK, NotFound after delete OK" in rows.get("File roundtrip", ""), rows.get("File roundtrip"))
check("Dir roundtrip (create_all/create/list/delete_empty/delete_all)",
      "OK, NotFound after delete_all OK" in rows.get("Dir roundtrip", ""), rows.get("Dir roundtrip"))
cmd_row = rows.get("Cmd roundtrip", "")
check("Cmd: capture, exit code, NotFound, env",
      "hello subprocess" in cmd_row and "exit 42 -&gt; 42" in cmd_row
      and "Err(NotFound)" in cmd_row and "env works" in cmd_row, cmd_row)
check("Env.var! finds HOME", rows.get("Env.var!(&quot;HOME&quot;)", "").startswith("/"))
check("Env.var! reports unset name",
      "VarNotFound(SURELY_NOT_SET_XYZ)" in rows.get("Env.var! on an unset name", ""))
check("Utc.now! is sane (year >= 2026)",
      int(rows.get("Utc.now! (nanos since epoch)", "0")) > 1_767_000_000 * 10**9)
check("Sleep.millis!(2) measured >= 2ms",
      int(rows.get("Sleep.millis!(2), measured", "0 ns").split()[0]) >= 2_000_000)

print("randomness & parallelism:")
_, body2 = fetch("/system")
rows2 = dict(re.findall(r"<th>(.*?)</th><td>(.*?)</td>", body2))
check("Random seeds differ between requests",
      rows.get("Random.seed_u64!") != rows2.get("Random.seed_u64!"))
with ThreadPoolExecutor(max_workers=20) as pool:
    results = list(pool.map(lambda _: fetch("/system"), range(40)))
check("40 parallel /system all 200", all(s == 200 for s, _ in results))
check("no race failures in parallel bodies",
      not any(re.search(r"FAILED|content mismatch|still (exists|listable)", b) for _, b in results))

print()
if failures:
    print(f"{len(failures)} FAILURE(S): {failures}")
    sys.exit(1)
print("all HTTP battery checks passed")
