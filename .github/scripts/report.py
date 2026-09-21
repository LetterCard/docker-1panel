#!/usr/bin/env python3
"""根据各矩阵 job 上传的详情文件，生成格式化的测试结果并输出到 stdout
（由调用方重定向到 $GITHUB_STEP_SUMMARY 显示在运行摘要，不再写回仓库文件）。

输入来源（优先级从高到低）:
  results-dir/  目录（download-artifact 下载的 detail-*.txt，每个文件一行详情）
  DETAILS       环境变量（各矩阵 job 输出的 JSON 字符串数组，本地测试用）
  GITHUB_ACTOR  触发者
  GITHUB_OUTPUT 步骤输出文件（写入 status/pass/fail/skip）
"""
import os
import sys
import json
import glob
import datetime


def load_details():
    # 1) 优先读取 results-dir 目录下的 detail 文件
    files = sorted(glob.glob("results-dir/**/detail-*.txt", recursive=True))
    if files:
        details = []
        for fp in files:
            with open(fp, "r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if line:
                        details.append(line)
        return details
    # 2) 兼容本地测试：读取 DETAILS 环境变量（JSON 字符串数组）
    raw = os.environ.get("DETAILS", "[]")
    try:
        details = json.loads(raw)
        if not isinstance(details, list):
            details = [details]
    except Exception:
        details = []
    return details


def parse_rows(details):
    rows = []
    for d in details:
        if not d:
            continue
        # 单行格式: IMAGE|VARIANT|STATUS;检查项|emoji;检查项|emoji;...
        segment = d.strip().split(";", 1)
        header = segment[0].split("|")
        if len(header) < 3:
            continue
        img, variant, st = header[:3]
        checks = []
        if len(segment) > 1 and segment[1]:
            for part in segment[1].split(";"):
                part = part.strip()
                if not part or "|" not in part:
                    continue
                name, res = part.split("|", 1)
                checks.append((name.strip(), res.strip()))
        rows.append((img, variant, st, checks))
    return rows


def order_rows(rows):
    ordered = [r for r in rows if r[0].endswith("latest")]
    for r in rows:
        if r not in ordered:
            ordered.append(r)
    return ordered


def main():
    now = datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%d %H:%M:%S UTC"
    )
    actor = os.environ.get("GITHUB_ACTOR", "github-actions")
    rows = order_rows(parse_rows(load_details()))

    pass_n = 0
    fail_n = 0
    skip_n = 0

    out = []
    out.append("# 1Panel 镜像发布测试结果")
    out.append("")
    out.append(f"> 更新时间: {now} · 触发者: {actor}")
    out.append("")

    if not rows:
        skip_n = 1
        out.append("（无镜像测试）")
    else:
        out.append("## 汇总")
        out.append("")
        out.append("| 镜像 | 变体 | 结果 |")
        out.append("|---|---|---|")
        for img, variant, st, _ in rows:
            out.append(f"| `{img}` | {variant} | {st} |")
        out.append("")
        out.append("## 详细检查")
        out.append("")

        for img, variant, st, checks in rows:
            if st == "🔴":
                fail_n += 1
            else:
                pass_n += 1
            open_attr = " open" if st == "🔴" else ""
            out.append(f"<details{open_attr}>")
            out.append(f"<summary><b>{img}</b> · {variant} · {st}</summary>")
            out.append("")
            out.append("| 检查项 | 结果 |")
            out.append("|---|---|")
            for name, res in checks:
                out.append(f"| {name} | {res} |")
            out.append("")
            out.append("</details>")
            out.append("")

    out.append("---")
    out.append(f"**通过: {pass_n} · 失败: {fail_n} · 跳过: {skip_n}**")
    sys.stdout.write("\n".join(out) + "\n")

    if fail_n > 0:
        status = "🔴"
    elif skip_n > 0:
        status = "🟡"
    else:
        status = "🟢"

    gh = os.environ.get("GITHUB_OUTPUT", "")
    if gh:
        with open(gh, "a", encoding="utf-8") as o:
            o.write(f"status={status}\n")
            o.write(f"pass={pass_n}\n")
            o.write(f"fail={fail_n}\n")
            o.write(f"skip={skip_n}\n")

    print(f"整体状态: {status}  通过 {pass_n} / 失败 {fail_n} / 跳过 {skip_n}")


if __name__ == "__main__":
    main()
