#!/bin/sh
# 下载生成词表用的 Rime 词库（rime-ice，GPL-3.0）。
set -eu
cd "$(dirname "$0")/.."
out=build/rime-ice
mkdir -p "$out"
for f in cn_dicts/8105.dict.yaml cn_dicts/base.dict.yaml cn_dicts/others.dict.yaml; do
	target="$out/$(basename "$f")"
	[ -s "$target" ] && continue
	echo "下载 $f"
	curl -sSL --http1.1 --retry 4 --retry-all-errors --max-time 180 \
		-o "$target" "https://cdn.jsdelivr.net/gh/iDvel/rime-ice@main/$f"
done
