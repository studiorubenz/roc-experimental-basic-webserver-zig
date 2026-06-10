import os, socket, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from wstest_helpers import handshake, send_text, recv_frame

def client(name):
    s = socket.create_connection(("localhost", 8000), timeout=10)
    handshake(s)
    send_text(s, name + "\t/joined")
    return s

a = client("ada"); time.sleep(0.2)
b = client("bob"); time.sleep(0.2)
c = client("cyd"); time.sleep(0.2)

# everyone drains their join traffic (ada sees 3 joins incl. own welcome reply...)
def drain(s, n):
    msgs = []
    s.settimeout(2)
    try:
        for _ in range(n): msgs.append(recv_frame(s)[1].decode())
    except Exception: pass
    return msgs

print("ada join-phase:", drain(a, 4))
print("bob join-phase:", drain(b, 3))
print("cyd join-phase:", drain(c, 2))

# ada says something -> all three receive it
send_text(a, "ada\thello <everyone>")
expected = "<b>ada:</b> hello &lt;everyone&gt;"
for who, s in [("ada", a), ("bob", b), ("cyd", c)]:
    op, data = recv_frame(s)
    got = data.decode()
    print(f"{who} got: {got!r} [{'OK' if got == expected else 'FAIL'}]")

# /help is private to bob: ada must NOT receive anything
send_text(b, "bob\t/help")
op, data = recv_frame(b)
print(f"bob /help reply: {data.decode()!r} [{'OK' if 'commands:' in data.decode() else 'FAIL'}]")
a.settimeout(1.5)
try:
    op, data = recv_frame(a)
    print(f"ada unexpectedly got: {data.decode()!r} [FAIL]")
except Exception:
    print("ada got nothing for bob's /help [OK]")

# /me action broadcast
send_text(c, "cyd\t/me waves")
for who, s in [("ada", a), ("bob", b), ("cyd", c)]:
    s.settimeout(3)
    op, data = recv_frame(s)
    got = data.decode()
    print(f"{who} got: {got!r} [{'OK' if got == '* cyd waves' else 'FAIL'}]")

for s in (a, b, c): s.close()
print("chat broadcast tests done")
