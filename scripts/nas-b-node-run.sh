#!/usr/bin/env bash
# B 站点（飞牛 NAS）节点容器：唯一权威的启动参数
# 说明：密钥等身份信息走 --env-file（600），但【env-file 变更必须重建容器】，docker restart 不生效
# 用法（在 NAS 上）: bash run-b-node.sh
set -euo pipefail

ENVF=${ENVF:-/vol1/kelp/b.env}
NAME=kelp-b-node
IMAGE=easytier/easytier:latest

echo "=== 前置检查 ==="
[[ -f $ENVF ]] || { echo "缺少 $ENVF"; exit 1; }
echo "  env-file: $ENVF（密钥前缀 $(grep -oE 'ET_NETWORK_SECRET=.{0,6}' "$ENVF" | cut -d= -f2)…）"
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "缺少镜像 $IMAGE（需先 docker.1ms.run 拉取并 tag）"; exit 1; }

echo "=== 备份现有容器配置 ==="
if docker inspect "$NAME" >/dev/null 2>&1; then
    docker inspect "$NAME" > "/vol1/kelp/$NAME.inspect.$(date +%Y%m%d%H%M%S).json"
    echo "  已存 /vol1/kelp/$NAME.inspect.*.json"
    docker rm -f "$NAME" >/dev/null
    echo "  旧容器已删"
fi

echo "=== 启动 ==="
docker run -d --name "$NAME" --restart unless-stopped \
  --network host --cap-add NET_ADMIN --device /dev/net/tun \
  --env-file "$ENVF" \
  --entrypoint easytier-core "$IMAGE" \
  --hostname kelp-nas --ipv4 10.144.144.20 \
  --proxy-networks 192.168.1.0/24 \
  --peers tcp://47.116.73.216:11010 \
  --private-mode true \
  --need-p2p true \
  --rpc-portal 0.0.0.0:15888 \
  --rpc-portal-whitelist 127.0.0.1,10.144.144.1 >/dev/null
echo "  已启动 $NAME"

echo "=== 20 秒后自检 ==="
sleep 20
docker ps --filter "name=$NAME" --format '  状态: {{.Status}}'
echo "  容器内密钥前缀: $(docker exec "$NAME" printenv ET_NETWORK_SECRET | cut -c1-6)"
docker exec "$NAME" easytier-cli -p 127.0.0.1:15888 peer 2>&1 | sed 's/^/    /'
