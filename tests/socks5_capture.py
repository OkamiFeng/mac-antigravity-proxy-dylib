#!/usr/bin/env python3
import socket
import struct
import sys


def recv_exact(conn, size):
    data = b""
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            raise RuntimeError("connection closed")
        data += chunk
    return data


def main():
    host = "127.0.0.1"
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18080

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((host, port))
    server.listen(1)
    print(f"listening {host}:{port}", flush=True)

    conn, _ = server.accept()
    with conn:
        header = recv_exact(conn, 2)
        version, methods_len = header[0], header[1]
        methods = recv_exact(conn, methods_len)
        if version != 5 or 0 not in methods:
            raise RuntimeError("unsupported greeting")
        conn.sendall(b"\x05\x00")

        req = recv_exact(conn, 4)
        version, command, _, atyp = req
        if version != 5 or command != 1:
            raise RuntimeError("unsupported request")

        if atyp == 1:
            dst = socket.inet_ntop(socket.AF_INET, recv_exact(conn, 4))
        elif atyp == 3:
            length = recv_exact(conn, 1)[0]
            dst = recv_exact(conn, length).decode("utf-8", "replace")
        elif atyp == 4:
            dst = socket.inet_ntop(socket.AF_INET6, recv_exact(conn, 16))
        else:
            raise RuntimeError("unsupported address type")

        dst_port = struct.unpack("!H", recv_exact(conn, 2))[0]
        print(f"captured {dst}:{dst_port}", flush=True)
        conn.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")

    server.close()


if __name__ == "__main__":
    main()
