---
name: "docker-maintenance"
description: "维护 1Panel Docker 镜像构建项目（CI 流水线、版本升级、冒烟测试、构建脚本）。当用户需要升级 1Panel 版本、修改 GitHub Actions 构建流程、排查构建/测试问题、对比上游 okxlin/docker-1panel 时触发。"
---

# 1Panel Docker 镜像维护

## 项目定位

本项目是 [okxlin/docker-1panel](https://github.com/okxlin/docker-1panel) 的 fork 定制版。通过 GitHub Actions 将 1Panel（V1/V2 × CN/Global 共 4 种镜像）构建并推送到 Docker Hub（发布账号 `bugseeker`）。核心差异化能力：

- **版本追踪**：用 `VERSION` / `VERSION-GLOBAL` 文件记录已发布版本，仅在远端有新版时才构建
- **冒烟测试**：发布前对镜像做 5 项自动化检查，失败则阻断推送
- **版本回写**：构建成功后自动提交新的 VERSION 文件

## 目录结构

```
.github/
  workflows/
    build-1panel-cn-docker-image.yml      # CN 版流水线
    build-1panel-global-docker-image.yml  # Global 版流水线
    published-images.yml                  # 已发布镜像全面测试（独立触发）
  dependabot.yml                          # 自动维护 Actions 版本
scripts/
  smoke-test.sh                           # 构建前冒烟测试（两个流水线共用）
  published-test.sh                       # 已发布镜像全面测试
  resolve-tags.py                         # 动态解析 Docker Hub tags（published-test 使用）
V1/
  Dockerfile           # CN 构建（ubuntu:26.04）
  Dockerfile-Global    # Global 构建
  entrypoint.sh        # 容器启动入口（初始化账号/端口/入口）
  install-v1.override.sh  # 构建期安装脚本（仅拷贝文件，不注册服务）
  supervisord.conf     # supervisor 管理 1panel 进程
  1pctl                # 控制脚本模板（构建时被 sed 注入版本/端口等）
  VERSION              # 已发布的 CN 版本号
  VERSION-GLOBAL       # 已发布的 Global 版本号
V2/
  ... # 与 V1 结构相同，进程为 1panel-core + 1panel-agent，数据库 core.db/agent.db
```

## CI 流水线（4 阶段）

两个 workflow（CN / Global）结构一致，各自独立运行：

```
阶段1 check_remote   V1/V2 并行：拉远端最新版，与本地 VERSION 比对
     │                输出 version（要构建的版本，无更新则为空）、bump（新版本号）
     ▼
阶段2 check_images   V1/V2 并行：buildx 构建 amd64 镜像并跑冒烟测试
     │                仅当 check_remote 有版本时执行
     ▼
阶段3 build_images   V1/V2 并行：多架构 buildx 构建并 push 到 Docker Hub
     │                依赖阶段1有版本 && 阶段2通过
     ▼
阶段4 bump_version   回写 VERSION 文件并提交 "chore: 1Panel升级到 x"
```

### 各阶段要点

- **check_remote**：`curl` 远端 latest URL（CN: `resource.fit2cloud.com`，Global: `resource.1panel.pro`），用正则 `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` 校验。支持 3 种手动输入：`version`（指定版本）、`force`（忽略比对强制重建）、`target`（只构建 V1 或 V2）。
- **check_images**：调用 `scripts/smoke-test.sh <NAME> <VERSION> <CONTEXT> <DOCKERFILE> <DB_FILE> <PROG...>`，任一检查失败以非零退出，由 `needs`/`if` 条件阻断构建。
- **build_images**：原生 `docker buildx build --push`，平台 `linux/amd64,linux/arm64,linux/arm/v7,linux/ppc64le,linux/s390x`。V2 用 `--cache-from/--cache-to type=gha` 加速。
- **bump_version**：仅在 `built=true && bump 非空` 时写 VERSION 文件；无变化则跳过提交。提交身份为 `github-actions[bot]`。

### 标签规则

| 目标 | 版本标签 | 浮动标签 |
|---|---|---|
| V1 CN | `1panel:v<版本>` | `1panel:v1` |
| V1 Global | `1panel:global-v<版本>` | `1panel:global-v1` |
| V2 CN | `1panel:v<版本>` | `1panel:v2`、`1panel:latest`（V2 专属） |
| V2 Global | `1panel:global-v<版本>` | `1panel:global-v2` |

`latest` 只在 `schedule` 触发或手动勾选 `push_latest` 时附加（编译旧版本必须取消勾选）。

## 冒烟测试 5 项检查（smoke-test.sh）

1. **服务健康**：容器内 `curl http://127.0.0.1:10086`，300 秒内就绪
2. **进程状态**：`supervisorctl status <PROG>` 全部 `RUNNING`
3. **版本一致**：`/usr/local/bin/1pctl` 中 `ORIGINAL_VERSION=` 与期望版本相同
4. **命令可用**：`1pctl version` 能执行
5. **数据初始化**：`/opt/1panel/db/<DB_FILE>` 存在（V1=`1Panel.db`，V2=`core.db` + `agent.db`）

## 已发布镜像全面测试（published-test.sh）

独立 workflow `published-images.yml`（手动触发），验证**已推送到 Docker Hub 的镜像**功能正常：

- **拉取方式**：`docker pull bugseeker/1panel:<tag>`，从 Docker Hub 拉取已发布镜像（不在本地构建）
- **动态 tag 解析**：`resolve-tags.py` 调 Docker Hub API 拉取全部 tags，取 5 个固定浮动标签（`latest`/`v1`/`v2`/`global-v1`/`global-v2`）+ 各系列最新版本号（如 `v2.2.5`、`global-v2.2.5`），版本升级后无需改配置
- **覆盖**：V1/V2 × CN/Global 共 9 个 tag，matrix 逐镜像执行
- **检查项**：镜像可拉取、容器可启动、服务健康（10086）、supervisor 进程 RUNNING、数据文件初始化、版本一致、1pctl 命令可用、docker/compose 可用、环境变量持久化、主进程存活
- **结果回写**：
  - `TEST-RESULT.md` 生成完整详情，每个镜像一段 `<details>/<summary>` 可折叠表格
  - commit message `chore: 测试结果-><emoji> (通过 N / 失败 M / 跳过 K)`，状态展示在 GitHub 仓库首页的 Commit 列表中
- **结果仅打印到 Actions 日志并回写 `TEST-RESULT.md`**，不推送镜像、不改 VERSION 版本文件

## 版本号位置（改版本时必须同步）

| 含义 | 文件 |
|---|---|
| CN 已发布版本 | `V1/VERSION`、`V2/VERSION` |
| Global 已发布版本 | `V1/VERSION-GLOBAL`、`V2/VERSION-GLOBAL` |
| 1pctl 模板默认版本（构建时被覆盖） | `V1/1pctl` 的 `ORIGINAL_VERSION`、`V2/1pctl` 的 `ORIGINAL_VERSION` |

版本号一律以 `v` 开头（如 `v2.2.5`），不带前后空格。

## 常见维护任务

### 1. 手动升级到指定版本
在 GitHub 仓库 Actions 页选择 workflow → `Run workflow`，填 `target`、`version`，务必取消勾选 `push_latest`（除非是要推 latest）。

### 2. 强制重建当前版本
勾选 `force=true`，跳过远端比对直接按 VERSION 文件构建。

### 3. 升级基础镜像
`V1/Dockerfile`、`V1/Dockerfile-Global`、`V2/Dockerfile`、`V2/Dockerfile-Global` 的 `FROM ubuntu:<tag>` 需要 4 处同步修改。改前先用 CI 冒烟测试验证。

### 4. 变更上游发布的 Docker Hub 账号
改两个 workflow 中 `Docker Hub` 登录所用 secrets（`DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`），并同步 Dockerfile 中 `LABEL org.opencontainers.image.vendor/source`。

### 5. 对比上游（okxlin/docker-1panel）
上游用单 job + matrix + `docker/build-push-action@v6`，无冒烟测试/版本回写。本项目是 4 阶段流水线。**不要把上游的简化结构直接套用**，本项目流水线的冒烟测试与版本回写是核心价值；如需参考，只参考上游的"安全加固"类改动（如构建输入校验、runtime hardening）。

### 6. 测试已发布镜像
Actions 页运行 `Test Published 1Panel Images`，默认测试全部 9 个 tag（动态解析最新版本）。传 `tag` 可只测单个，传 `username` 可覆盖默认命名空间 `bugseeker`。

## 约定与注意事项

- Secrets 仅 `DOCKERHUB_USERNAME`、`DOCKERHUB_TOKEN` 两个
- 提交信息固定格式：`chore: 1Panel升级到 <版本>`
- Actions 版本由 `.github/dependabot.yml` 每周自动维护（github-actions ecosystem，合并为一个 PR，前缀 `ci:`）
- 修改 CI 后必须本地校验 YAML 缩进（job 名、`needs`、`if` 引用要一致）
- 两个 workflow 中 check_remote 的 URL、VERSION 文件路径、smoke-test 参数是 CN/Global 的**主要差异点**，修改时注意不要改错文件

## 验证

- workflow YAML 语法校验：`python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" .github/workflows/build-1panel-cn-docker-image.yml`（`on:` 会被解析为布尔值是正常现象，重点看是否报缩进/语法错误）
- shell 脚本语法校验：`bash -n scripts/smoke-test.sh V1 v1.0 ./V1 ./V1/Dockerfile 1Panel.db 1panel`（`bash -n` 不执行，参数仅占位）
