#!/bin/bash

# ==============================================================================
# 1Panel V1 Docker 构建专用安装脚本
# 作用: 仅负责文件拷贝和基础目录结构创建，不进行任何系统服务注册
# ==============================================================================

# 硬编码默认配置 (构建时临时使用，启动时会被 entrypoint.sh 覆盖)
PANEL_BASE_DIR="/opt"
PANEL_PORT="10086"
PANEL_USERNAME="1panel"
PANEL_PASSWORD="1panel_password"
PANEL_ENTRANCE="entrance"

# 日志函数
log() {
    echo "[Build-Installer] $1"
}

init_configure() {
    log "开始部署 1Panel V1 二进制文件..."
    
    # 1. 准备目录
    mkdir -p /usr/local/bin
    mkdir -p /usr/bin

    # 2. 复制并授权主程序
    if [ -f "./1panel" ]; then
        cp ./1panel /usr/local/bin/1panel
        chmod +x /usr/local/bin/1panel
        ln -sf /usr/local/bin/1panel /usr/bin/1panel
        log "主程序 1panel 部署完成"
    else
        log "错误: 未找到 1panel 二进制文件"
        exit 1
    fi

    # 3. 复制并授权控制脚本
    if [ -f "./1pctl" ]; then
        cp ./1pctl /usr/local/bin/1pctl
        chmod +x /usr/local/bin/1pctl
        ln -sf /usr/local/bin/1pctl /usr/bin/1pctl
        log "控制脚本 1pctl 部署完成"
    else
        log "错误: 未找到 1pctl 脚本"
        exit 1
    fi

    # 4. 修改 1pctl 中的占位符变量
    # 这些变量在构建时先写死，容器启动时 entrypoint.sh 会再次根据环境变量修改它们
    log "初始化 1pctl 配置参数..."
    sed -i -e "s#BASE_DIR=.*#BASE_DIR=${PANEL_BASE_DIR}#g" /usr/local/bin/1pctl
    sed -i -e "s#ORIGINAL_PORT=.*#ORIGINAL_PORT=${PANEL_PORT}#g" /usr/local/bin/1pctl
    sed -i -e "s#ORIGINAL_USERNAME=.*#ORIGINAL_USERNAME=${PANEL_USERNAME}#g" /usr/local/bin/1pctl
    sed -i -e "s#ORIGINAL_PASSWORD=.*#ORIGINAL_PASSWORD=${PANEL_PASSWORD}#g" /usr/local/bin/1pctl
    sed -i -e "s#ORIGINAL_ENTRANCE=.*#ORIGINAL_ENTRANCE=${PANEL_ENTRANCE}#g" /usr/local/bin/1pctl
    # 默认语言设为英文，避免编码问题，用户可在面板修改
    sed -i -e "s#LANGUAGE=.*#LANGUAGE=en#g" /usr/local/bin/1pctl

    # 5. 部署资源文件
    # V1 的运行目录通常是 /opt/1panel
    RUN_BASE_DIR="${PANEL_BASE_DIR}/1panel"
    mkdir -p "$RUN_BASE_DIR/geo"
    mkdir -p "$RUN_BASE_DIR/resource"
    mkdir -p "$RUN_BASE_DIR/db"
    
    # 复制 GeoIP 数据库
    if [ -f "./GeoIP.mmdb" ]; then
        log "复制 GeoIP 数据库..."
        cp ./GeoIP.mmdb "$RUN_BASE_DIR/geo/"
    fi
    
    # 复制语言包 (1pctl 需要用到)
    if [ -d "./lang" ]; then
        log "复制语言包..."
        cp -r ./lang /usr/local/bin/
    fi

    log "1Panel V1 安装文件部署完成。"
}

main() {
    init_configure
}

main