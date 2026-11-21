#!/usr/bin/env bash
# 在 NixOS minimal ISO 中重建 qnap-aio 系统盘。
#
# 只格式化 --disk 指定的整盘；data / backup / cache 数据盘绝不触碰。
# 典型的自动化流程见 .claude/skills/nas-reinstall/SKILL.md。
set -euo pipefail

usage() {
  cat <<'EOF'
用法：
  reinstall-from-iso.sh --disk <by-id|/dev/sdX> --bundle <repo.bundle> \
      --rootstate <root-state.tar.zst> [选项]

必选：
  --disk          系统盘设备，建议用 /dev/disk/by-id/ata-XXX
  --bundle        qnap-aio 的 git bundle（需含目标分支）
  --rootstate     root-state 归档（含 /var/lib/sops-nix/key.txt）

选项：
  --branch <b>          安装分支，默认 main
  --expect-serial <s>   目标盘序列号；与 lsblk 不符则立即退出
  --yes                 非交互确认；仍必须同时给 --expect-serial
  --no-root-passwd      传给 nixos-install，跳过设置 root 密码
  --root-hash-file <f>  从文件读取 crypt 哈希并写入新系统 root 密码（自动跳过交互）
  --no-rootstate        跳过 root-state 恢复（不推荐）
  --inputs-dir <dir>    离线 flake 输入目录（nixpkgs/…）；没有代理时强烈推荐
  --proxy <url>         为 nixos-install 设置 http(s)_proxy（仅在仍有代理时使用）
  --allow-removable     允许目标盘 reported as removable（USB 转接时）
  --allow-missing-data  允许找不到 data/backup/cache 标签（仅调试）
  --dry-run             完成所有检查并打印计划，不做任何写入
  --reboot              安装完成后立即重启（默认不重启）
  -h, --help            显示本帮助

安全机制：
  1. 目标盘上任何分区带 data / backup / cache 标签 → 拒绝执行
  2. 目标盘任何分区已挂载 → 拒绝执行
  3. 目标盘是可移动介质（除非 --allow-removable）→ 拒绝执行
  4. 必须存在 data / backup / cache 三块数据盘（除非 --allow-missing-data）
  5. 交互模式必须输入目标盘序列号确认；--yes 模式必须提供 --expect-serial
EOF
}

die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; }

DISK=""
BUNDLE=""
ROOTSTATE=""
BRANCH="main"
EXPECT_SERIAL=""
YES=0
NO_ROOT_PASSWD=0
ROOT_HASH_FILE=""
NO_ROOTSTATE=0
INPUTS_DIR=""
PROXY=""
ALLOW_REMOVABLE=0
ALLOW_MISSING_DATA=0
DRY_RUN=0
REBOOT=0
SUBS="https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store https://cache.nixos.org/ https://qnap-kernel.cachix.org"
KEYS="qnap-kernel.cachix.org-1:HwBIYv2RlW2ZHEeuDP+0HRRKABTcjmd8DMAK9vdopL4="

while [ $# -gt 0 ]; do
  case "$1" in
    --disk) DISK=${2:?}; shift 2 ;;
    --bundle) BUNDLE=${2:?}; shift 2 ;;
    --rootstate) ROOTSTATE=${2:?}; shift 2 ;;
    --branch) BRANCH=${2:?}; shift 2 ;;
    --expect-serial) EXPECT_SERIAL=${2:?}; shift 2 ;;
    --inputs-dir) INPUTS_DIR=${2:?}; shift 2 ;;
    --proxy) PROXY=${2:?}; shift 2 ;;
    --yes) YES=1; shift ;;
    --no-root-passwd) NO_ROOT_PASSWD=1; shift ;;
    --root-hash-file) ROOT_HASH_FILE=${2:?}; shift 2 ;;
    --no-rootstate) NO_ROOTSTATE=1; shift ;;
    --allow-removable) ALLOW_REMOVABLE=1; shift ;;
    --allow-missing-data) ALLOW_MISSING_DATA=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --reboot) REBOOT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（--help 查看用法）" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "必须以 root 运行（ISO 控制台里先 sudo -i）"
[ -n "$DISK" ] || die "缺少 --disk"
[ -n "$BUNDLE" ] || die "缺少 --bundle"
if [ "$NO_ROOTSTATE" -eq 0 ] && [ -z "$ROOTSTATE" ]; then
  die "缺少 --rootstate（确实不恢复请显式加 --no-rootstate）"
fi
if [ "$YES" -eq 1 ] && [ -z "$EXPECT_SERIAL" ]; then
  die "--yes 必须同时提供 --expect-serial"
fi

missing=()
for c in parted mkfs.fat mkfs.ext4 nixos-generate-config nixos-install \
         git tar rsync zstd blkid lsblk findmnt wipefs partprobe; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if [ "${#missing[@]}" -ne 0 ]; then
  die "缺少命令：${missing[*]}
可先进入带工具的 shell 再运行：
  nix shell nixpkgs#git nixpkgs#rsync nixpkgs#zstd nixpkgs#parted nixpkgs#dosfstools nixpkgs#e2fsprogs nixpkgs#util-linux -c bash $0 --help"
fi

[ -f "$BUNDLE" ] || die "找不到 bundle：$BUNDLE"
if [ "$NO_ROOTSTATE" -eq 0 ]; then
  [ -f "$ROOTSTATE" ] || die "找不到 root-state 归档：$ROOTSTATE"
fi
if [ -n "$INPUTS_DIR" ]; then
  [ -d "$INPUTS_DIR" ] || die "找不到离线输入目录：$INPUTS_DIR"
fi
if [ -n "$ROOT_HASH_FILE" ]; then
  [ -f "$ROOT_HASH_FILE" ] || die "找不到 root 哈希文件：$ROOT_HASH_FILE"
  ROOT_HASH=$(tr -d '\r\n' < "$ROOT_HASH_FILE")
  case "$ROOT_HASH" in
    '$'*'$'*) ;;
    *) die "root 哈希文件内容不像 crypt 哈希（应为 \$6\$… 或 \$y\$…）" ;;
  esac
  NO_ROOT_PASSWD=1
fi

# 新根会挂到 /mnt；放在 /mnt 下的归档/输入在挂载后会被遮住
for p in "$BUNDLE" "$ROOTSTATE" "$INPUTS_DIR"; do
  [ -n "$p" ] || continue
  case "$p" in
    /mnt/*) die "路径不能放在 /mnt 下（新根挂载后会遮住）：$p；请挂到 /backup 等目录" ;;
  esac
done

# ── 目标盘识别与安全门 ───────────────────────────────────────────────
[ -b "$DISK" ] || die "$DISK 不是块设备（建议用 /dev/disk/by-id/…）"
DISK_REAL=$(readlink -f "$DISK")
[ -b "$DISK_REAL" ] || die "无法解析 $DISK 的真实设备"
DEV=$(basename "$DISK_REAL")
[ -d "/sys/block/$DEV" ] || die "$DISK_REAL 不是整盘设备"

case "$DEV" in
  mmcblk*)
    die "拒绝把 eMMC/DOM（$DEV）当作系统盘；确有需要请手工分区"
    ;;
esac

SIZE_BYTES=$(lsblk -dnbo SIZE "$DISK_REAL" 2>/dev/null || echo 0)
[ "${SIZE_BYTES:-0}" -ge 8589934592 ] || die "目标盘容量异常，疑似 U 盘或启动介质"

# 防止在已安装系统里误跑：目标盘是当前根盘时直接拒绝
ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null || true)
if [ -n "$ROOT_SRC" ] && [ -b "$ROOT_SRC" ]; then
  ROOT_DISK=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -n1 || true)
  if [ -n "$ROOT_DISK" ] && [ "/dev/$ROOT_DISK" = "$DISK_REAL" ]; then
    die "目标盘是当前运行系统的根盘（$ROOT_SRC），拒绝执行"
  fi
fi

eval "$(lsblk -dn -P -o MODEL,SERIAL,SIZE,RM "$DISK_REAL")"
RM=${RM:-0}

if [ "$RM" = "1" ] && [ "$ALLOW_REMOVABLE" -eq 0 ]; then
  die "目标盘被识别为可移动介质（可能是 U 盘/读卡器）；确认无误后加 --allow-removable"
fi

LABELS=$(lsblk -lnpo LABEL "$DISK_REAL" 2>/dev/null | sed '/^$/d' || true)
for bad in data backup cache; do
  if printf '%s\n' "$LABELS" | grep -qx "$bad"; then
    die "目标盘包含标签 '$bad' 的分区，疑似数据盘，拒绝执行"
  fi
done

MOUNTS=$(lsblk -lnpo MOUNTPOINT "$DISK_REAL" 2>/dev/null | sed '/^$/d' || true)
[ -z "$MOUNTS" ] || die "目标盘有分区已挂载：$MOUNTS"

if findmnt -rn /mnt >/dev/null 2>&1; then
  die "/mnt 当前已挂载，请先卸载（安装脚本要求 /mnt 干净）"
fi

missing_data=()
for l in data backup cache; do
  blkid -t "LABEL=$l" -o device >/dev/null 2>&1 || missing_data+=("$l")
done
if [ "${#missing_data[@]}" -ne 0 ]; then
  if [ "$ALLOW_MISSING_DATA" -eq 1 ]; then
    warn "找不到数据盘标签：${missing_data[*]}（--allow-missing-data 已允许）"
  else
    die "找不到数据盘标签：${missing_data[*]}。请确认数据盘已接好；仅调试时才用 --allow-missing-data"
  fi
fi

if [ -n "$EXPECT_SERIAL" ] && [ "${SERIAL:-}" != "$EXPECT_SERIAL" ]; then
  die "序列号不匹配：目标盘是 '${SERIAL:-<空>}'，期望 '$EXPECT_SERIAL'"
fi

info "安装计划"
cat <<EOF
  目标系统盘 : $DISK_REAL
  型号/序列  : ${MODEL:-?} / ${SERIAL:-?} / ${SIZE:-?}
  分区方案   : GPT，1GiB ESP（label boot）+ 剩余 ext4（label nixos）
  安装分支   : $BRANCH
  仓库 bundle: $BUNDLE
  离线输入   : ${INPUTS_DIR:-未提供（需要能访问 GitHub）}
  root 密码  : $([ -n "$ROOT_HASH_FILE" ] && echo '从哈希文件注入' || { [ "$NO_ROOT_PASSWD" -eq 1 ] && echo '跳过' || echo '安装时交互设置'; })
  root-state : $([ "$NO_ROOTSTATE" -eq 1 ] && echo '跳过' || echo "$ROOTSTATE")
  数据盘     : data / backup / cache 保持不动
EOF

if [ "$DRY_RUN" -eq 1 ]; then
  info "dry-run：检查通过，未写入任何数据"
  exit 0
fi

if [ "$YES" -eq 0 ]; then
  [ -n "${SERIAL:-}" ] || die "目标盘没有可用序列号；请用 --expect-serial 明确指定"
  printf '\n输入目标盘序列号以确认格式化（%s）：' "$SERIAL"
  read -r answer
  [ "$answer" = "$SERIAL" ] || die "确认失败，未做任何修改"
fi

# ── 分区与格式化（只动目标盘）────────────────────────────────────────
info "写入分区表：$DISK_REAL"
wipefs -a "$DISK_REAL"
parted --script "$DISK_REAL" mklabel gpt
parted --script "$DISK_REAL" mkpart ESP fat32 1MiB 1GiB
parted --script "$DISK_REAL" set 1 esp on
parted --script "$DISK_REAL" mkpart primary ext4 1GiB 100%
partprobe "$DISK_REAL" 2>/dev/null || true
udevadm settle 2>/dev/null || sleep 1

PARTS=()
while read -r name type; do
  [ "$type" = "part" ] && PARTS+=("$name")
done < <(lsblk -lnpo NAME,TYPE "$DISK_REAL")
[ "${#PARTS[@]}" -eq 2 ] || die "预期 2 个分区，实际 ${#PARTS[@]} 个"
P1=${PARTS[0]}
P2=${PARTS[1]}

info "格式化 $P1 → boot(vfat) / $P2 → nixos(ext4)"
mkfs.fat -F 32 -n boot "$P1"
mkfs.ext4 -L nixos "$P2"
[ "$(blkid -s LABEL -o value "$P1")" = "boot" ] || die "ESP 标签写入失败"
[ "$(blkid -s LABEL -o value "$P2")" = "nixos" ] || die "root 标签写入失败"

info "挂载到 /mnt"
mkdir -p /mnt
mount "$P2" /mnt
# 必须先挂新根再创建 /mnt/boot，否则会被新根遮住
mkdir -p /mnt/boot
mount "$P1" /mnt/boot

info "生成硬件配置"
nixos-generate-config --root /mnt

info "从 bundle 放置仓库（分支 $BRANCH）"
mkdir -p /tmp/hwconf
mv /mnt/etc/nixos/hardware-configuration.nix /tmp/hwconf/
rm -rf /mnt/etc/nixos
git clone --branch "$BRANCH" "$BUNDLE" /mnt/etc/nixos
mv /tmp/hwconf/hardware-configuration.nix /mnt/etc/nixos/
( cd /mnt/etc/nixos && git add -N -f hardware-configuration.nix )

# ── 离线锁定 flake 输入（无代理时用）──────────────────────────────────
if [ -n "$INPUTS_DIR" ]; then
  cp /mnt/etc/nixos/flake.lock /tmp/flake.lock.qnap-aio.orig
  restore_flake_lock() {
    [ -f /tmp/flake.lock.qnap-aio.orig ] && \
      cp /tmp/flake.lock.qnap-aio.orig /mnt/etc/nixos/flake.lock || true
  }
  trap restore_flake_lock EXIT

  overrides=()
  ov() {
    local name=$1 dir=$2
    [ -d "$INPUTS_DIR/$dir" ] || die "离线输入缺少目录：$dir"
    overrides+=(--override-input "$name" "path:$INPUTS_DIR/$dir")
  }

  ov nixpkgs nixpkgs
  if [ -d "$INPUTS_DIR/nixpkgs-unstable" ]; then
    ov nixpkgs-unstable nixpkgs-unstable
  fi
  for i in sops-nix qnap8528 qnap-kernel router-container; do
    ov "$i" "$i"
  done
  ov qnap-kernel/qnap8528 qnap8528
  ov router-container/yunshu-nix yunshu-nix

  if [ -d "$INPUTS_DIR/nixpkgs-qnap-kernel" ]; then
    ov qnap-kernel/nixpkgs nixpkgs-qnap-kernel
  else
    ov qnap-kernel/nixpkgs nixpkgs
  fi

  if [ -d "$INPUTS_DIR/nixpkgs-qnap8528" ]; then
    ov qnap8528/nixpkgs nixpkgs-qnap8528
    ov qnap-kernel/qnap8528/nixpkgs nixpkgs-qnap8528
  else
    ov qnap8528/nixpkgs nixpkgs
    ov qnap-kernel/qnap8528/nixpkgs nixpkgs
  fi

  info "离线锁定 flake 输入（不访问 GitHub）"
  ( cd /mnt/etc/nixos && \
    nix --extra-experimental-features 'nix-command flakes' \
      flake lock --offline "${overrides[@]}" )
fi

# ── 恢复 root-state（sops 私钥必须在首次启动前到位）──────────────────
if [ "$NO_ROOTSTATE" -eq 0 ]; then
  info "恢复 root-state"
  tmp=$(mktemp -d /tmp/rootstate.XXXXXX)
  tar --zstd -xpf "$ROOTSTATE" -C "$tmp"
  src=""
  for d in "$tmp"/*/root; do
    [ -d "$d" ] && src=$d && break
  done
  [ -n "$src" ] || die "归档中找不到 <目录>/root/"
  rsync -aHAX --numeric-ids "$src/" /mnt/
  [ -f /mnt/var/lib/sops-nix/key.txt ] || die "root-state 中没有 sops 私钥，拒绝继续"
  chown 0:0 /mnt/var/lib/sops-nix/key.txt
  chmod 600 /mnt/var/lib/sops-nix/key.txt
  rm -rf "$tmp"
fi

# ── 安装 ─────────────────────────────────────────────────────────────
info "nixos-install"
if [ -n "$PROXY" ]; then
  export http_proxy="$PROXY" https_proxy="$PROXY"
  export no_proxy="localhost,127.0.0.1,192.168.0.0/16"
fi

install_args=(--flake "/mnt/etc/nixos#default")
[ "$NO_ROOT_PASSWD" -eq 1 ] && install_args+=(--no-root-passwd)

cd /mnt/etc/nixos
nixos-install "${install_args[@]}" \
  --option substituters "$SUBS" \
  --option extra-trusted-public-keys "$KEYS"

# nixos-install 没有“从文件读密码”的选项；这里直接把哈希写进新系统 shadow
if [ -n "$ROOT_HASH_FILE" ]; then
  [ -f /mnt/etc/shadow ] || die "新系统没有 /etc/shadow，无法注入 root 密码"
  awk -F: '$1=="root"{found=1} END{exit !found}' /mnt/etc/shadow \
    || die "shadow 中没有 root 条目"
  tmp=$(mktemp /mnt/etc/.shadow.XXXXXX)
  awk -F: -v h="$ROOT_HASH" 'BEGIN{OFS=":"} $1=="root"{$2=h} {print}' \
    /mnt/etc/shadow > "$tmp"
  chmod --reference=/mnt/etc/shadow "$tmp"
  chown --reference=/mnt/etc/shadow "$tmp"
  mv "$tmp" /mnt/etc/shadow
  got=$(awk -F: '$1=="root"{print $2}' /mnt/etc/shadow)
  [ "$got" = "$ROOT_HASH" ] || die "root 密码哈希写入失败"
  info "root 密码哈希已写入新系统"
fi

info "安装完成"
cat <<'EOF'
后续：
  1. reboot，并拔掉 U 盘
  2. 笔记本接 LAN 口，静态 IP 192.168.10.100/24，ssh nas@192.168.10.2
  3. 按 skill 的验证清单检查（uname -r / 容器 / tun0 / 数据盘 / 服务）
EOF

if [ "$REBOOT" -eq 1 ]; then
  info "按 --reboot 重启"
  reboot
fi
