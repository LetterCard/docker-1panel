#!/usr/bin/env bash
# 1Panel Docker 镜像冒烟测试脚本
# 用法: smoke-test.sh <NAME> <VERSION> <CONTEXT> <DOCKERFILE> <DB_FILE> <SUPERVISOR_PROG...>
# 无 VERSION 时跳过（该目标本轮未更新）；任一检查失败则以非零退出，由调用方决定是否放行
set -euo pipefail

NAME=$1
VERSION=$2
CONTEXT=$3
DOCKERFILE=$4
DBFILE=$5
shift 5
PROGS=("$@")

if [ -z "$VERSION" ]; then
  echo "⏭️ ${NAME} 此轮未构建版本，跳过冒烟测试"
  exit 0
fi

IMG="1panel-smoke:${NAME}"

echo "== 构建冒烟镜像 (amd64, 不推送) =="
docker buildx build --load \
  --platform linux/amd64 \
  --file "$DOCKERFILE" \
  --build-arg "PANELVER=${VERSION}" \
  --tag "$IMG" \
  "$CONTEXT"

CID=""
cleanup() {
  if [ -n "$CID" ]; then
    docker rm -f "$CID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "== 启动容器 =="
CID=$(docker run -d --name "smoke-${NAME}" \
  -e USERNAME=1panel \
  -e PASSWORD=1panel_smoke_test \
  -e PORT=10086 \
  "${IMG}")

echo "== 1) 等待服务健康 (http://127.0.0.1:10086) =="
OK=0
for i in $(seq 1 300); do
  if docker exec "$CID" sh -c "curl -fsS -o /dev/null --max-time 2 http://127.0.0.1:10086" 2>/dev/null; then
    OK=1
    break
  fi
  sleep 1
done
if [ "$OK" != "1" ]; then
  echo "::error::${NAME} 服务健康检查超时 (端口 10086)"
  docker logs "$CID" --tail 200 || true
  exit 1
fi
echo "✅ 服务已在端口 10086 响应"

echo "== 2) 检查 supervisor 进程状态 =="
docker exec "$CID" supervisorctl status || true
for p in "${PROGS[@]}"; do
  if ! docker exec "$CID" supervisorctl status "$p" | grep -q "RUNNING"; then
    echo "::error::${NAME} 进程 $p 未处于 RUNNING"
    docker logs "$CID" --tail 200 || true
    exit 1
  fi
done
echo "✅ 全部受管进程 RUNNING"

echo "== 3) 校验面板版本 =="
ACTUAL=$(docker exec "$CID" sh -c "grep '^ORIGINAL_VERSION=' /usr/local/bin/1pctl | cut -d= -f2")
echo "实际: ${ACTUAL}  期望: ${VERSION}"
if [ "$ACTUAL" != "$VERSION" ]; then
  echo "::error::${NAME} 版本不匹配"
  exit 1
fi
echo "✅ 版本一致"

echo "== 4) 验证 1pctl version 可执行 =="
if ! docker exec "$CID" sh -c "/usr/local/bin/1pctl version" >/dev/null 2>&1; then
  echo "::error::${NAME} 1pctl version 执行失败"
  exit 1
fi
echo "✅ 1pctl version 正常"

echo "== 5) 校验数据目录已初始化 =="
if ! docker exec "$CID" sh -c "[ -f /opt/1panel/db/${DBFILE} ]"; then
  echo "::error::${NAME} 数据目录未初始化 (/opt/1panel/db/${DBFILE})"
  docker logs "$CID" --tail 200 || true
  exit 1
fi
echo "✅ 数据目录已初始化"

echo "🎉 ${NAME} 冒烟测试全部通过"
