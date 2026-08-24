#!/usr/bin/env python3
"""动态解析 bugseeker/1panel 在 Docker Hub 上的待测 tag 列表。

输出一组 {image, variant} JSON 数组：
- 固定浮动标签（始终跟随最新版）：latest、v1、global-v1、v2、global-v2
- 动态版本标签（取当前语义最大的具体版本）：
  - v1.<x>（latest 之前无 v1.latest，故按版本号排序取最新）
  - global-v1.<x>
  - v2.<x>
  - global-v2.<x>

用法: python3 resolve-tags.py <namespace> [--api-base <url>] [--single <tag>]
"""
import argparse
import json
import re
import sys
import urllib.request


def fetch_tags(namespace, api_base):
    """分页拉取 Docker Hub 仓库的全部 tag 名。"""
    names = []
    url = f"{api_base}/v2/repositories/{namespace}/1panel/tags/?page_size=100"
    while url:
        with urllib.request.urlopen(url, timeout=30) as resp:
            data = json.load(resp)
        names.extend(item["name"] for item in data.get("results", []))
        url = data.get("next")
    return names


def version_key(tag):
    """把版本 tag 转成可比较的数值元组；非常规则的返回 None。"""
    m = re.match(r"^(?:global-)?v(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-(.*))?$", tag)
    if not m:
        return None
    major, minor, patch, suffix = m.groups(default="")
    parts = [int(major), int(minor or 0), int(patch or 0)]
    if suffix:
        parts.append(suffix)
    return parts


def latest_of(tags, prefix):
    """在 tags 中选出以 prefix 开头、版本最大者；无候选返回 None。"""
    cands = [t for t in tags if t.startswith(prefix) and version_key(t)]
    if not cands:
        return None
    return max(cands, key=version_key)


def variant_of(tag):
    return "v1" if tag.startswith(("v1", "global-v1")) else "v2"


def single(namespace, tag, api_base):
    image = f"{namespace}/1panel:{tag}"
    return [{"image": image, "variant": variant_of(tag)}]


def build_matrix(namespace, api_base):
    tags = fetch_tags(namespace, api_base)

    # 固定浮动标签（始终存在，跟随最新版）
    fixed = ["latest", "v1", "global-v1", "v2", "global-v2"]
    entries = [f"{namespace}/1panel:{t}" for t in fixed]

    # 动态最新具体版本（若 Docker Hub 上确实存在则追加，否则跳过）
    dynamic = ["v2", "global-v2", "v1", "global-v1"]
    seen = set(fixed)
    for prefix in dynamic:
        latest = latest_of(tags, prefix)
        if latest and latest not in seen:
            seen.add(latest)
            entries.append(f"{namespace}/1panel:{latest}")

    return [{"image": img, "variant": variant_of(img.rsplit(":", 1)[1])} for img in entries]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("namespace")
    parser.add_argument("--api-base", default="https://hub.docker.com")
    parser.add_argument("--single", default=None)
    args = parser.parse_args()

    if args.single:
        result = single(args.namespace, args.single, args.api_base)
    else:
        result = build_matrix(args.namespace, args.api_base)
    if not result:
        print("::error::未解析出任何待测镜像", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(result))


if __name__ == "__main__":
    main()