# M3 验收记录：手机接入（机器侧全部完成 ✅　仅剩"用户手机真机测试"）

执行时间：2026-09-19 23:4x – 2026-09-20 00:2x　|　证据均为实测原始输出
安全组 `11013/UDP`：用户已开通 → 已由**外部真客户端**实证可达（见 §2.5）

## 1. 方案选择（手机侧两条路）

| 路径 | 怎么做 | 计费影响 | 适用 |
|---|---|---|---|
| **A. WireGuard 门户**（本次已部署） | 公网节点开 WG 服务端，手机装官方 WireGuard App 扫二维码导入 | ⚠️ 手机流量**全部经公网节点转发** = 出网 0.8 元/GB | iOS（原生 App 在外区 App Store，US$0.99）/ Android 也可 |
| B. 原生 EasyTier 客户端 | Android 装 APK（GitHub Release，v2.6.4）；iOS 需外区 Apple ID 装 `EasyTier-iOS` | **P2P 直连，不计费** | Android 首选；大流量场景首选 |

> 现状：iOS 侧原生 App「已在外区 App Store 上架，定价 US$0.99（补贴开发者账号费用）」——见官方 `guide/gui/easytier-ios.html`。因此 v1 按任务书既定路线：**iOS 走 WireGuard 门户，Android 可选原生 App**。

## 2. 已完成的部署与实测

### 2.1 公网节点开启 WireGuard 门户

```
--vpn-portal wg://0.0.0.0:11013/10.144.150.0/24      # 追加到 easytier.service（改前已备份 unit）
ss -lnup | grep 11013 → 0.0.0.0:11013 / [::]:11013  udp  LISTEN   ✅
```

### 2.2 客户端配置（由 `easytier-cli vpn-portal` 生成，助手补齐 Endpoint/MTU）

```
[Interface]
PrivateKey = <由门户生成，见本机 ~/.config/kelp/wg-phone.conf（600，不入库）>
Address = 10.144.150.2/24          # 门户网段 10.144.150.0/24 内自行分配
MTU = 1360                          # 与 EasyTier 隧道 MTU 对齐

[Peer]
PublicKey = <门户公钥，见同一文件>
AllowedIPs = 192.168.1.0/24, 192.168.50.0/24, 10.144.144.0/24, 10.144.150.0/24
Endpoint = 47.116.73.216:11013
PersistentKeepalive = 25
```

二维码（手机扫）：`~/kelp-run/wg-phone-qr.png`

### 2.3 端到端自测（在公网节点上用真 WireGuard 客户端接自己的门户）

```
wg show          → latest handshake: 3 seconds ago, transfer: 92 B received, 180 B sent
经隧道访问 NAS   → https://192.168.1.99:5667/  HTTP 200   （页面标题：飞牛 fnOS）
经隧道访问 A 站点→ https://192.168.50.9/       HTTP 401   （鉴权正常，链路真实）
隧道流量计数     → 收 19.8 KB / 发 6.1 KB
清理             → 接口删除、配置删除；主机到 NAS 的原路由仍为 `dev tun0`（未被扰动）✅
```

> 说明：测试时 AllowedIPs 只放 `192.168.1.99/32, 192.168.50.9/32`，避免覆盖主机自身到 NAS 的路由；正式手机配置用整段。

### 2.4 面板新增「移动端接入」区块（FR9 延伸）

- 数据源：对标记了 `vpn_portal` 的节点执行 `easytier-cli -o json vpn-portal`，取 `connected_clients`
- **只暴露客户端地址列表与数量，绝不下发 `client_config`（内含客户端私钥）**
- 卡片同时写明「此段流量计费 0.8 元/GB」，与 FR7 流量护栏呼应
- 实测：测试客户端在线时面板显示 `count=1 / wg://127.0.0.1:42239`；断开后归零 ✅

### 2.5 公网可达性实证（从外部机器用真 WireGuard 客户端接入 —— 2026-09-20 00:1x）

自测点：`192.168.50.9`（Ubuntu 20.04 / 内核 5.15，真实外网出口）。为**零污染**，全程在**网络命名空间**内进行（不碰宿主路由、不碰海带组网路由），脚本：`scripts/diag-wg-portal-external.sh`

```
=== 1) 建命名空间 + veth + 出网 SNAT ===
  netns → 宿主 veth: 通
=== 2) 在命名空间内拉起 WireGuard 客户端（真走公网到 47.116.73.216:11013）===
  peer: <PORTAL-PUBKEY-FROM-CLI>
    endpoint: 47.116.73.216:11013
    latest handshake: Now          ← 公网 UDP 11013 通（安全组确实放行）
    transfer: 92 B received, 180 B sent
=== 3) 经隧道访问两个站点 ===
  B 站点·飞牛 NAS   200 0.131467s 4557B  标题: 飞牛 fnOS
  A 站点·50.9        401 0.137184s 38B
  隧道计数: 12712 B 收 / 4212 B 发
=== 4) 宿主路由未被扰动 ===
  宿主默认路由: default via 192.168.50.1 dev ens160 proto static metric 100   （与测试前一致）
  veth 出现在宿主默认路由: 0
=== 清理 ===
  SNAT 规则已删 / FORWARD 规则已删 / netns 已删 / veth 已删
  残留检查: netns=0  veth=0  WG路由=0          工具包已卸载（dpkg -P），模块已卸载
```

> 结论：**门户 + 安全组 + 公网路径三者均实证可用**，手机侧不再是"未知数"。
> 附带发现（已记入 50.9 代理问题）：50.9 的 `apt` 也被死代理 `192.168.50.12:10809` 挡死（`E: 无法下载 … 连接失败 [IP: 192.168.50.12 10809]`），本次用 `curl --noproxy '*'` 直取 deb + `dpkg -i` 绕过。这再次印证：**该机任何走 http_proxy 的工具都是坏的**。

### 2.6 客户端下载页（FR9 延伸 / 交付便利性）

公网节点新增两条路径，**面板本体仍强制鉴权**：

| 路径 | 鉴权 | 内容 |
|---|---|---|
| `https://47.116.73.216:18080/dl/` | **公开** | 各平台客户端下载页（含二维码、SHA-256 校验值） |
| `https://47.116.73.216:18080/wg/conf`、`/wg/qr.png` | **需登录** | 手机 WireGuard 配置（含私钥）与二维码 |

已托管文件（EasyTier v2.6.4，经 `ghfast.top` 取 GitHub 官方 Release，共 143 MB）：

| 文件 | 用途 | 大小 |
|---|---|---|
| `easytier-gui_2.6.4_x64-setup.exe` | Windows 图形界面 | 10.4 MB |
| `easytier-windows-x86_64-v2.6.4.zip` | Windows 命令行 | 31.1 MB |
| `easytier-gui_2.6.4_aarch64.dmg` | macOS Apple 芯片 | 12.2 MB |
| `easytier-gui_2.6.4_x64.dmg` | macOS Intel | 13.4 MB |
| `app-arm64-release.apk` | Android 64 位 | 29.9 MB |
| `app-arm-release.apk` | Android 32 位 | 21.4 MB |
| `easytier-linux-x86_64-v2.6.4.zip` | Linux 节点/服务端 | 24.3 MB |

实测：

```
HEAD /dl/easytier-gui_2.6.4_aarch64.dmg   → 200, Accept-Ranges: bytes
Range: bytes=0-1048575 (APK)              → 206, 1048576 bytes（支持断点续传）
Range: bytes=100-199                      → 206, 100 bytes
完整下载 Windows 安装包（外网真实路径）    → 200, 10942975 bytes, 435643 B/s ≈ 3.5 Mbps
  收到文件 sha256 前缀 0f92d378658fe5b5b150f6dbd06c0069… == 服务器声明值 ✅
越权探测 /dl/../../etc/passwd             → 401（未泄露）
/wg/conf 无凭据 → 401 ；有凭据 → 200 ✅
```

> ⚠️ **WireGuard 官方客户端安装包无法托管**：`download.wireguard.com`、`f-droid.org` 从国内及本机均不可达（实测超时/000），GitHub 上亦无官方 Release 资产。故下载页只给 App Store / Google Play / 官网链接，并明确标注「经公网节点 · 0.8 元/GB」。**Windows/macOS/Android 建议直接用 EasyTier 原生客户端（P2P，不计费）**，WireGuard 实际只为 iOS 服务。

### 2.7 面板在浏览器里打不开的定位与修复（2026-09-20 00:4x）

**现象**：手机能开（要手动点过证书警告），电脑浏览器打不开；但同一台 Mac 上 `curl` 秒开（连接 23ms、首字节 80ms）。

**定位过程（关键是对照实验）**：

| 测试 | 结果 | 说明 |
|---|---|---|
| Mac 上 `curl -sk` 面板 | 200，0.08–0.18s | 网络、TLS、服务全部正常 |
| Mac 上 `curl`（**不带 -k**，即做证书校验） | 000 | 证书不被信任 ⇒ 浏览器会拦 |
| `security verify-cert` 面板证书 | 成功（装信任前也"成功"，但 WebKit 仍拒绝） | 需要真正写入钥匙串信任 |
| **用 Safari 同引擎的 WKWebView、不做任何证书豁免** | **❌ NSURLErrorDomain -1001 超时** | **复现了浏览器打不开** |
| 同一 WKWebView 加载 baidu | ✅ | 证明测试工具本身没问题 |
| 把证书装进用户钥匙串信任后再测 | **✅ 加载成功，标题「海带 · Kelp 客户端下载」** | **根因确认：证书信任链** |

**结论**：浏览器（Chrome/Safari）走的是系统证书信任链，与 curl 的行为完全不同——curl 用自带 CA 包、且我全程加了 `-k`，所以一直"看起来正常"，把真问题遮住了。**判据更正：验证"网页在浏览器里能不能打开"必须用浏览器引擎（WKWebView/真浏览器或 `curl` 不带 `-k`），不能用 `curl -k` 的结论代替。**

**修复**：
1. 重签面板证书（`scripts/renew-panel-cert.sh`）：保留 SAN `IP:47.116.73.216`，新增 `IP:127.0.0.1`、`DNS:localhost`、`EKU=serverAuth`、`critical keyUsage`；旧证书就地备份为 `panel.{crt,key}.bak.20260920003424`。
2. 把证书装进用户钥匙串信任（用户 Mac）：`security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db kelp-panel.crt`；**撤销**：`security delete-certificate -c kelp-panel`。
3. 证书公开到下载页（`/dl/kelp-panel.crt`），页内给出 Windows/macOS/iOS 三平台导入步骤，供其他设备一次性消除警告。

### 2.8 面板内新增客户端下载入口（用户要求）

- 顶部导航新增高亮入口「⬇ 客户端下载」→ `/dl/`；
- 新增「客户端下载」区块：Windows / macOS(两种芯片) / Android 直链按钮 + 「全部文件/校验值/二维码」入口；
- 同区块并列「手机接入配置（WireGuard 门户）」：二维码 `/wg/qr.png` + 配置文件 `/wg/conf`（均需登录，含私钥不入公网）。

### 2.9 公网节点出网带宽实测（"慢"的根源）

| 下载方 | 速度 | 说明 |
|---|---|---|
| 家里 Mac（真实公网路径） | 435 KB/s ≈ 3.5 Mbps | 下 10.4MB 用 25s |
| 站点 50.9 | 127 KB/s ≈ 1 Mbps | 下同一个包用 86s |

面板页面本身只有 9.6KB（0.1s 级），所以"手机慢"不是面板的问题，而是**公网节点出网带宽只有 1–3.5 Mbps**（ECS 带宽配置所致）。影响：下载 143MB 客户端约需 6–20 分钟；面板日常浏览无感。要提速只有两条路：调高 ECS 带宽（要加钱），或把客户端包改从 NAS（家宽上传）分发。

### 2.10 网络密钥轮换（2026-09-20 09:5x，用户要求"改简短点"）

原密钥 32 字符随机串 → 新密钥 **新密钥（见各机 600 文件）**（已写入各机 600 文件与手机；不入库）。

| 位置 | 文件 | 改动方式 |
|---|---|---|
| 公网 hub | `/etc/easytier/kelp.env` | sed 改值 + `systemctl restart easytier` |
| A 站点 50.9 | `/etc/easytier/kelp.env` | sed 改值 + `systemctl restart easytier-node` |
| B 站点 NAS | `/vol1/kelp/b.env` | sed 改值 + **必须重建容器**（见下） |

轮换前后的实测：三节点全部回到在线；hub 视角 `kelp-50-9 p2p 17.6ms`、`kelp-nas p2p`；端到端 hub→NAS `HTTP 200 (0.062s)`、hub→50.9 `HTTP 401 (0.067s)` ✓
回滚材料：各机原文件 `.bak.20260920095231`、原密钥留存 `/root/kelp-secret-old.20260920095231.txt`（600）、本机 `~/kelp-run/secret-backup-20260920095231/`。

**踩到并已修复的三个坑（都已写进技能库）**：

1. **`docker restart` 不会重读 `--env-file`** ⚠️ —— 环境变量在容器创建时就固化，改 env 文件后必须 `docker rm -f` + 按原参数 `docker run` 重建。首轮轮换后 NAS 节点掉线就是这个原因（容器内仍是旧密钥，日志里不断 `connecting to peer ... peer removed`）。已产出唯一权威启动脚本 `scripts/nas-b-node-run.sh`（含 `--private-mode true` 等全部原参数，避免重建时漏参数）。
2. **hub 重启会让 WireGuard 门户重新生成密钥对** ⚠️ —— 手机上已导入的 WG 配置与二维码随即失效。已产出 `scripts/refresh-wg-phone-conf.sh`（拉取新配置→写 600 文件→重生成二维码→推到鉴权区→**用新配置做端到端自测**）。本次自测：`wg` 握手成功、经隧道访问 NAS `HTTP 200`。
3. **macOS 的 `grep` 不支持 `-P`，且解析密钥不能用 `=` 当分隔符** —— base64 结尾的 `=` 会被吃掉，密钥变 43 字符，`wg` 直接报 `Key is not the correct length`。改用 `sed -n 's/^PrivateKey[[:space:]]*=[[:space:]]*//p'`，并在脚本里加长度校验（必须 44）。

### 2.11 面板"无人访问即停止远端轮询"（省出网费，2026-09-20 10:0x）

发现：面板每 5 秒经组网向两个站点节点查 RPC，**空转时公网节点出网恒为 1807 B/s ≈ 149 MB/天 ≈ 0.11 元/天**（按 0.8 元/GB）。这在"按流量计费 + 常态 P2P"的架构里属于纯浪费。

改法：`refresh_once()` 增加空闲判定——**无人访问超过 120 秒时，只刷新本机(127.0.0.1)节点，远端节点沿用上次采样**（标记 `stale`）；有人访问时在 `/api/status` 里即时强制刷新一次，避免首屏旧值。

实测（同一节点、同一测法）：

| 状态 | 出网速率 | 折算 |
|---|---|---|
| 改前（空转轮询） | 1807 B/s | 149 MB/天 ≈ 0.11 元/天 ≈ 3.4 元/月 |
| 改后（空闲） | **369 B/s** | 30.5 MB/天 ≈ **0.024 元/天** ≈ 0.7 元/月 |

剩余 369 B/s 是 EasyTier 自身保活/控制流量，属 P2P 必要成本。当日累计出网（含此前下载客户端包的测试）223 MB ≈ 0.18 元。

## 3. 与任务书验收口径的偏差（需记录）

任务书 M3 验收原写「`easytier-cli peer` 可见移动端节点」——该口径只对**原生客户端**成立。走 **WireGuard 门户**的手机**不会出现在 peer 列表**，而是出现在 `vpn-portal` 的 `connected_clients`（已接进面板）。故 M3 验收口径改为：

- 原生客户端：`easytier-cli peer` 可见移动端节点（10.144.144.30+）
- WireGuard 门户客户端：面板「移动端接入」区块可见 + `easytier-cli vpn-portal` 的 connected_clients 非空

## 4. 待用户执行（M3 收尾，仅剩真机）

1. ~~阿里云安全组放行 `11013/UDP`~~ ✅ 已开通且已外部实证
2. 手机装 WireGuard App → 扫 `~/kelp-run/wg-phone-qr.png` → 启用
3. **关掉 Wi-Fi、用蜂窝数据**实测：打开 `https://192.168.1.99:5667`（飞牛 NAS 面板）与 `https://192.168.50.9`；SSH 侧可用 Termius 等连 `192.168.1.99:48032` 或 `192.168.50.9:22`
4. 把结果告诉助手 → 助手核对面板「移动端接入」与 `vpn-portal` 输出，记录速率（用 `scripts/net-throughput-*.py` 从手机侧不适用，改由面板/门户流量计数核对）

## 5. 遗留与风险

- ⚠️ **计费**：走 WG 门户时，手机访问 NAS 的流量 = 手机 → 公网节点 → NAS 节点，**公网节点出网全量计费（0.8 元/GB）**。看一部 2GB 电影 ≈ 1.6 元。大流量建议用原生客户端（Android 免费；iOS 需外区 Apple ID）。
  可选优化（未做，待用户评估）：把 WG 门户改开在 B 站点 NAS 上，用其**公网 IPv6（240e:…）**做 Endpoint，手机若有 IPv6 即可直连 NAS、完全绕开公网节点；代价是 IPv6 变动需更新配置。
- 门户只有一个客户端密钥（`client_config` 由 `easytier-cli vpn-portal` 生成）；多台手机需各自指定不同 `Address`（10.144.150.x），密钥相同是否可并存待真机验证。
- 公网节点重启后门户密钥是否变化待验证（若变化，手机需重新导入）。
