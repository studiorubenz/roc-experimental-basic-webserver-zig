import socket, base64, hashlib, os, struct, sys

HOST, PORT = "localhost", 8000

def handshake(sock, path="/ws"):
    key = base64.b64encode(os.urandom(16)).decode()
    req = (f"GET {path} HTTP/1.1\r\nHost: {HOST}:{PORT}\r\nUpgrade: websocket\r\n"
           f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
    sock.sendall(req.encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        resp += sock.recv(4096)
    head = resp.decode(errors="replace")
    assert "101 Switching Protocols" in head, head
    expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    assert f"Sec-WebSocket-Accept: {expected}" in head, head
    return "handshake OK (accept key verified)"

def send_text(sock, text):
    payload = text.encode()
    mask = os.urandom(4)
    header = bytes([0x81])
    n = len(payload)
    if n < 126: header += bytes([0x80 | n])
    elif n <= 0xFFFF: header += bytes([0x80 | 126]) + struct.pack(">H", n)
    else: header += bytes([0x80 | 127]) + struct.pack(">Q", n)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(header + mask + masked)

def recv_exact(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        assert chunk, "connection closed"
        data += chunk
    return data

def recv_frame(sock):
    b0, b1 = recv_exact(sock, 2)
    opcode = b0 & 0x0F
    n = b1 & 0x7F
    if n == 126: n = struct.unpack(">H", recv_exact(sock, 2))[0]
    elif n == 127: n = struct.unpack(">Q", recv_exact(sock, 8))[0]
    assert not (b1 & 0x80), "server frames must be unmasked"
    return opcode, recv_exact(sock, n)

