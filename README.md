# 海带 (Kelp)

自建的异地组网 + 远程访问系统：把两个异地局域网、一堆不装客户端的设备（电视 / AppleTV / 办公电脑）和手机，统一收进一张可控的私有网络里。用于替代商业软件"节点小宝"免费版的设备数与穿透限制。

仓库：<https://github.com/winann-xu/kelp>（公开，不含任何凭据）。核心不自研网络协议——直接用 [EasyTier](https://github.com/EasyTier/EasyTier)（Apache-2.0，Rust）做组网，自研的只有"编排 + 护栏 + 面板 + 交付脚本"这一层。

## 一句话架构

```
【A 站点 家 192.168.50.0/24】                【公网节点（阿里云 ECS）】
 Mac / Windows(客户端)  ──┐                  EasyTier 私有节点 10.144.144.1:11010
 50.9 (站点节点/网关)  ───┼── EasyTier ────►  职责：信令 + 打洞协助 + 兜底中继
 电视/AppleTV（无客户端）─┘   子网代理 50 段        ├─ 只读面板 18080/HTTPS
       ↑ 网关/静态路由指向 50.9                    └─ WireGuard 门户 11013/udp（手机）
【B 站点 NAS 侧 192.168.1.0/24】
 飞牛 NAS / Windows ── EasyTier 节点(10.144.144.20) ── 子网代理 1 段
```

两条硬约束决定了整个设计：

1. **公网节点按流量计费（0.8 元/GB 出网）** ⇒ 节点只做信令与兜底，**常态必须 P2P 直连**；面板自带出网流量统计与阈值告警（默认 5 GB/日）。
2. **域名未备案** ⇒ 不做公网域名 Web 入口，全部访问走组网隧道（直连内网 IP / 组网 IP）。

## 状态

**M0–M4 五个里程碑全部验收通过（2026-09-19 ~ 2026-09-20）**，验收证据与原始输出见 [`docs/`](docs/)：

| 里程碑 | 内容 | 结论 |
|---|---|---|
| M0 | 勘测与骨架 | ✅ [docs/00-environment.md](docs/00-environment.md) |
| M1 | 公网私有节点上线（systemd 常驻） | ✅ [docs/M1-acceptance.md](docs/M1-acceptance.md) |
| M2 | 两站点组网 + 子网代理（P2P 路径证明 + 速率基线 17.6–18.1 Mbps） | ✅ [docs/M2-acceptance.md](docs/M2-acceptance.md) |
| M3 | 手机接入（原生客户端 / WireGuard 门户）+ 客户端分发页 | ✅ [docs/M3-acceptance.md](docs/M3-acceptance.md) |
| M4 | 网关模式（免客户端设备）+ 流量护栏 + 回滚演练 + 公网副作用基线 | ✅ [docs/M4-acceptance.md](docs/M4-acceptance.md) |

## 交付物件

| 物件 | 位置 | 说明 |
|---|---|---|
| 只读面板 | `scripts/panel/panel.py` + `panel_ui.html` + `kelp-panel.service` | Python 标准库零依赖、HTTPS、Basic 鉴权、期望名册比对判离线、中继预警、出网流量与费用估算；无人访问时自动停止远端轮询省流量 |
| 节点安装器 | `scripts/setup-node.sh` | 幂等：装二进制 + 写 600 身份文件 + systemd 单元 |
| 网关模式 | `scripts/gateway-mode.sh` | 免客户端设备接入：`ip_forward` + FORWARD 放行 + **SNAT**（必须，见下）；含 netns 自测与精确回滚 |
| B 站点（Docker） | `scripts/nas-b-node-run.sh` | 唯一权威启动参数（`--env-file` 变更必须重建容器，`docker restart` 不生效） |
| 手机接入 | `scripts/refresh-wg-phone-conf.sh` | 从门户取配置 → 写 600 → 生成二维码 → 推到鉴权区 → 端到端自测 |
| 密钥轮换 | `scripts/rotate-network-secret.sh` | 三节点同步换网络密钥（含备份与回滚材料） |
| 回滚手册 | [docs/rollback.md](docs/rollback.md) | 每个组件都有停止/卸载路径 |

## 面板「管理」页（唯一的可写入口）

`https://<hub>:18080/admin`（需登录，且每次动作都要再次输入当前口令）提供两件事：

| 功能 | 做了什么 | 影响面 |
|---|---|---|
| 修改面板登录口令 | 生成新 salt+sha256 写入 `/etc/kelp/panel.json`（改前备份），随后面板自我重启 | 只影响面板登录；本机 `~/.config/kelp/kelp.env` 里的口令要同步改 |
| 轮换组网网络密钥 | 公网 hub（本地改 env）→ A 站点 50.9（hub→50.9 走 SSH 公钥 + **限定范围的 sudo 白名单**跑 `kelp-apply-secret.sh`）→ 最后重建 B 站点容器（hub→NAS 用 `/etc/kelp/nas-access.env`（600 root））→ 校验组网 → 刷新门户配置 | 会短暂断线；**手机 / Mac / Windows 客户端里的密钥需手改** |

设计要点（为什么这么做）：

- **面板仍然只读为主**：写动作只有这两个，且都在 `/admin` 下、每次都要当前口令（顺带充当 CSRF 防护）。
- **认证只用公钥不落密码**：hub→50.9 用一次性生成的 `id_ed25519_kelp`；只有 hub→NAS 因为 fnOS 上 `admin` 的 home 不存在（`/home/admin` 缺失 ⇒ 无法放 authorized_keys），才用 600 凭据文件。撤销：删 `/etc/kelp/nas-access.env` 即可让该腿自动失败并给出提示。
- **换密钥的次序是刻意的**：先 hub、再 50.9、最后 NAS。因为 **重建 B 站点容器会掐断 hub→NAS 的隧道**（那条 SSH 正是穿过这个容器转发的），而且 fnOS 上重建要几分钟，所以 NAS 放最后 —— 万一慢/失败，前两台的密钥仍是一致的。相应地，NAS 这一步的判定不靠"命令返回成功"，而是事后轮询容器状态 + 容器内密钥前缀。

## 踩过的坑（都写进文档与脚本了）

- **网关模式必须 SNAT**：只开 `ip_forward` + FORWARD 时 TCP 全不通，而 **ping 却能通**（EasyTier 对代理网段自行代答 ICMP）——"假通"。判据：**判断转发是否可用只能用 TCP，不能用 ping**。
- **浏览器可达性 ≠ curl 可达性**：`curl -k` 会完全遮住证书链问题；验证浏览器要嘛不带 `-k`、要嘛用浏览器引擎（`scripts/check-panel-in-browser.sh` 用 WKWebView，且**鉴权页必须带凭据**，否则会得到 `-1001` 假阴性）。
- **代理环境变量造成的假故障**：测试组网/内网目标必须 `--noproxy '*'`，否则一个挂掉的 `http_proxy` 会让所有探测显示"不通"。
- **`docker restart` 不重读 `--env-file`**；**hub 重启会让 WireGuard 门户密钥重生成**（手机配置失效，需重跑刷新脚本）。
- **换 B 站点密钥时不能同步等结果**：`docker rm -f` + `docker run` 会把控制它的 SSH 会话一起掐掉（隧道穿过该容器）——必须 `setsid` 派生执行 + 事后轮询（面板已如此实现）。
- **bash 在 UTF-8 locale 下会把全角字符当成变量名的一部分**：`$VAR（中文）` 会报 `unbound variable`，脚本里一律写 `${VAR}`（本项目 `scripts/rotate-network-secret.sh` 就踩过）。
- **公网节点是硬单点**：实测停掉后 3 秒内两站点间全部中断（含原本 P2P 直连的节点），重启 15 秒恢复。

## 凭据纪律

仓库内**不含任何凭据**。网络标识、各机登录口令、面板口令统一放在本机 `~/.config/kelp/`（权限 600，不进版本库），脚本一律通过环境变量/文件读取：

```
~/.config/kelp/kelp.env     # 网络名 / 网络密钥 / 面板地址与账号
~/.config/kelp/creds.env    # 各机 SSH 登录口令（脚本用）
~/.config/kelp/wg-phone.conf# 手机 WireGuard 配置（含私钥）
```

## 许可证

[MIT](LICENSE)（Copyright 2026 winann-xu）。第三方组件：EasyTier 为 Apache-2.0。

## 文档导航

- [项目任务书.md](项目任务书.md) —— 唯一权威：范围、铁律、功能需求、决策记录（D1–D30）
- [checkpoint.md](checkpoint.md) —— 跨会话交接锚点：当前状态、待办、逐轮日志
- [AGENT.md](AGENT.md) —— 编码/沟通规范
