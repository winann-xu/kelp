# M2 验收记录：两站点组网 + 子网代理（✅ 完成）

完成时间：2026-09-19 22:5x　|　证据全部为实测原始输出

## 1. 拓扑（实测）

```
【A 站点 192.168.50.0/24 中国移动】        【公网节点 47.116.73.216 上海】
  kelp-50-9  10.144.144.9  ────┐            kelp-hub  10.144.144.1
  爱快/ Mac(50.10)/ 电视等      ├── EasyTier ── 组网 IP 10.144.144.1
                               │   P2P 直连    仅信令 + 兜底中继
【B 站点 192.168.1.0/24 中国电信】            （按流量计费 0.8 元/GB）
  kelp-nas  10.144.144.20 ─────┘
  飞牛 NAS(192.168.1.99/.100)、网关 192.168.1.1
```

## 2. 三个节点全部 P2P 直连（hub 视角）

```
| ipv4             | hostname  | cost | lat(ms) | loss | tunnel | NAT            | version        |
| 10.144.144.1/24  | kelp-hub  | Local| -       | -    | -      | PortRestricted | 2.6.4-8428a89d |
| 10.144.144.9/24  | kelp-50-9 | p2p  | 15.59   | 0.0% | tcp    | PortRestricted | 2.6.4-8428a89d |
| 10.144.144.20/24 | kelp-nas  | p2p  | 14.79   | 0.0% | tcp    | PortRestricted | 2.6.4-8428a89d |
```

路由表同时收录两个站点的代理网段：

```
| 10.144.144.9/24  | kelp-50-9 | 192.168.50.0/24 | DIRECT |
| 10.144.144.20/24 | kelp-nas  | 192.168.1.0/24  | DIRECT |
```

## 3. 子网代理穿透（双向实测，未改任何系统转发设置）

| 方向 | 测试 | 结果 |
|---|---|---|
| 上海 hub → A 站点 LAN | `ping 192.168.50.1/.10/.9` | 全通 |
| 上海 hub → A 站点服务 | `https://192.168.50.9/` | HTTP 401（ollama nginx 鉴权，链路真实可用） |
| 上海 hub → B 站点 LAN | `ping 192.168.1.1/.99/.100` | 全通 |
| 上海 hub → B 站点服务 | `https://192.168.1.99:5667/` | HTTP 200（飞牛 fnOS 登录页） |
| **B → A（反向）** | NAS 上 `nc 192.168.50.9:22 / :443`、`192.168.50.10:22` | 全部 OPEN |
| **B → A 服务** | NAS 上 `curl -k https://192.168.50.9/` | 401 @ 0.11s |

> 结论（D16）：**50.9 与 NAS 的 `net.ipv4.ip_forward` 均保持默认、未加任何 iptables 规则**，EasyTier 在用户态完成跨网段转发。铁律 §6.4 未触发。

## 4. 跨站点路径：从中继修正为 P2P（重要）

| 阶段 | NAS 视角看 50.9 | 说明 |
|---|---|---|
| 初始 | `relay(2)` · 30.00ms · tunnel 空 | 两站点打洞未成，流量将经上海 hub 转发 = **按 0.8 元/GB 计费** |
| 加 `--need-p2p true` 后 | **`p2p` · 21.48ms · tunnel udp** | 直连成立，**跨站点流量不再计费** |

处置：NAS 节点容器已带 `--need-p2p true`（见 §6）。建议 50.9 与 hub 也补该参数（下次 sudo 窗口一并处理，与非 RPC 白名单修正同批）。

## 5. 速率基线（跨站点 P2P，NAS → 50.9，TCP 单流）

```
received 52.4 MB in 23.86s = 17.6 Mbps  (path 10.144.144.20:9002)
```

- 量级与 B 站点家宽上行相当（约 20 Mbps 档），说明链路不再是瓶颈
- 测试脚本：`scripts/net-throughput-server.py` / `scripts/net-throughput-client.py`（可复用于 M3 手机端基线）

## 6. B 站点（飞牛 NAS）部署细节

| 项 | 值 |
|---|---|
| 入口 | 用户开通 fnOS SSH，端口 **48032**；账号 admin 属 **docker 组**（无需 sudo 即可管容器） |
| 主机 | fn-nas，Linux 6.18.18 x86_64，3794 MB RAM，/ 剩余 45G；双网卡 192.168.1.99 / .100 |
| 镜像 | Docker Hub 直连不通，走 fnOS 镜像站前缀 `docker.1ms.run/easytier/easytier:latest`（内含 **2.6.4**，与 hub/50.9 同版本） |
| 容器 | `kelp-b-node`，`--restart unless-stopped`、`--network host`、`--cap-add NET_ADMIN`、`--device /dev/net/tun` |
| 参数 | `--hostname kelp-nas --ipv4 10.144.144.20 --proxy-networks 192.168.1.0/24 --peers tcp://47.116.73.216:11010 --rpc-portal 0.0.0.0:15888 --rpc-portal-whitelist 127.0.0.1,10.144.144.1 --private-mode true --need-p2p true` |
| 凭据 | 网络名/密钥经 `--env-file /vol1/kelp/b.env`（600）注入，未写入命令行与镜像 |
| 运维命令 | `docker logs kelp-b-node` / `docker restart kelp-b-node` / `docker exec kelp-b-node easytier-cli peer` |

## 7. 面板覆盖（FR9）

面板已加入 B 站点节点与设备，`/api/status` 汇总实测：

```
{'total': 3, 'online': 3, 'expect': 3, 'expect_total': 3, 'p2p': 3, 'relay': 0, 'rx_total': '1.12 MB', 'tx_total': '1.20 MB'}
 设备: 公网节点 10.144.144.1  online p2p 16.08 ms
 设备: 家里服务器 10.144.144.9 online p2p 15.77 ms
 设备: 飞牛 NAS 10.144.144.20 online p2p 15.63 ms
```

## 8. 遗留

- [ ] 50.9 / hub 补 `--need-p2p`（可选，防跨站点回落到中继）
- [ ] 50.9 的 RPC 白名单补 `127.0.0.1`（便于本机 CLI 查询）
- [ ] B 站点入口依赖 fnOS SSH 常开（48032）；若关闭则节点仍在跑但无法远程维护
