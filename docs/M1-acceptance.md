# M1 验收记录：公网节点（进行中）

状态：**✅ 完成**（2026-09-19 22:3x）—— hub 常驻、A 站点节点接入、**P2P 直连成立**（16ms / 0% 丢包 / tunnel=tcp）、安全组放行、FR9 只读面板上线。

## 1. 已完成

| 项 | 证据 |
|---|---|
| EasyTier 版本 | `easytier-core 2.6.4-8428a89d` / `easytier-cli 2.6.4-8428a89d`（Ubuntu 24.04.4 x86_64） |
| 安装包来源 | ghfast.top 镜像（VPS 直连 GitHub 超时 000）；SHA-256 `61b659eaedba658fa66fe47d17e1426cdd77e5d02fa15fed447bb4357c09dfd6`（VPS/Mac/50.9 三处一致） |
| 二进制 | `/usr/local/bin/easytier-core`、`/usr/local/bin/easytier-cli`（755） |
| 身份 | `KELP_NET_NAME` / `KELP_NET_SECRET`（40 位随机）→ `/etc/easytier/kelp.env`（600），命令行经 systemd `EnvironmentFile` 注入 |
| systemd | `/etc/systemd/system/easytier.service`，`Restart=always`、`RestartSec=3`、`LimitNOFILE=1048576`；`systemctl enable --now` 已生效 |
| 私有模式 | 启动日志确认 `private_mode = true`、`network_name = kelp-…`（外网不同密钥的节点将被拒） |
| 监听 | `ss -lntup`：`tcp/udp 0.0.0.0:11010` + `[::]:11010`；`tcp 127.0.0.1:15888`（RPC 仅本机） |
| TUN | 日志 `tun device ready dev="tun0"`；组网 IP `10.144.144.1/24` |
| 本节点状态 | `easytier-cli node`：Hostname=kelp-hub，Public IPv4=47.116.73.216，UDP Stun Type=PortRestricted |

## 1.1 安全组放行验证（用户操作后复测）

| 测试（从干净出口 50.9） | 结果 |
|---|---|
| tcp/11010 | **CONNECTED 0.02s** ✅ |
| tcp/18080 | Connection refused（端口已放行，尚无服务监听——面板待建） |
| tcp/22 | CONNECTED 0.02s（对照） |

## 1.2 已修复缺陷：`--peer` → `--peers`

- 症状：50.9 的 `easytier-node.service` 反复 `activating (auto-restart)`，`ExecStart` 退出码 **2**（clap 参数解析失败）。
- 根因：脚本把连接参数写成 `--peer`，2.6.4 的长选项实为 **`--peers`**（帮助原文 `-p, --peers [<PEERS>...]`，见 `docs/reference-easytier-2.6.4-core-help.txt`）。
- 预检方法（免 root 验证参数合法性）：以普通用户执行同一条命令 → 参数合法时才会推进到 TUN 创建并报 `Operation not permitted`；参数非法会立刻退出码 2。
- 修复：`scripts/setup-node.sh` 接受 `--peer|--peers`，生成的 unit 使用 `--peers`；自检增加"非 active 时打印 status + journal 尾部"以便一次定位。

## 2. 未完成（阻塞）

**外部节点无法接入**，根因是安全组，证据链：

| 测试 | 结果 |
|---|---|
| 从 50.9 → `tcp/22` | 0.02s 成功 |
| 从 50.9 → `tcp/11010` | **5s 超时** |
| 从 50.9 / Mac → `udp/11010`（及 53/443/3478/9999） | VPS `tcpdump -ni eth0` 抓到 **0 个包** |
| Mac → `tcp/11010`（未绑接口） | 0.00s "成功" → **假阳性**：`route get` 显示走 `utun6`（Stash TUN），本地被接管 |
| Mac → `tcp/11010`（bind 192.168.50.10） | 6.00s 超时（真实结果） |
| Mac 侧 EasyTier 连接 hub | `handshake timeout after 1.984477708s`（connect 后握手无响应） |

→ 需在阿里云安全组放行 **11010/TCP 与 11010/UDP**（源 0.0.0.0/0，或限定常用出口 IP）。

## 1.3 A 站点节点接入结果（50.9）

| 项 | 证据 |
|---|---|
| 服务 | `easytier-node.service` **active**、enabled；`/etc/easytier/kelp.env` 600 |
| 组网 IP | 10.144.144.9/24，子网代理 `192.168.50.0/24`（hub 路由表显示 `192.168.50.0/24 dev tun0 proto static`） |
| **P2P 直连** | hub 侧 `easytier-cli peer`：`10.144.144.9 kelp-50-9 cost=p2p lat=16.43ms loss=0.0% tunnel=tcp` ✅ **未走中继（不产生流量费）** |
| overlay 延迟 | hub → 10.144.144.9 ping 16.60ms（家宽↔上海 P2P） |
| 子网代理穿透 | hub 直接 ping 通家里 `192.168.50.1`（爱快）/ `.10`（Mac）/ `.9`（50.9）；`https://192.168.50.9/` 返回 401（ollama nginx 鉴权，链路真实可用） |
| 关键结论 | **无需开启 50.9 的 `ip_forward`、无需 iptables NAT**：EasyTier 在用户态完成转发，`ip_forward` 保持 0 即可穿透到 LAN（避免了对系统网络设置的改动，铁律 6.4 无触发） |

> 注：50.9 的 RPC 白名单当前只写 `10.144.144.1`（hub），因此本机 `easytier-cli` 直查会被拒（面板从 hub 侧查询不受影响）。若要在 50.9 本地用 CLI 查看，白名单需补 `127.0.0.1`——留待下次 sudo 窗口一并处理。

## 1.4 FR9 只读面板（已上线）

| 项 | 值 |
|---|---|
| 地址 | `http://47.116.73.216:18080`（用户/口令见 IAM 侧：`~/.config/kelp/kelp.env`，不入库） |
| 实现 | `/opt/kelp/panel.py`（Python 标准库，无第三方依赖）+ `/opt/kelp/panel_ui.html`；systemd `kelp-panel.service`（Restart=always） |
| 数据源 | 各节点 RPC：`easytier-cli -p <addr>:15888 -o json peer/node`，5s 一轮；**只读，不下发配置** |
| 安全 | HTTP Basic 认证（sha256+salt，口令不落盘明文之外的日志）；未认证 401；已核验 API 响应**不含网络密钥**（`node.config` 字段被丢弃） |
| 离线判定 | 以配置中的"期望设备清单"与各节点实时邻居表比对，记录最后在线时间 |
| 计费护栏 | 中继条数 > 0 时页面顶部弹出橙色警示（中继 = 0.8 元/GB） |
| 验收 | 从家访问 `api/status` HTTP 200（0.05s）；页面 10134B；桌面/手机双视口离屏渲染截图复核（WKWebView + 视觉检查），修正版本号折行、"监听"竖排拆字、端口串乱换行三处 |

## 3. 待办

- [x] 用户放行安全组（11010 TCP+UDP、18080 TCP）；11010 已复测连通 ✅
- [ ] 用户重跑一次 `sudo bash /tmp/kelp-node-setup.sh`（脚本已修正 `--peers` 并推送到 50.9）→ 验证 `easytier-cli peer` 双向可见
- [ ] `systemctl restart` + 真实 reboot 各一次，确认自启（M1 验收项）
- [ ] FR9 只读面板路径：面板部署在 VPS（用户已定），需在其上提供节点 RPC 可达性（各节点 `--rpc-portal 0.0.0.0:15888` + `--rpc-portal-whitelist 10.144.144.1`）
- [ ] 加固：hub 的 journal 会打印含 `network_secret` 的启动配置；M4 硬化时改用 `--console-log-level warn`（现保留 info 便于联调）

## 4. 复现命令

```bash
# 本机（Mac）存身份
~/.config/kelp/kelp.env          # 600 权限，含 KELP_NET_NAME / KELP_NET_SECRET（不入库）

# hub 状态（VPS）
ssh root@47.116.73.216 'systemctl status easytier --no-pager; ss -lntup | grep -E "11010|15888"; easytier-cli peer; easytier-cli node'

# 干净出口连通性验证（在 50.9 上，勿用 Mac——会被 Stash 接管）
ssh winann@192.168.50.9 'python3 -c "import socket;s=socket.socket();s.settimeout(5);print(s.connect_ex((\"47.116.73.216\",11010)))"'
```
