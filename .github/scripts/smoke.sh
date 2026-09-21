#!/usr/bin/env bash
# 1Panel Docker 镜像冒烟测试脚本
# 用法: smoke.sh <NAME> <VERSION> <CONTEXT> <DOCKERFILE> <DB_FILE> <SUPERVISOR_PROG...>
# 无 VERSION 时跳过（该目标本轮未更新）；任一检查失败会记录明细并以非零退出码结束，
# 由调用方决定是否放行（CI 中通过 set -e 阻止后续构建推送）。
set -uo pipefail

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
REPORT_IMG="1Panel ${NAME} 冒烟镜像"

# 变体来源：Dockerfile-Global -> Global，其余视为 CN
if [[ "$DOCKERFILE" == *"Global"* ]]; then
  VARIANT="Global"
else
  VARIANT="CN"
fi

# ---------- 结果明细（供 report.py 汇总） ----------
# 单行格式: IMAGE|VARIANT|STATUS;检查项|emoji;检查项|emoji;...
DETAIL_DIR="${SMOKE_DETAIL_DIR:-results}"
DETAIL_FILE="${DETAIL_DIR}/detail-${NAME}.txt"
mkdir -p "$DETAIL_DIR"

CHECK_NAMES=("镜像构建" "容器启动" "服务健康检查(10086)" "Supervisor 进程 RUNNING" "面板版本一致" "1pctl version 可执行" "数据目录初始化")
CHECK_RES=("⏭️" "⏭️" "⏭️" "⏭️" "⏭️" "⏭️" "⏭️")
FAILED=0

record() {  # record <检查项下标> <0|1> [失败说明]
  local idx=$1 ok=$2 msg=${3:-}
  if [ "$ok" -eq 1 ]; then
    CHECK_RES[$idx]="🟢"
  else
    CHECK_RES[$idx]="🔴"
    FAILED=1
    echo "::error::${NAME} ${CHECK_NAMES[$idx]}${msg:+ (${msg})}"
  fi
}

write_detail() {
  local status="🟢" i
  [ "$FAILED" -ne 0 ] && status="🔴"
  local line="${REPORT_IMG}|${VARIANT}|${status}"
  for i in "${!CHECK_NAMES[@]}"; do
    line="${line};${CHECK_NAMES[$i]}|${CHECK_RES[$i]}"
  done
  printf '%s\n' "$line" > "$DETAIL_FILE"
  echo "📄 明细已写入 ${DETAIL_FILE}: ${line}"
}

CID=""
cleanup() {
  if [ -n "$CID" ]; then
    docker rm -f "$CID" >/dev/null 2>&1 || true
  fi
}
trap 'write_detail; cleanup' EXIT

echo "== 构建冒烟镜像 (amd64, 不推送) =="
if docker buildx build --load \
  --platform linux/amd64 \
  --file "$DOCKERFILE" \
  --build-arg "PANELVER=${VERSION}" \
  --tag "$IMG" \
  "$CONTEXT"; then
  record 0 1
else
  record 0 0 "docker buildx build 失败"
  exit 1
fi

echo "== 启动容器 =="
CID=$(docker run -d --name "smoke-${NAME}" \
  -e USERNAME=1panel \
  -e PASSWORD=1panel_smoke_test \
  -e PORT=10086 \
  "${IMG}") || CID=""
if [ -z "$CID" ]; then
  record 1 0 "docker run 失败"
  exit 1
fi
record 1 1

echo "== 1) 等待服务健康 (http://127.0.0.1:10086) =="
OK=0
for i in $(seq 1 300); do
  if docker exec "$CID" sh -c "curl -fsS -o /dev/null --max-time 2 http://127.0.0.1:10086" 2>/dev/null; then
    OK=1
    break
  fi
  sleep 1
done
if [ "$OK" -ne 1 ]; then
  docker logs "$CID" --tail 200 || true
fi
record 2 "$OK" "300 秒内未就绪"
[ "$OK" -eq 1 ] && echo "✅ 服务已在端口 10086 响应"

echo "== 2) 检查 supervisor 进程状态 =="
docker exec "$CID" supervisorctl status || true
# 入口脚本在首次初始化时会执行 1pctl update/restart，期间受管进程会经历
# STOPPING/STARTING 短暂窗口，故采用轮询而非单次快照，避免误判为未 RUNNING。
PROG_TIMEOUT=${SMOKE_PROG_TIMEOUT:-180}
PROGS_OK=1
for p in "${PROGS[@]}"; do
  OKP=0
  for i in $(seq 1 "$PROG_TIMEOUT"); do
    if docker exec "$CID" supervisorctl status "$p" 2>/dev/null | grep -q "RUNNING"; then
      OKP=1
      echo "  ✓ ${p} RUNNING (第 ${i}s)"
      break
    fi
    sleep 1
  done
  if [ "$OKP" -ne 1 ]; then
    PROGS_OK=0
    echo "  ✗ ${p} 在 ${PROG_TIMEOUT}s 内未处于 RUNNING"
    docker exec "$CID" supervisorctl status "$p" 2>/dev/null || true
  fi
done
if [ "$PROGS_OK" -ne 1 ]; then
  docker logs "$CID" --tail 200 || true
fi
record 3 "$PROGS_OK" "存在未 RUNNING 的进程: ${PROGS[*]}"
[ "$PROGS_OK" -eq 1 ] && echo "✅ 全部受管进程 RUNNING"

echo "== 3) 校验面板版本 =="
ACTUAL=$(docker exec "$CID" sh -c "grep '^ORIGINAL_VERSION=' /usr/local/bin/1pctl | cut -d= -f2" 2>/dev/null || true)
echo "实际: ${ACTUAL}  期望: ${VERSION}"
VER_OK=1
[ "$ACTUAL" = "$VERSION" ] || VER_OK=0
record 4 "$VER_OK" "版本不匹配 (实际 ${ACTUAL:-空})"
[ "$VER_OK" -eq 1 ] && echo "✅ 版本一致"

echo "== 4) 验证 1pctl version 可执行 =="
CLI_OK=1
docker exec "$CID" sh -c "/usr/local/bin/1pctl version" >/dev/null 2>&1 || CLI_OK=0
record 5 "$CLI_OK" "1pctl version 执行失败"
[ "$CLI_OK" -eq 1 ] && echo "✅ 1pctl version 正常"

echo "== 5) 校验数据目录已初始化 =="
DB_OK=1
if ! docker exec "$CID" sh -c "[ -f /opt/1panel/db/${DBFILE} ]"; then
  DB_OK=0
  docker logs "$CID" --tail 200 || true
fi
record 6 "$DB_OK" "数据目录未初始化 (/opt/1panel/db/${DBFILE})"
[ "$DB_OK" -eq 1 ] && echo "✅ 数据目录已初始化"

if [ "$FAILED" -ne 0 ]; then
  echo "❌ ${NAME} 冒烟测试存在失败项"
  exit 1
fi
echo "🎉 ${NAME} 冒烟测试全部通过"
