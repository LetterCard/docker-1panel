#!/usr/bin/env bash
# ==============================================================================
# 1Panel 已发布镜像全面冒烟测试
# 用法: published-test.sh <镜像tag> <variant>
#   <镜像tag>  例如 bugseeker/1panel:v2 或 bugseeker/1panel:global-v1
#   <variant>  v1 | v2   （决定数据库文件与进程名）
#
# 设计说明:
#   - 本脚本在"已有 docker CLI 的宿主机/GitHub Runner"运行，
#     通过 docker exec 进入被测 1Panel 容器内部执行断言。
#   - 容器内置 sqlite3/supervisorctl/curl（正式镜像自带），故不依赖宿主工具。
#   - 任一断言失败会记录 FAIL，全部执行完后以非零退出码报告，便于 CI 展示。
#   - 运行时只会新增容器 smoke-<随机>，结束后自动清理，不修改任何发布内容。
#   - 详情逐项写入 $DETAIL_FILE，供 CI 汇总回写 TEST-RESULT.md。
# ==============================================================================
set -uo pipefail

IMAGE="$1"
VARIANT="${2:-v2}"

# ---------- 结果汇总 ----------
PASS=0
FAIL=0
declare -a RESULTS=()

# 详情回写文件（供 CI 汇总；可用环境变量 PUBLISHED_DETAIL_FILE 覆盖路径）
DETAIL_FILE="${PUBLISHED_DETAIL_FILE:-/tmp/published-detail.txt}"
echo "# ${IMAGE} (variant: ${VARIANT})" > "$DETAIL_FILE"

record() {
    local name="$1" ok="$2" msg="${3:-}"
    if [ "$ok" -eq 1 ]; then
        PASS=$((PASS + 1))
        RESULTS+=("✅ ${name} 通过")
        echo "[PASS] ${name}"
        echo "${name}|🟢" >> "$DETAIL_FILE"
    else
        FAIL=$((FAIL + 1))
        RESULTS+=("❌ ${name} 失败: ${msg}")
        echo "[FAIL] ${name}: ${msg}"
        echo "${name}|🔴" >> "$DETAIL_FILE"
    fi
}

# ---------- 受测容器内部访问 ----------
CNAME="smoke-full-$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
CID=""

cleanup() {
    if [ -n "$CID" ]; then
        docker rm -f "$CID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

in_exe() {
    # in_exe <命令...>: 在受测容器内以 root 执行
    docker exec "$CID" "$@" 2>/tmp/full-test-in-err || {
        echo "  (容内命令失败: $* | $(cat /tmp/full-test-in-err 2>/dev/null))" >&2
        return 1
    }
}

# ============================ 阶段 A: 拉取与启动 ============================
echo "== [1] 拉取镜像 ${IMAGE} =="
if ! docker pull "$IMAGE" 2>/tmp/full-test-pull.log; then
    echo "[FAIL] 🚫 镜像拉取失败"
    RESULTS+=("❌ 拉取 ${IMAGE} 失败")
    echo "镜像拉取|🔴" >> "$DETAIL_FILE"
    FAIL=1
    echo "----- pull 日志 -----"
    cat /tmp/full-test-pull.log
    exit 1
fi
record "镜像可拉取" 1

echo "== [2] 启动容器 =="
# 与 smoke-test 对齐：按镜像默认方式启动，不依赖 host 网络/特权
CID=$(docker run -d \
    --name "$CNAME" \
    -e USERNAME=1panel \
    -e PASSWORD=1panel_test_pass \
    -e PORT=10086 \
    -e ENTRANCE=testentry \
    -e TZ=Asia/Shanghai \
    "$IMAGE")
if [ -z "$CID" ]; then
    echo "[FAIL] 🚫 容器启动失败"
    echo "容器启动|🔴" >> "$DETAIL_FILE"
    exit 1
fi
echo "  容器: $CID"

# ============================ 阶段 B: 服务与进程 ============================
echo "== [3] 服务健康检查 (容器内 curl http://127.0.0.1:10086) =="
OK=0
for i in $(seq 1 300); do
    if in_exe sh -c "curl -fsS -o /dev/null --max-time 2 http://127.0.0.1:10086" 2>/dev/null; then
        OK=1
        break
    fi
    sleep 1
done
record "服务健康检查(10086)" "$OK" "300 秒内未就绪"
if [ "$OK" -ne 1 ]; then
    docker logs "$CID" --tail 100 || true
fi

echo "== [4] Supervisor 进程状态 =="
if [ "$VARIANT" = "v1" ]; then
    PROGS=("1panel")
else
    PROGS=("1panel-core" "1panel-agent")
fi
# core 启动较慢（初始化数据库/迁移），等待其进入 RUNNING，消除启动竞态
PROGS_OK=1
for p in "${PROGS[@]}"; do
    ready=0
    for _ in $(seq 1 45); do
        if in_exe supervisorctl status "$p" 2>/dev/null | grep -q "RUNNING"; then
            ready=1
            break
        fi
        sleep 2
    done
    if [ "$ready" -eq 1 ]; then
        echo "  ✓ ${p} RUNNING"
    else
        PROGS_OK=0
        echo "  ✗ 进程 ${p} 未 RUNNING（等待 90 秒超时）"
    fi
done
record "Supervisor 进程 RUNNING" "$PROGS_OK" "预期进程: ${PROGS[*]}"

# ============================ 阶段 C: 功能与数据 ============================
echo "== [5] 数据目录初始化 =="
case "$VARIANT" in
    v1) DB_FILES=(/opt/1panel/db/1Panel.db) ;;
    *)  DB_FILES=(/opt/1panel/db/core.db /opt/1panel/db/agent.db) ;;
esac
DB_OK=1
for f in "${DB_FILES[@]}"; do
    if ! in_exe test -f "$f"; then
        DB_OK=0
        echo "  ✗ 缺数据文件 $f"
    else
        echo "  ✓ $f"
    fi
done
record "数据文件初始化" "$DB_OK" "期望: ${DB_FILES[*]}"

echo "== [6] 面板版本一致性 =="
ACTUAL=$(in_exe sh -c "grep '^ORIGINAL_VERSION=' /usr/local/bin/1pctl | cut -d= -f2" 2>/dev/null)
VER_OK=0
if [ -n "$ACTUAL" ]; then
    VER_OK=1
    echo "  镜像内 ORIGINAL_VERSION = ${ACTUAL}"
    # 尽量与 tag 版本段对齐（tag 形如 v2.2.5 / global-v2.2.5）
    TAG_VER=$(echo "$IMAGE" | sed -E 's/.*:(global-)?//')
    if [[ "$TAG_VER" == *"$ACTUAL"* || "$ACTUAL" == *"$TAG_VER"* ]]; then
        echo "  与 tag 版本 ${TAG_VER} 匹配"
    else
        echo "  ⚠ 与 tag 版本 ${TAG_VER} 不完全一致（浮动标签正常）"
    fi
fi
record "面板版本可读" "$VER_OK" "无法读取 ORIGINAL_VERSION"

echo "== [7] 1pctl 常用命令 =="
for cmd in version user-info status; do
    if in_exe sh -c "/usr/local/bin/1pctl $cmd" >/dev/null 2>&1; then
        echo "  ✓ 1pctl ${cmd}"
        record "1pctl ${cmd}" 1
    else
        record "1pctl ${cmd}" 0 "命令失败"
    fi
done

echo "== [8] Docker 生态命令可用 =="
DOCKER_OK=1
in_exe sh -c 'command -v docker >/dev/null' || DOCKER_OK=0
in_exe sh -c 'command -v docker-compose >/dev/null' || in_exe sh -c 'docker compose version >/dev/null 2>&1' || DOCKER_OK=0
record "docker Compose 可用" "$DOCKER_OK" "容器内缺少 docker/docker-compose"

echo "== [9] 环境变量生效 (端口/入口持久化) =="
# 验证 db 中 ServerPort 与 SecurityEntrance 已被初始化（V1/V2 关键键）
case "$VARIANT" in
    v1) DB=/opt/1panel/db/1Panel.db ;;
    *)  DB=/opt/1panel/db/core.db ;;
esac
CFG_OK=1
PORT_VAL=$(in_exe sh -c "sqlite3 ${DB} \"SELECT value FROM settings WHERE key='ServerPort';\"" 2>/dev/null)
ENT_VAL=$(in_exe sh -c "sqlite3 ${DB} \"SELECT value FROM settings WHERE key='SecurityEntrance';\"" 2>/dev/null)
if [ -z "$PORT_VAL" ]; then CFG_OK=0; echo "  ✗ ServerPort 未初始化"; else echo "  ✓ ServerPort=${PORT_VAL}"; fi
if [ -z "$ENT_VAL" ]; then CFG_OK=0; echo "  ✗ SecurityEntrance 未初始化"; else echo "  ✓ SecurityEntrance=${ENT_VAL}"; fi
record "环境变量持久化" "$CFG_OK" "ServerPort/SecurityEntrance 未写入"

echo "== [10] 容器内 1panel 主进程存活 =="
ALIVE_OK=1
if [ "$VARIANT" = "v1" ]; then
    in_exe sh -c 'pgrep -x 1panel >/dev/null' || ALIVE_OK=0
else
    in_exe sh -c 'pgrep -x 1panel-core >/dev/null' || ALIVE_OK=0
fi
record "主进程存活" "$ALIVE_OK" "未检测到存活的主进程"

# ============================ 汇总输出 ============================
echo
echo "======================================================"
echo "测试镜像: ${IMAGE}  (variant: ${VARIANT})"
echo "通过: ${PASS}   失败: ${FAIL}"
echo "------------------------------------------------------"
printf '%s\n' "${RESULTS[@]}"
echo "======================================================"

if [ "$FAIL" -gt 0 ]; then
    echo "::error::${IMAGE} 存在 ${FAIL} 项失败"
    exit 1
else
    echo "::notice::${IMAGE} 全部 ${PASS} 项通过"
    exit 0
fi
