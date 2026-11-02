#!/usr/bin/env bash
# 刷機前驗證 sysupgrade image 的分割表真的是 107M。
# 原理：sysupgrade.bin 是 tar，內含 FIT 格式的 kernel；FIT 內嵌 DTB，
#       Linux 開機後的 MTD 分割完全由這份 DTB 決定。把它拆出來反編譯檢查即可。
#
# 用法: scripts/verify-image.sh <xxx-ruijie_rg-x60-pro-107m-squashfs-sysupgrade.bin>
# 需要: tar、dumpimage（u-boot-tools）、dtc（device-tree-compiler）
#   Ubuntu/WSL: sudo apt-get install -y u-boot-tools device-tree-compiler
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }
[ $# -ge 1 ] && [ $# -le 2 ] || die "用法: $0 <sysupgrade.bin> [packages.txt]"
IMG=$1
PKGS_FILE=${2:-}
[ -f "$IMG" ] || die "找不到 $IMG"
for t in tar dumpimage dtc; do command -v $t >/dev/null || die "缺少工具 $t"; done
[ -z "$PKGS_FILE" ] || command -v unsquashfs >/dev/null || die "缺少工具 unsquashfs（squashfs-tools）"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
tar -xf "$IMG" -C "$T" 2>/dev/null || die "不是 tar 格式（拿錯檔案？要 squashfs-sysupgrade.bin）"
K=$(find "$T" -type f -name kernel | head -n1)
[ -n "$K" ] || die "tar 內找不到 kernel"
echo "tar 內容："; (cd "$T" && find . -type f | sort)

dumpimage -l "$K" > "$T/fit.txt"
IDX=$(awk '/^ *Image [0-9]+ \(fdt/ {print $2; exit}' "$T/fit.txt")
[ -n "$IDX" ] || { cat "$T/fit.txt"; die "FIT 內找不到 fdt image"; }
dumpimage -T flat_dt -p "$IDX" -o "$T/board.dtb" "$K" >/dev/null
dtc -q -I dtb -O dts -o "$T/board.dts" "$T/board.dtb"

echo "== DTB root compatible / model =="
grep -m2 -E '^\s*(compatible|model) = ' "$T/board.dts"
grep -m1 -E '^\s*compatible = ' "$T/board.dts" | grep -qF '"ruijie,rg-x60-pro-107m"' \
  || die "board compatible 不是 ruijie,rg-x60-pro-107m"

echo "== MTD 分割（DTB 內） =="
awk '/partition@[0-9a-f]+ \{/ {p=$1} p && /label =/ {l=$3} p && /reg =/ {print p, l, $3, $4; p=""}' "$T/board.dts" | tr -d '";<>'
UBI=$(awk '/partition@680000 \{/ {f=1} f && /reg =/ {print; exit}' "$T/board.dts" | sed -E 's/^[[:space:]]+//')
[ "$UBI" = "reg = <0x680000 0x6b00000>;" ] \
  || die "ubi 分割不是 0x680000 + 0x6b00000，實際: $UBI"
echo "OK: ubi = 0x680000 起，0x6b00000 (107 MiB) = 856 個 128KiB PEB，對齊 Yuzhii ubi-107m layout"

echo "== sysupgrade metadata supported_devices =="
META=$(grep -aoE '"supported_devices" *: *\[[^]]*\]' "$IMG" | head -n1 || true)
echo "${META:-（找不到 metadata）}"
echo "$META" | grep -qF '"ruijie,rg-x60-pro-107m"' || die "metadata 的 supported_devices 不含 ruijie,rg-x60-pro-107m"
echo "$META" | grep -qE '"ruijie,rg-x60-pro"' && die "metadata 竟然允許官方 board name，會讓 63MB 版互刷"

if [ -n "$PKGS_FILE" ]; then
  echo "== rootfs 實際安裝的套件（/lib/apk/db/installed） =="
  R=$(find "$T" -type f -name root | head -n1)
  [ -n "$R" ] || die "tar 內找不到 root（squashfs）"
  unsquashfs -cat "$R" lib/apk/db/installed 2>/dev/null | sed -n 's/^P://p' | sort -u > "$T/installed.txt"
  [ -s "$T/installed.txt" ] || die "讀不到 rootfs 的 apk installed db"
  echo "共 $(wc -l < "$T/installed.txt") 個套件"
  PFAIL=0
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
    case "$line" in
      ''|CONFIG_*) ;;
      -*) grep -qxF "${line:1}" "$T/installed.txt" && { echo "::error::image 內不該有 ${line:1}"; PFAIL=1; } ;;
      *)  grep -qxF "$line" "$T/installed.txt" || { echo "::error::image 內缺少 $line"; PFAIL=1; } ;;
    esac
  done < "$PKGS_FILE"
  [ $PFAIL = 0 ] || die "image 套件內容與 packages.txt 不符"
  echo "OK: packages.txt 的內建/排除全部符合"
fi

echo "verify-image: 全部通過"
