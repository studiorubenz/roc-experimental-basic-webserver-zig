import socket, base64, hashlib, os, struct, threading, sys
sys.path.insert(0, os.path.dirname(__file__))
HOST, PORT = "localhost", 8000
from wstest_helpers import handshake, send_text, recv_frame  # reuse helpers

results = []
def client(n):
    s = socket.create_connection((HOST, PORT), timeout=10)
    handshake(s)
    for i in range(20):
        send_text(s, f"client{n} msg{i}")
        op, data = recv_frame(s)
        assert data.decode() == f"echo: client{n} msg{i}", (n, i, data)
    results.append(n)
    s.close()

threads = [threading.Thread(target=client, args=(i,)) for i in range(4)]
[t.start() for t in threads]
[t.join() for t in threads]
print(f"{len(results)}/4 concurrent ws clients OK (80 messages)")
