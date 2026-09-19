# 海带 (Kelp) 回滚手册

用途：把本项目**全部或局部**从各机器上干净移除，恢复到部署前状态。
每一次回滚演练的原始输出见 `docs/M4-acceptance.md`。

## 0. 组件清单与影响面

| # | 组件 | 位置 | 回滚影响 |
|---|---|---|---|
| 1 | `easytier.service`（公网节点/hub） | 47.116.73.216 | 停掉 → **组网立即中断**（实测 3 秒内 A↔B 全断），面板同时不可用 |
| 2 | `kelp-panel.service`（只读面板） | 47.116.73.216 | 停掉 → 只影响面板，组网不受影响（已演练） |
| 3 | `easytier-node.service`（A 站点节点） | 192.168.50.9 | 停掉 → 家里侧退出组网，VPS/NAS 侧不受影响 |
| 4 | `kelp-b-node` 容器（B 站点节点） | 飞牛 NAS | 停掉 → NAS 侧退出组网，其余不受影响（已演练：65 秒内面板判离线并记录最后在线时间） |
| 5 | 网关模式（`ip_forward` + FORWARD 规则 + 单元） | 192.168.50.9 | `bash kelp-gateway.sh rollback` 精确还原 |
| 6 | 客户端静态路由 / 网关指向 | 各客户端设备 | 删除路由或改回原网关 |
| 7 | 阿里云安全组放行（11010 TCP+UDP、18080 TCP） | 阿里云控制台 | 删除规则即封闭入口 |
| 8 | 本机临时工作区 `~/kelp-run/` | Mac | 直接删除，无服务、无自启 |

## 1. 局部回滚

### 1.1 B 站点节点（飞牛 NAS，Docker）
```bash
ssh -p 48032 admin@<NAS>
docker stop kelp-b-node          # 停（可随时 start 恢复）
docker rm -f kelp-b-node         # 彻底删除容器
docker rmi easytier/easytier:latest   # 删除镜像（可选）
rm -rf /vol1/kelp                # 删除网络身份文件（600）
```
验证：面板中该设备在约 65 秒内变“离线”并记录最后在线时间；其余节点保持 P2P。

### 1.2 A 站点节点（192.168.50.9）
```bash
sudo systemctl disable --now easytier-node
sudo rm -f /etc/systemd/system/easytier-node.service
sudo rm -rf /etc/easytier                  # 含 kelp.env（600）网络身份
sudo rm -f /usr/local/bin/easytier-core /usr/local/bin/easytier-cli
sudo systemctl daemon-reload
```

### 1.3 网关模式（FR3）
```bash
sudo bash /usr/local/sbin/kelp-gateway.sh rollback
# 幂等；会把 ip_forward 恢复为首次 apply 时记录的原值（/etc/kelp/gateway-originals.json）
```

### 1.4 只读面板
```bash
sudo systemctl disable --now kelp-panel
sudo rm -f /etc/systemd/system/kelp-panel.service
sudo rm -rf /opt/kelp /etc/kelp /var/lib/kelp
sudo systemctl daemon-reload
```

### 1.5 公网节点（最后一环）
```bash
sudo systemctl disable --now easytier
sudo rm -f /etc/systemd/system/easytier.service
sudo rm -f /usr/local/bin/easytier-core /usr/local/bin/easytier-cli
sudo rm -rf /etc/kelp
sudo systemctl daemon-reload
```
最后到阿里云控制台删除安全组中的 `11010/TCP`、`11010/UDP`、`18080/TCP` 三条放行规则。

## 2. 客户端还原

| 端 | 加过什么 | 怎么还原 |
|---|---|---|
| macOS / Windows / Linux | 静态路由（如 `192.168.1.0/24 via 192.168.50.9`） | `sudo route delete -net 192.168.1.0/24` / `route delete` / `ip route del` |
| 电视 / AppleTV（如确实改过默认网关） | 默认网关指向 50.9 | 改回原网关（一般为 `192.168.50.1`） |
| iOS（如按 FR3 第 3 条改过 DNS） | DNS 改为 `223.5.5.5` | 改回“自动” |
| Android / iOS | 安装的 EasyTier / WireGuard 客户端与配置 | 卸载 App 或删除对应网络配置 |

## 3. 全量回滚顺序（推荐）

1. 客户端还原（§2）——先断客户端，避免半通状态
2. 网关模式回滚（§1.3）
3. 两站点节点回滚（§1.1、§1.2）
4. 面板回滚（§1.4）
5. 公网节点回滚（§1.5）+ 安全组收回
6. 本机工作区清理：`rm -rf ~/kelp-run ~/.config/kelp`

回滚后自检：`ip_forward` 恢复原值、`iptables -S FORWARD | grep KELP` 无输出、
`ss -lntup | grep -E '11010|15888|18080'` 无监听、原网段互访恢复为“不通”（本就无路由）。

## 4. 已演练记录（2026-09-19）

| 演练项 | 结果 |
|---|---|
| 停 B 站点容器 | 65 秒内面板判“离线”并记录最后在线时间；其余 2 节点 P2P 不受影响 ✅ |
| 重启 B 站点容器 | 35 秒内恢复在线，P2P 15.11ms ✅ |
| 停只读面板 | 组网不受影响（B→A `https://192.168.50.9/` 仍 401）；重启后恢复 ✅ |
| 停公网节点 | **组网立即中断**（3 秒内 A↔B 不通），重启后 15 秒内自动恢复 2 条 P2P ⚠️ 见任务书风险表 |
