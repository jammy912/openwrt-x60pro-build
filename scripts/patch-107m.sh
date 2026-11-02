#!/usr/bin/env bash
# 為 Ruijie RG-X60 Pro 新增 107M 版 device profile（ruijie_rg-x60-pro-107m）。
#
# 用法: scripts/patch-107m.sh <openwrt 源碼目錄>
#
# 設計原則（為了跨大版本 25.12 -> 26.x 沿用）：
#   - 不用 context patch，全部用「數值取代 + 取代後驗證」。
#   - 上游只要改了我們依賴的任何一行，就直接 exit 1（失敗要大聲），
#     絕不默默編出 63MB 分割的 image。
#   - 官方 DTS 原檔不動，複製成新檔再改；官方 profile 照樣存在。
#
# 分割表必須與 Yuzhii U-Boot（bl-mt798x-dhcpd）的 layout "ubi-107m" 完全一致：
#   nmbm0:1024k(bl2),512k(u-boot-env),2048k(Factory),2048k(fip),
#         512k(product_info),512k(kdump),109568k(ubi)
#   => ubi 起點 0x680000（不動），大小 109568k = 0x6B00000（107 MiB）
#   來源: Yuzhii0718/bl-mt798x-dhcpd
#         uboot-mtk-20250711/arch/arm/dts/mt7986a-ruijie-x60-pro.dts  mtd-layout/layout@1
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }

[ $# -eq 1 ] || die "用法: $0 <openwrt 源碼目錄>"
cd "$1"

SRC_DTS=target/linux/mediatek/dts/mt7986a-ruijie-rg-x60-pro.dts
NEW_DTS=target/linux/mediatek/dts/mt7986a-ruijie-rg-x60-pro-107m.dts
MK=target/linux/mediatek/image/filogic.mk

OLD_REG='reg = <0x680000 0x3f00000>;'
NEW_REG='reg = <0x680000 0x6b00000>;'
OLD_COMPAT='compatible = "ruijie,rg-x60-pro", "mediatek,mt7986a";'
NEW_COMPAT='compatible = "ruijie,rg-x60-pro-107m", "mediatek,mt7986a";'
OLD_MODEL='model = "Ruijie RG-X60 Pro";'
NEW_MODEL='model = "Ruijie RG-X60 Pro (107M)";'

# 官方 DTS 的 partition 起點清單；任何一個變了都代表分割表被上游改過，必須人工重審
EXPECTED_PARTS='partition@0 partition@100000 partition@180000 partition@380000 partition@580000 partition@600000 partition@680000'

echo "== 1/3 DTS =="
[ -f "$SRC_DTS" ] || die "找不到 $SRC_DTS（上游改檔名了？）"

[ "$(grep -cF "$OLD_REG" "$SRC_DTS")" = 1 ] \
  || die "上游 DTS 的 ubi reg 不是預期的 '$OLD_REG'（或出現不只一次）。請人工比對新版分割表與 Yuzhii U-Boot ubi-107m layout 後再更新本腳本。"
grep -qF "$OLD_COMPAT" "$SRC_DTS" || die "上游 DTS 的 compatible 行變了: 預期 '$OLD_COMPAT'"
grep -qF "$OLD_MODEL"  "$SRC_DTS" || die "上游 DTS 的 model 行變了: 預期 '$OLD_MODEL'"

GOT_PARTS=$(grep -oE 'partition@[0-9a-f]+' "$SRC_DTS" | tr '\n' ' ' | sed 's/ $//')
[ "$GOT_PARTS" = "$EXPECTED_PARTS" ] \
  || die "上游 DTS 的 partition 清單變了。預期: [$EXPECTED_PARTS] 實際: [$GOT_PARTS]"

# ubi 的 reg 必須真的屬於 label "ubi" 的那個節點
grep -A3 'partition@680000' "$SRC_DTS" | grep -qF 'label = "ubi";' \
  || die "partition@680000 的 label 不是 ubi"

cp "$SRC_DTS" "$NEW_DTS"
sed -i \
  -e "s|$OLD_REG|$NEW_REG|" \
  -e "s|$OLD_COMPAT|$NEW_COMPAT|" \
  -e "s|$OLD_MODEL|$NEW_MODEL|" \
  "$NEW_DTS"

[ "$(grep -cF "$NEW_REG" "$NEW_DTS")" = 1 ] || die "DTS reg 取代失敗"
grep -qF "$NEW_COMPAT" "$NEW_DTS" || die "DTS compatible 取代失敗"
grep -qF "$NEW_MODEL"  "$NEW_DTS" || die "DTS model 取代失敗"
! grep -qF "$OLD_REG" "$NEW_DTS" || die "新 DTS 仍殘留 63MB reg"
echo "OK: $NEW_DTS"
grep -n -A3 'partition@680000' "$NEW_DTS"

echo "== 2/3 filogic.mk =="
grep -q '^define Device/ruijie_rg-x60-pro$' "$MK" || die "$MK 裡找不到 Device/ruijie_rg-x60-pro（上游改名了？）"
if grep -q '^define Device/ruijie_rg-x60-pro-107m$' "$MK"; then
  echo "已存在 Device/ruijie_rg-x60-pro-107m，略過"
else
  # 繼承官方 profile（DEVICE_PACKAGES、IMAGE 等跟著上游走），只覆寫 DTS 與 board name
  cat >> "$MK" <<'EOF'

define Device/ruijie_rg-x60-pro-107m
$(call Device/ruijie_rg-x60-pro)
  DEVICE_VARIANT := 107M (Yuzhii U-Boot ubi-107m layout)
  DEVICE_DTS := mt7986a-ruijie-rg-x60-pro-107m
  SUPPORTED_DEVICES := ruijie,rg-x60-pro-107m
endef
TARGET_DEVICES += ruijie_rg-x60-pro-107m
EOF
fi
grep -n -A7 '^define Device/ruijie_rg-x60-pro-107m$' "$MK"

echo "== 3/3 board_name 腳本（MAC 位址、網路埠） =="
# 新 board name = ruijie,rg-x60-pro-107m，所有 case 分支要同時認得新名字
mapfile -t FILES < <(grep -rlE 'ruijie,rg-x60-pro[|)]' target/linux/mediatek/filogic/base-files package || true)
[ "${#FILES[@]}" -ge 1 ] || die "找不到任何引用 ruijie,rg-x60-pro 的 board 腳本（上游結構變了？）"
for f in "${FILES[@]}"; do
  if grep -q 'ruijie,rg-x60-pro-107m' "$f"; then
    echo "已處理過: $f"
    continue
  fi
  sed -i -E 's/ruijie,rg-x60-pro([|)])/ruijie,rg-x60-pro|ruijie,rg-x60-pro-107m\1/g' "$f"
  echo "patched: $f"
done
# 驗證：每一個 case 分支都要同時含新名字
LEFT=$(grep -rnE 'ruijie,rg-x60-pro[|)]' "${FILES[@]}" | grep -v 'rg-x60-pro-107m' || true)
[ -z "$LEFT" ] || die "仍有 case 分支沒加上 107m: $LEFT"
grep -rn 'rg-x60-pro-107m' "${FILES[@]}"

# 其他寫法的引用（非 case 分支）只警告，讓人工判斷
OTHER=$(grep -rn 'ruijie,rg-x60-pro' target/linux/mediatek package feeds 2>/dev/null \
        | grep -v 'rg-x60-pro-107m' | grep -vE '\.dts:|filogic\.mk:' || true)
if [ -n "$OTHER" ]; then
  echo "::warning::以下引用 ruijie,rg-x60-pro 的地方未自動處理，請人工確認是否需要 107m："
  echo "$OTHER"
fi

echo "patch-107m: 全部完成"
