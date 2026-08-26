#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p data/generated data/runtime
if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "[OK] 已生成 .env。测试阶段可保持 GITHUB_PUBLISH_ENABLED=false。"
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] 未找到 Docker。请先安装 Docker Engine + Compose plugin。" >&2
  exit 1
fi

echo "[INFO] 请确认 ranges/NRT/ipv4.txt 与 ranges/NRT/ipv6.txt 已填入有效 CIDR。"
docker compose -f compose.yaml build --pull
echo "[OK] 镜像已构建。启动：docker compose -f compose.yaml up -d"
