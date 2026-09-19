#!/usr/bin/env python3
"""海带 (Kelp) 组网速率基线 - 接收端

用法: python3 net-throughput-client.py <host> <port>
连接目标端口，读到 EOF，输出接收量与实测速率。
"""
import socket
import sys
import time


def main() -> None:
    host = sys.argv[1]
    port = int(sys.argv[2])

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(120)
    started = time.time()
    sock.connect((host, port))
    received = 0
    while True:
        data = sock.recv(1 << 16)
        if not data:
            break
        received += len(data)
    elapsed = time.time() - started
    sock.close()
    print(f"received {received / 1e6:.1f} MB in {elapsed:.2f}s = "
          f"{received * 8 / elapsed / 1e6:.1f} Mbps  (path {host}:{port})", flush=True)


if __name__ == "__main__":
    main()
