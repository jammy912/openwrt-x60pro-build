# OpenWrt for Ruijie RG-X60 Pro — 107M UBI layout

用 GitHub Actions 從**官方 OpenWrt 原始碼**編譯 Ruijie RG-X60 Pro 的 image，並把 UBI 分割從 63 MiB 擴大成 107 MiB。
編出來的 kernel vermagic 和官方 release 一致，所以刷好之後仍然可以直接 `apk add` 官方 feed 的 kmod。

> ⚠️ 這個 image **只能**用在已經刷入 Yuzhii U-Boot（[bl-mt798x-dhcpd](https://github.com/Yuzhii0718/bl-mt798x-dhcpd)）、而且 layout 選 `ubi-107m` 的機器上。
> 原廠 Ruijie U-Boot 把 ubi 寫死成 `64512k`，直接刷這個 image 會開不了機。

## 分割表

和 Yuzhii U-Boot 的 `ubi-107m` layout 完全一致：

```
nmbm0:1024k(bl2),512k(u-boot-env),2048k(Factory),2048k(fip),512k(product_info),512k(kdump),109568k(ubi)
```

| 分割 | 起點 | 大小 |
|---|---|---|
| ubi（官方） | `0x680000` | `0x3f00000`（63 MiB） |
| ubi（本 repo） | `0x680000` | `0x6b00000`（107 MiB，共 856 個 PEB） |

`product_info` 不能刪，官方的 `02_network` 和 `11_fix_wifi_mac` 都從這裡讀 MAC 位址。

## Repo 結構

| 檔案 | 用途 |
|---|---|
| `.github/workflows/build.yml` | clone 官方 tag → 套用 patch → 產生 config → 編譯 → 驗證 image |
| `scripts/patch-107m.sh` | 新增 `ruijie_rg-x60-pro-107m` device：複製官方 DTS 後用 sed 改 reg、compatible、model；board 腳本加上新的 board name。改之前和改之後都會驗證，不符就失敗 |
| `scripts/make-config.sh` | 以官方同版本的 `config.buildinfo` 為 seed，加上 `config/packages.txt` 的套件，再跑 `make defconfig`，並驗證每個套件都有選到 |
| `scripts/verify-image.sh` | 從 sysupgrade.bin 拆出 FIT 內的 DTB，檢查 ubi 是 `0x680000 + 0x6b00000`，並檢查 metadata |
| `config/packages.txt` | 要內建進 squashfs 的套件；前面加 `-` 表示排除 |

## 使用方式

1. 到 Actions 頁籤，選「Build OpenWrt for RG-X60 Pro (107M)」，按 Run workflow，輸入官方 tag（例如 `v25.12.5`）。
2. workflow 會依序檢查以下關卡，任何一項不符就直接失敗：
   - 上游 DTS 的 ubi reg、compatible、model，以及 7 個 partition 起點都和預期一致。
   - `packages.txt` 的每個套件在 `make defconfig` 之後都還是 `=y`。
   - 編完 kernel 後，`.vermagic` 等於官方 kmods 目錄的 hash。
   - 產出的 image 中，DTB 的 ubi 分割是 107M，board 是 `ruijie,rg-x60-pro-107m`。
3. 產出在 artifact，內含 `*-squashfs-sysupgrade.bin`、`*-initramfs-kernel.bin`、`sha256sums`、`vermagic.txt`、`verify-report.txt`、`defconfig.diff`。

在本機驗證 image（Linux 或 WSL）：

```bash
sudo apt-get install -y u-boot-tools device-tree-compiler
bash scripts/verify-image.sh <...-ruijie_rg-x60-pro-107m-squashfs-sysupgrade.bin>
```

## 設計重點

- **vermagic 和官方一致**：vermagic 是 kernel `.config` 中所有 `=y`/`=m` 的 md5，會受到被選取 kmod 的 KCONFIG 影響（見 `include/kernel-defaults.mk`）。所以保留官方的 `CONFIG_ALL_KMODS` 和 `CONFIG_COLLECT_KERNEL_DEBUG`，只拿掉 device 選擇、SDK、ImageBuilder 等產出物設定。
- **套件組合與官方 release 相同**（`config/packages.txt` 為空），其餘套件刷機後再用 apk 安裝。
- **新的 board name `ruijie,rg-x60-pro-107m`**：官方 63MB 版的 image 會被 sysupgrade 的 metadata 檢查拒絕。image 內仍有官方的 `owut` / `attendedsysupgrade`，**不要用它們升級**。升級伺服器沒有這個 profile，理論上會直接失敗，但不要依賴這一點；一律用本 repo 編出的 sysupgrade.bin 升級。
- **跨版本升級**：只要改 workflow 的 tag 輸入。上游如果改了相關的 DTS、檔案或套件名稱，workflow 會直接失敗，提醒你人工確認，不會默默編出錯誤的 image。

## 刷機流程概要

1. 備份所有 mtd 分割，特別是 `Factory` 和 `product_info`，這兩個無法重建。
2. 刷入 Yuzhii FIP，**layout 保持 default**，先確認現有系統照常開機。
3. 進入 failsafe 的 Web Console，執行 `mtd list` 和 `nmbm nmbm0 info`，確認 NAND 容量足夠（nmbm0 ≥ `0x7180000`）。
4. 把 layout 切成 `ubi-107m`，執行 `mtd erase ubi`，再上傳本 repo 的 sysupgrade.bin。
5. 開機後確認：`/proc/mtd` 的 ubi 是 `06b00000`，`/sys/class/ubi/ubi0/total_eraseblocks` 是 856。

刷 FIP 有變磚風險，救援需要 USB-TTL。使用風險自負。
