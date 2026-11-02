#!/usr/bin/env bash
# 產生 .config：以「官方同版本的 config.buildinfo」為 seed，換成單一 107M device，
# 加上 config/packages.txt 的套件，再 make defconfig 自動補齊。
#
# 用法: scripts/make-config.sh <openwrt 源碼目錄> <版本號，例 25.12.5> <packages.txt>
#
# 為什麼用官方 config.buildinfo 當 seed：
#   kernel 的 vermagic = md5(kernel .config 裡所有 =y/=m)，而 kernel .config 會被
#   「被選取的 kmod 的 KCONFIG」與 CONFIG_KERNEL_* 影響（include/kernel-defaults.mk）。
#   官方 build 開了 CONFIG_ALL_KMODS 與 COLLECT_KERNEL_DEBUG(→KERNEL_DEBUG_INFO)，
#   我們必須保留同樣設定，vermagic 才會與官方一致，之後才能直接 apk add 官方 kmods。
#   seed 每次從官方伺服器依版本號抓，換大版本時不用手改。
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }
[ $# -eq 3 ] || die "用法: $0 <openwrt 目錄> <版本號> <packages.txt>"

PKGS_FILE=$(realpath "$3")
cd "$1"
VER=$2
BASE="https://downloads.openwrt.org/releases/$VER/targets/mediatek/filogic"
DEVICE=ruijie_rg-x60-pro-107m

curl -fsSL "$BASE/config.buildinfo" -o official.buildinfo || die "抓不到 $BASE/config.buildinfo"

# 解析套件清單
INCLUDE=(); EXCLUDE=()
while IFS= read -r line; do
  line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
  [ -z "$line" ] && continue
  if [ "${line:0:1}" = "-" ]; then EXCLUDE+=("${line:1}"); else INCLUDE+=("$line"); fi
done < "$PKGS_FILE"
echo "套件：內建 ${#INCLUDE[@]} 個，排除 ${#EXCLUDE[@]} 個"

# 從官方 seed 拿掉：所有 device 選擇、建 SDK/ImageBuilder/toolchain/SBOM/全部 userspace 套件
#（這些只影響產出物與編譯時間，不影響 kernel config），以及要排除的套件
EXCL_RE=$(printf '%s|' "${EXCLUDE[@]}"); EXCL_RE="${EXCL_RE%|}"
grep -vE '^CONFIG_TARGET_DEVICE_|^CONFIG_TARGET_ALL_PROFILES=|^CONFIG_(SDK|SDK_LLVM_BPF|IB|MAKE_TOOLCHAIN|ALL_NONSHARED|JSON_CYCLONEDX_SBOM)=' official.buildinfo \
  | grep -vE "^CONFIG_PACKAGE_(${EXCL_RE})=" > .config

{
  echo "CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_${DEVICE}=y"
  echo "# CONFIG_TARGET_ALL_PROFILES is not set"
  echo "# CONFIG_SDK is not set"
  echo "# CONFIG_IB is not set"
  echo "# CONFIG_MAKE_TOOLCHAIN is not set"
  echo "# CONFIG_ALL_NONSHARED is not set"
  echo "# CONFIG_JSON_CYCLONEDX_SBOM is not set"
  for p in "${INCLUDE[@]}"; do echo "CONFIG_PACKAGE_${p}=y"; done
  for p in "${EXCLUDE[@]}"; do echo "# CONFIG_PACKAGE_${p} is not set"; done
} >> .config

cp .config seed.config
make defconfig > defconfig.log 2>&1 || { cat defconfig.log; die "make defconfig 失敗"; }
diff -u seed.config .config > defconfig.diff || true
echo "defconfig 前後差異：$(grep -c '^[-+][^-+]' defconfig.diff || true) 行（完整內容見 artifact defconfig.diff）"

# ---- 驗證：任何一項不符就 fail ----
FAIL=0
chk_y() { grep -q "^$1=y$" .config || { echo "::error::缺少 $1=y"; FAIL=1; }; }
chk_y "CONFIG_TARGET_mediatek_filogic"
chk_y "CONFIG_TARGET_MULTI_PROFILE"
chk_y "CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_${DEVICE}"
chk_y "CONFIG_ALL_KMODS"
chk_y "CONFIG_COLLECT_KERNEL_DEBUG"
for p in "${INCLUDE[@]}"; do chk_y "CONFIG_PACKAGE_${p}"; done
for p in "${EXCLUDE[@]}"; do
  grep -q "^CONFIG_PACKAGE_${p}=[ym]$" .config && { echo "::error::$p 應排除但被選進來（被其他套件依賴？）"; FAIL=1; }
done
grep -q '^CONFIG_VERSION_REPO="https://downloads.openwrt.org/releases/' .config \
  || { echo "::error::CONFIG_VERSION_REPO 不是官方 releases，distfeeds 會指錯"; FAIL=1; }
[ $FAIL = 0 ] || die ".config 驗證失敗（套件名稱在新版可能更名或移除，請修改 config/packages.txt）"
echo "make-config: .config 驗證通過"
