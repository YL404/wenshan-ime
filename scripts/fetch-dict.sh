#!/bin/sh
# 下载生成词表用的万象词库（rime-wanxiang-data，CC BY 4.0）和单字辅码表（rime-frost，GPL-3.0）。
set -eu
cd "$(dirname "$0")/.."
out=build/wanxiang
mkdir -p "$out"

need_dicts=0
for f in zi.dict.yaml jichu.dict.yaml duoyin.dict.yaml diming.dict.yaml mingren.dict.yaml en.dict.yaml; do
	[ -s "$out/$f" ] || need_dicts=1
done

if [ "$need_dicts" -eq 1 ]; then
	zip="$out/dicts.zip"
	url="https://github.com/amzxyz/rime-wanxiang-data/releases/download/dict-nightly/dicts.zip"
	proxy_url="https://gh-proxy.org/$url"
	if [ ! -s "$zip" ]; then
		echo "下载万象词库 dicts.zip"
		if ! curl -sSL --http1.1 --retry 3 --retry-all-errors --max-time 240 -o "$zip.part" "$proxy_url"; then
			rm -f "$zip.part"
			curl -sSL --http1.1 --retry 3 --retry-all-errors --max-time 240 -o "$zip.part" "$url"
		fi
		mv "$zip.part" "$zip"
	fi
	unzip -o -j "$zip" \
		dicts/zi.dict.yaml dicts/jichu.dict.yaml dicts/duoyin.dict.yaml \
		dicts/diming.dict.yaml dicts/mingren.dict.yaml dicts/en.dict.yaml \
		-d "$out" >/dev/null
fi

aux=build/aux/moqi_aux_code.txt
mkdir -p "$(dirname "$aux")"
if [ ! -s "$aux" ]; then
	echo "下载辅码表"
	curl -sSL --http1.1 --retry 4 --retry-all-errors --max-time 180 \
		-o "$aux" "https://cdn.jsdelivr.net/gh/gaboolic/rime-frost@master/lua/aux_code/moqi_aux_code.txt"
fi
