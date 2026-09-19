#!/usr/bin/env python3
"""海带 (Kelp) 组网速率基线 - 发送端

用法: python3 net-throughput-server.py <listen_port> <megabytes>
监听一个连接，连接建立后连续发送 N MB，随后输出耗时与速率。
"""
import socket
import sys
import time

CHUNK = 1024 * 1024


def main() -> None:
    port = int(sys.argv[1])
    megabytes = float(sys.argv[2])
    total = int(megabytes * CHUNK)
    payload = b"k" * CHUNK

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(1)
    print(f"listening on 0.0.0.0:{port}, will send {megabytes} MB", flush=True)

    conn, addr = srv.accept()
    print(f"client {addr[0]} connected", flush=True)
    started = time.time()
    sent = 0
    try:
        while sent < total:
            n = conn.send(payload if total - sent >= CHUNK else payload[: total - sent])
            sent += n
    finally:
        conn.close()
        srv.close()
    elapsed = time.time() - started
    print(f"sent {sent / 1e6:.1f} MB in {elapsed:.2f}s = {sent * 8 / elapsed / 1e6:.1f} Mbps", flush=True)


if __name__ == "__main__":
    main()
