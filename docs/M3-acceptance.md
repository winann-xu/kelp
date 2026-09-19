# M3 验收记录：手机接入（进行中 —— 待"安全组放行 + 真机蜂窝测试"）

执行时间：2026-09-19 23:4x–23:5x　|　证据均为实测原始输出

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

## 3. 与任务书验收口径的偏差（需记录）

任务书 M3 验收原写「`easytier-cli peer` 可见移动端节点」——该口径只对**原生客户端**成立。走 **WireGuard 门户**的手机**不会出现在 peer 列表**，而是出现在 `vpn-portal` 的 `connected_clients`（已接进面板）。故 M3 验收口径改为：

- 原生客户端：`easytier-cli peer` 可见移动端节点（10.144.144.30+）
- WireGuard 门户客户端：面板「移动端接入」区块可见 + `easytier-cli vpn-portal` 的 connected_clients 非空

## 4. 待用户执行（M3 收尾）

1. **阿里云安全组放行 `11013/UDP`**（TCP 不用开）——否则手机在蜂窝网络下连不上门户
2. 手机装 WireGuard App → 扫 `~/kelp-run/wg-phone-qr.png` → 启用
3. **关掉 Wi-Fi、用蜂窝数据**实测：打开 `https://192.168.1.99:5667`（飞牛 NAS 面板）与 `https://192.168.50.9`；SSH 侧可用 Termius 等连 `192.168.1.99:48032` 或 `192.168.50.9:22`
4. 把结果告诉助手 → 助手核对面板「移动端接入」与 `vpn-portal` 输出，记录速率（用 `scripts/net-throughput-*.py` 从手机侧不适用，改由面板/门户流量计数核对）

## 5. 遗留与风险

- ⚠️ **计费**：走 WG 门户时，手机访问 NAS 的流量 = 手机 → 公网节点 → NAS 节点，**公网节点出网全量计费（0.8 元/GB）**。看一部 2GB 电影 ≈ 1.6 元。大流量建议用原生客户端（Android 免费；iOS 需外区 Apple ID）。
  可选优化（未做，待用户评估）：把 WG 门户改开在 B 站点 NAS 上，用其**公网 IPv6（240e:…）**做 Endpoint，手机若有 IPv6 即可直连 NAS、完全绕开公网节点；代价是 IPv6 变动需更新配置。
- 门户只有一个客户端密钥（`client_config` 由 `easytier-cli vpn-portal` 生成）；多台手机需各自指定不同 `Address`（10.144.150.x），密钥相同是否可并存待真机验证。
- 公网节点重启后门户密钥是否变化待验证（若变化，手机需重新导入）。
