#!/usr/bin/env python3
"""根据各矩阵 job 输出的详情，生成格式化的 TEST-RESULT.md 并写回步骤输出。

环境变量:
  DETAILS        各矩阵 job 的 detail 输出（toJSON 聚合成的 JSON 字符串）
  GITHUB_ACTOR   触发者
  GITHUB_OUTPUT  步骤输出文件（写入 status/pass/fail/skip）
"""
import os
import sys
import json
import datetime


def load_details():
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
        lines = d.strip("\n").split("\n")
        parts = lines[0].split("|")
        if len(parts) < 3:
            continue
        img, variant, st = parts[:3]
        checks = []
        for ln in lines[1:]:
            ln = ln.strip()
            if not ln or "|" not in ln:
                continue
            name, res = ln.split("|", 1)
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

    with open("TEST-RESULT.md", "w", encoding="utf-8") as f:
        f.write("# 1Panel 镜像发布测试结果\n\n")
        f.write(f"> 更新时间: {now} · 触发者: {actor}\n\n")

        if not rows:
            skip_n = 1
            f.write("（无镜像测试）\n")
        else:
            f.write("## 汇总\n\n")
            f.write("| 镜像 | 变体 | 结果 |\n|---|---|---|\n")
            for img, variant, st, _ in rows:
                f.write(f"| `{img}` | {variant} | {st} |\n")
            f.write("\n## 详细检查\n\n")

            for img, variant, st, checks in rows:
                if st == "🔴":
                    fail_n += 1
                else:
                    pass_n += 1
                open_attr = " open" if st == "🔴" else ""
                f.write(f"<details{open_attr}>\n")
                f.write(f"<summary><b>{img}</b> · {variant} · {st}</summary>\n\n")
                f.write("| 检查项 | 结果 |\n|---|---|\n")
                for name, res in checks:
                    f.write(f"| {name} | {res} |\n")
                f.write("\n</details>\n\n")

        f.write("---\n")
        f.write(f"**通过: {pass_n} · 失败: {fail_n} · 跳过: {skip_n}**\n")

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