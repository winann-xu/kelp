# M1 验收记录：公网节点（进行中）

状态：**hub 已部署常驻；安全组已由用户放行（11010 已验证连通）；组装端节点时发现并修复参数笔误**（2026-09-19 22:0x~22:3x）

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
