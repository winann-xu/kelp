#!/usr/bin/env python3
"""观察窗口：每 10 秒抓一次面板状态，记录出现 relay 的具体节点对（用于判断中继回落发生在哪一对）。

用法: bash 起停即可，日志打到 stdout（重定向到文件）。
凭据从 ~/.config/kelp/kelp.env 读（KELP_PANEL_*）。
"""
import base64
import json
import os
import ssl
import sys
import time
import urllib.request

ENV = os.path.expanduser("~/.config/kelp/kelp.env")
cfg = {}
for line in open(ENV, encoding="utf-8"):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        cfg[k.strip()] = v.strip().strip('"').strip("'")

URL = cfg["KELP_PANEL_URL"].replace("http:", "https:").rstrip("/") + "/api/status"
AUTH = "Basic " + base64.b64encode(f"{cfg['KELP_PANEL_USER']}:{cfg['KELP_PANEL_PASS']}".encode()).decode()
CTX = ssl._create_unverified_context()
ROUNDS = int(sys.argv[1]) if len(sys.argv) > 1 else 12
GAP = float(sys.argv[2]) if len(sys.argv) > 2 else 10.0

for i in range(ROUNDS):
    try:
        req = urllib.request.Request(URL, headers={"Authorization": AUTH})
        d = json.load(urllib.request.urlopen(req, context=CTX, timeout=25))
        bad = []
        for n in d["nodes"]:
            for p in n["peers"]:
                if p["cost"] == "relay":
                    bad.append(f"{n['key']}→{p['ipv4']}({p['hostname']}) rx={p['rx']} lat={p['lat_ms']}")
        s = d["summary"]
        ts = time.strftime("%H:%M:%S")
        print(f"[{ts}] online={s['online']}/{s['total']} p2p={s['p2p']} relay={s['relay']} "
              f"| {' ; '.join(bad) if bad else '全部 P2P'}", flush=True)
    except Exception as exc:  # 面板偶尔超时不算致命
        print(f"[{time.strftime('%H:%M:%S')}] 抓取失败: {exc}", flush=True)
    time.sleep(GAP)
