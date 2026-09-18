#!/usr/bin/env bash
# 在本机 libvirt 测试 VM 上验证 qnap-aio 改动，**不碰生产 NAS**。
#
#   ./scripts/vm-test.sh            # 装配 + 构建 + 部署 + 验证（默认）
#   ./scripts/vm-test.sh build      # 只装配 + 构建
#   ./scripts/vm-test.sh deploy     # 只 boot + 重启
#   ./scripts/vm-test.sh verify     # 只验证（等 boot_id 变化后跑检查）
#   ./scripts/vm-test.sh status     # 看一眼 VM 现状
#
# 为什么需要这个脚本（都是踩过的坑）：
#   1. **VM 拉不了 GitHub**。VM 里没有 YunShu 登录态，出口是直连，github.com
#      连不上——而 flake input 默认走 git+https。所以必须把 router-container /
#      yunshu-nix 的源码 scp 进去并用 --override-input path: 覆盖。
#   2. **VM 自己的配置不能覆盖**。`configuration.nix`（去掉 qnap8528）、
#      `vm-sops-stub.nix`（无 age 私钥）、`hardware-configuration.nix`（真实
#      virtio 盘）三份是 VM 专属的，装配时要保留。
#   3. **VM 的 flake/覆盖也要适配**。接口改名后 links 是 10-wan/10-lan、
#      宿主机 DNS 挂在 br-lan 上，而"保命地址"192.168.122.250 必须挂到
#      br-lan——挂 mv-shim 的话 bridge 改造后就失去 SSH 入口了。
set -uo pipefail

VM=${VM:-192.168.122.250}
DOMAIN=${DOMAIN:-nixos-26.05}
WS=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)   # 工作区根
QNAP=$WS/qnap-aio
SSHOPT="-i $HOME/.ssh/id_ed25519_ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
SSH="ssh $SSHOPT root@$VM"
SCP="scp $SSHOPT"
REMOTE=/root/qnap-aio-vm
# deploy 把"重启前的 boot_id"写在这里给 verify 读。不让 verify 自己现读——
# VM 启动很快，deploy 与 verify 之间隔的那几秒够它重启完，verify 会把重启
# **后**的 id 当成基线，然后干等 6 分钟（2026-09-18 踩过）。
STATE=${TMPDIR:-/tmp}/vm-test-boot-id

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

vm_up() { timeout 8 $SSH true >/dev/null 2>&1; }

# ── 装配：把仓库代码送进去，保留 VM 专属文件 ──────────────────────────
do_assemble() {
  say "装配：打包源码 → scp → 在 VM 里组树"
  local tmp; tmp=$(mktemp -d)
  for r in qnap-aio router-container yunshu-nix; do
    tar czf "$tmp/$r.tar.gz" --exclude=.git --exclude=result --exclude='result-*' -C "$WS" "$r" || die "打包 $r 失败"
  done
  $SCP "$tmp"/*.tar.gz root@$VM:/root/ || die "scp 失败"
  rm -rf "$tmp"

  $SSH 'set -e
    cd /root
    for r in qnap-aio router-container yunshu-nix; do
      rm -rf "$r.new"; mkdir "$r.new"
      tar xzf "$r.tar.gz" -C "$r.new" --strip-components=1
    done
    # router-container / yunshu-nix：直接换掉
    rm -rf router-container yunshu-nix
    mv router-container.new router-container
    mv yunshu-nix.new     yunshu-nix
    # qnap-aio：保留 VM 专属的三份文件
    rm -rf '"$REMOTE"'; mv qnap-aio.new '"$REMOTE"'
    cp /root/qnap-aio/configuration.nix          '"$REMOTE"'/
    cp /root/qnap-aio/vm-sops-stub.nix           '"$REMOTE"'/
    cp /root/qnap-aio/hardware-configuration.nix '"$REMOTE"'/
  ' || die "VM 侧装配失败"

  # VM 专属的 flake / vm-test 覆盖（每次重写，保证跟上接口名变化）
  $SSH "cat > $REMOTE/flake.nix" <<'FLAKE'
{
  description = "测试 VM 版 qnap-aio（去掉 QNAP 专属输入）";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    router-container = {
      url = "git+https://github.com/allenmagic/router-container";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = { self, nixpkgs, ... }@inputs: {
    nixosConfigurations.default = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        ./configuration.nix ./vm-sops-stub.nix ./vm-test.nix
        ./modules/system ./modules/network ./modules/gateway
        ./modules/security ./modules/users
      ];
    };
  };
}
FLAKE

  $SSH "cat > $REMOTE/vm-test.nix" <<'VMTEST'
# VM 测试专用覆盖（已适配 bridge 架构）
{ config, lib, pkgs, ... }:
{
  boot.supportedFilesystems = [ "btrfs" ];
  boot.kernelModules = [ "btrfs" ];

  # VM 网卡是 virtio，MAC 与生产不同。注意用新的接口名 wan/lan
  systemd.network.links."10-wan".matchConfig.MACAddress = lib.mkForce "52:54:00:13:83:94";
  systemd.network.links."10-lan".matchConfig.MACAddress = lib.mkForce "52:54:00:ae:56:87";

  # 解析走 libvirt 网关，不走隧道。接口名从 mv-shim 改成 br-lan
  systemd.network.networks."30-br-lan".networkConfig.DNS =
    lib.mkForce [ "192.168.122.1" "223.5.5.5" ];

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDxOVLqS8pbklbsF+dM+frmUC4nFD9czNqkx5XsuEVE9"
  ];

  # 保命地址：bridge 改造后 mv-shim 不存在，必须挂 br-lan，否则失去 SSH 入口
  systemd.services.vm-test-addr = {
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-networkd.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      ${pkgs.iproute2}/bin/ip addr add 192.168.122.250/24 dev br-lan 2>/dev/null || true
    '';
  };
}
VMTEST
  echo "  ✓ 装配完成（TESTING.md 里记的坑见脚本头部注释）"
}

# ── 构建 ─────────────────────────────────────────────────────────────
# 必须写成一行：换行插进远程命令会被 shell 当成另一条命令执行
OVERRIDES="--override-input router-container path:/root/router-container --override-input router-container/yunshu-nix path:/root/yunshu-nix"

do_build() {
  say "构建（用本地路径覆盖，不拉 GitHub）"
  # shellcheck disable=SC2086
  $SSH "cd $REMOTE && nixos-rebuild build --flake .#default $OVERRIDES > /tmp/vm-build.log 2>&1; \
        echo EXIT=\$?; tail -3 /tmp/vm-build.log" || die "构建命令失败"
}

# ── 部署：boot + 重启 ────────────────────────────────────────────────
do_deploy() {
  say "设为下次启动并重启"
  timeout 10 $SSH 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null > "$STATE"
  # shellcheck disable=SC2086
  $SSH "cd $REMOTE && nixos-rebuild boot --flake .#default $OVERRIDES 2>&1 | tail -2; \
        sleep 6; systemctl reboot" || true
  echo "  ✓ 已下发重启（重启前 boot_id: $(cut -c1-8 "$STATE" 2>/dev/null)）"
}

# ── 验证 ─────────────────────────────────────────────────────────────
do_verify() {
  say "等待重启"
  local old new n=0
  if [ -s "$STATE" ]; then
    # deploy 留下的基线，见 STATE 的注释。这时**不能**要求 VM 可达——
    # 刚下发重启，它本来就正在关机/开机，直接判"不可达"会误杀。
    old=$(cat "$STATE")
  else
    # 单独跑 verify（没有 deploy 的基线）：只能现读，读不到就是真不可达
    old=$(timeout 10 $SSH 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)
    vm_up || die "VM 当前不可达；用 virsh console $DOMAIN 看控制台"
  fi
  echo "  旧 boot_id: ${old:0:8}"
  while :; do
    n=$((n+1))
    [ $n -gt 60 ] && { echo "✗ 6 分钟没起来 → virsh console $DOMAIN"; return 1; }
    new=$(timeout 8 $SSH 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)
    [ -n "$new" ] && [ "$new" != "$old" ] && { echo "  ✓ 已重启（${new:0:8}，$(($n*6))s）"; break; }
    sleep 6
  done
  rm -f "$STATE"
  sleep 25

  local rc=0
  chk() { # chk <标题> <远程命令> <期望正则>
    local out; out=$(timeout 30 $SSH "$2" 2>&1)
    if echo "$out" | grep -qE "$3"; then printf '  ✓ %s\n' "$1"
    else printf '  ✗ %s\n%s\n' "$1" "$(echo "$out" | sed 's/^/      /' | head -6)"; rc=1; fi
  }

  say "验证"
  chk "宿主地址在 br-lan 上，且保命地址也在" 'ip -br addr show br-lan' '192\.168\.10\.2/24'
  chk "wan 口 up"  'cat /sys/class/net/wan/operstate' '^up$'
  chk "lan 口 up"  'cat /sys/class/net/lan/operstate' '^up$'
  chk "三个容器都在跑" 'systemctl list-units "container@*" --state=running --no-legend' 'container@main-router'
  chk "无重启循环（NRestarts=0）" 'systemctl show container@main-router -p NRestarts --value' '^0$'
  chk "★ main-router 里 lan 有地址" 'nixos-container run main-router -- ip -br addr show lan' '192\.168\.10\.1/24'
  chk "★ lan 的 MAC 已固定" 'nixos-container run main-router -- cat /sys/class/net/lan/address' '02:00:00:02:00:11'
  chk "main-router 到 Multi-User" 'journalctl -D /var/lib/nixos-containers/main-router/var/log/journal --no-pager -b 0 2>/dev/null | grep -c "Reached target Multi-User"' '^[1-9]'
  chk "★ tailscale 双宿主机（lan=.4）" 'nixos-container run tailscale -- ip -br addr show lan' '192\.168\.10\.4/24'

  say "完整链路"
  $SSH 'nixos-container run main-router -- sh -c "ip -br addr; echo; ip route show default" 2>&1 | head -10'
  echo
  [ $rc -eq 0 ] && echo "✓ 全部通过" || echo "✗ 有失败项 —— 看容器自己的 journal：journalctl -D /var/lib/nixos-containers/<名>/var/log/journal -b -1"
  return $rc
}

do_status() {
  say "VM 现状"
  $SSH 'echo "系统: $(readlink -f /run/current-system | sed "s|.*/||")"
        echo "世代:"; nix-env --profile /nix/var/nix/profiles/system --list-generations 2>/dev/null | tail -3
        echo "接口:"; ip -br addr | grep -vE "DOWN|UNKNOWN"
        echo "容器:"; systemctl list-units "container@*" --state=running --no-legend | awk "{print \$1}"' 2>&1
}

case "${1:-all}" in
  assemble) do_assemble ;;
  build)    do_assemble && do_build ;;
  deploy)   do_deploy ;;
  verify)   do_verify ;;
  status)   do_status ;;
  all)      do_assemble && do_build && do_deploy && do_verify ;;
  *)        die "用法: $0 [assemble|build|deploy|verify|status|all]" ;;
esac
