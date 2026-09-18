#!/usr/bin/env bash
# 在 NAS 上以 root 运行：bash scripts/deploy-nas.sh
#
# 远端部署专用。除了 pull/build/boot，还做一件本地不需要的事：把**回滚保险**
# 设好——默认启动项 = 当前正在跑的世代，oneshot = 新世代。新系统若起不来，
# 断电重启会自动落回能用的那一版。
#
# ⚠️ 保险的"当前世代"必须按 /run/current-system 反查，不能读 profile 的
#    current：从 boot 菜单选旧条目启动**不会改 profile**，读 profile 会把保险
#    设到上一版（可能同样是坏的）上，等于没保。2026-09-18 那次就踩了。
#
# 这次部署包含 LAN 从 macvlan 换成 bridge + 接口改名，是网络层的最大变化。
# 回滚：重启时在 boot 菜单选旧条目，或进来后 nixos-rebuild switch --rollback。
set -uo pipefail

FLAKE=/home/nas/qnap-aio-git

echo "══════ 1. 预检 ══════"
[ "$(id -u)" = 0 ] || { echo "✗ 需要 root"; exit 1; }
echo "  ✓ root"

for d in /srv/state/router/yunshu /srv/state/router/dnsmasq; do
  [ -d "$d" ] || { echo "✗ 缺 $d —— 状态没迁过来，部署会丢 YunShu 登录态"; exit 1; }
done
[ -f /srv/state/router/yunshu/config/.logged-in ] \
  || { echo "✗ 缺 .logged-in —— YunShu 登录态不在，部署后要重登"; exit 1; }
echo "  ✓ 状态目录与登录标记就位"

echo
echo "══════ 2. 回滚目标（记住这个）══════"
echo -n "  当前系统: "; readlink -f /run/current-system | sed 's|.*/||'
echo "  重启后 boot 菜单里选旧条目即可回滚"
echo -n "  当前宿主地址: "; ip -br addr show mv-shim 2>/dev/null | tr -s ' ' | cut -d' ' -f3 \
  || ip -br addr show br-lan 2>/dev/null | tr -s ' ' | cut -d' ' -f3

echo
echo "══════ 3. 拉取最新代码 ══════"
cd "$FLAKE" || exit 1
# 本机构建会把 flake.lock 改脏，先丢掉（权威版本在已推送的提交里）
git checkout -- flake.lock 2>/dev/null || true
git pull --rebase 2>&1 | tail -2 || { echo "✗ 拉取失败"; exit 1; }
echo -n "  HEAD: "; git log --oneline -1

echo
echo "══════ 4. 构建 ══════"
if nixos-rebuild build --flake .#default > /tmp/deploy-build.log 2>&1; then
  echo "  ✓ 构建通过"
else
  echo "  ✗ 构建失败，中止。日志尾部："
  tail -15 /tmp/deploy-build.log
  exit 1
fi

echo
echo "══════ 5. 生成启动项 ══════"
# 回滚目标必须是**当前正在跑**的世代，不能读 profile 的 current：
# 从 boot 菜单选旧条目启动时 profile 不会变——上次就因此把"保险"设到了
# 上一版失败的世代上，等于没保。
RUNNING=$(readlink -f /run/current-system)
CUR_GEN=""
for link in /nix/var/nix/profiles/system-*-link; do
  if [ "$(readlink -f "$link")" = "$RUNNING" ]; then
    CUR_GEN=$(basename "$link" | sed "s/^system-\([0-9]*\)-link$/\1/")
    break
  fi
done
if [ -n "$CUR_GEN" ]; then
  echo "  当前世代: $CUR_GEN（正在运行的，作为回滚目标）"
else
  echo "  ⚠ 认不出当前世代号，本次不设回滚保险（新世代会成为默认）"
fi
nixos-rebuild boot --flake .#default 2>&1 | tail -3 || { echo "  ✗ boot 失败"; exit 1; }
NEW_GEN=$(nix-env --profile /nix/var/nix/profiles/system --list-generations 2>/dev/null | tail -1 | awk "{print \$1}")
echo "  新世代:   $NEW_GEN"

echo
echo "══════ 6. 设远程保险：默认=当前，oneshot=新世代 ══════"
# 远端部署专用：新系统若起不来，断电重启会落回已知可用的旧世代。
# 验证通过后再把默认切到新世代（见 verify-router.sh 末尾）。
bootctl set-oneshot "nixos-generation-$NEW_GEN" >/dev/null 2>&1 \
  && echo "  ✓ oneshot → nixos-generation-$NEW_GEN（只生效一次）" \
  || { echo "  ⚠ set-oneshot 失败 —— 那么新世代会成为默认，起不来就只能靠控制台"; }
if [ -n "$CUR_GEN" ]; then
  bootctl set-default "nixos-generation-$CUR_GEN" >/dev/null 2>&1 \
    && echo "  ✓ 默认 → nixos-generation-$CUR_GEN（断电重启落回这个）" \
    || echo "  ⚠ set-default 失败"
fi
bootctl status 2>/dev/null | grep -iE "^ *(Default|Boot|OneShot)" | head -5

echo
echo "  10 秒后重启（Ctrl-C 取消）"
echo "  重启后：工作站上跑 verify-router.sh"
echo "  若彻底失联：让人断电重启 → 会自动回到 $CUR_GEN"
sleep 10
systemctl reboot
