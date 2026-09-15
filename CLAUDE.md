# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

QNAP TS-564 的 NixOS 一体化网关宿主：**纯二层宿主机 + 一组 systemd-nspawn 网关容器**。
主机配置直接在仓库根目录，flake 只输出 `nixosConfigurations.default`。设计取舍与验收依据见
[`docs/gateway.md`](docs/gateway.md)（含实测的性能/资源对比与编址迁移清单）。

> **⚠️ 本配置尚未在任何机器上部署过。** 从 `qnap-nixos-nas` 复制而来并完成了架构改造，
> 但迁移（编址、接口改名、从 MicroVM 切换）尚未在真机执行，也**没做过任何真机验证**。
> 首次部署前务必先读 `docs/gateway.md` 附录 A 与 §7.4（失败域）。

## 常用命令

```bash
nix flake update                                  # 更新全部 flake 依赖（含 yunshu-container）
nix flake check                                   # 验证配置求值

# 求值验证（改完务必跑，逐叶子 eval 会漏掉整系统才暴露的错误）
nix eval --raw .#nixosConfigurations.default.config.system.build.toplevel.drvPath
nix eval --raw .#nixosConfigurations.default.config.containers.main-router.config.system.build.toplevel.drvPath

sudo nixos-rebuild switch --flake .#default       # 重建系统（输出名是 default）
sudo nixos-rebuild switch --rollback

sops secrets/secrets.yaml                         # 编辑加密密钥（需要 age 私钥）
```

**flake.lock 已提交并锁定依赖**（nixos-26.05）。CI（`.github/workflows/`）在每次 push 跑
`nix flake check` + 宿主机 dry-run build。

## 架构

### 入口与模块组织

- `flake.nix`：唯一入口。inputs = nixpkgs / qnap8528 / qnap-kernel / sops-nix / yunshu-container。
  导入 `./configuration.nix` 与 `./modules/{system,hardware,network,gateway,services,security,users}`。
- `modules/gateway/`：**网关容器组**，一个文件一个容器（见下）。这是本仓库与旧仓库最大的差异。
- `modules/network/`：`links.nix`（物理口按 MAC 命名）+ `shim.nix`（宿主机 macvlan shim）。
  **没有 bridge** —— 宿主机纯二层，不做转发。
- `modules/<分组>/default.nix` 是聚合入口，只做 imports。

### 网络拓扑（关键设计）

**物理口按 MAC 锚定命名**（`modules/network/links.nix`）：两颗同型号 Intel igc（I225/I226）
网卡分别挂 WAN 和 LAN，内核给的 `enpXsY` 只对 PCI 位置稳定，发现顺序一翻转就是内外网对调。

| 名字 | MAC | 位置 | 给谁 |
|---|---|---|---|
| `wan0` | `24:5e:be:88:1e:79` | 原 `enp2s0` | main-router / side-router 的 WAN 侧 macvlan |
| `lan0` | `24:5e:be:88:1e:78` | 原 `enp3s0` | 所有容器的 LAN 侧 macvlan + 宿主机 shim |

- 用 `MACAddress` 而非 `PermanentMACAddress` 匹配：这对网卡在当前内核上不暴露 `perm_address`。
- ⚠️ 改名**必须重启才生效**（`.link` 由 udev 在设备出现时处理），生效后旧名消失。
- ⚠️ 防火墙按**接口名**匹配：宿主机地址从 `br-lan` 挪到 `mv-shim` 时 `modules/network/default.nix`
  那张端口表必须同时改。漏改不报错，只会让 Samba/NFS/Syncthing 静默被挡在门外。

**宿主机只保留一个 macvlan shim**（`mv-shim` on `lan0`，`mode=bridge`，`192.168.10.250/24`）。
"宿主机纯二层"的准确含义是**不做转发**，不是"没有三层"——它必须有地址、默认路由和 DNS，
否则 flake update / sops 解密 / NTP 对时全都做不了。默认路由与 DNS 都指向浮动网关 `.1`。

**编址**（详见 `docs/gateway.md` §3）：

| 角色 | 地址 | 说明 |
|---|---|---|
| 浮动网关 VIP | `192.168.10.1` | 下游设备的默认网关与 DNS，随 VRRP 漂移 |
| main-router | `.2` | VRRP MASTER |
| side-router | `.3` | VRRP BACKUP |
| tailscale | `.4` | 两个 tailscale 实例 |
| cloudflared | `.6` | 隧道 |
| dnsmasq | `.7` | DHCP + 降级态 DNS |
| 宿主机 | `.250` | macvlan shim |

### 网关容器组（`modules/gateway/`）

| 文件 | 容器 | 接法 | 要点 |
|---|---|---|---|
| `main-router.nix` | main-router | `lan0:eth0` + `wan0:eth1` | 由 `yunshu-container` 的 container 模块构建；VRRP MASTER（priority 100），YunShu 策略分流 |
| `side-router.nix` | side-router | `lan0:eth0` + `wan0:eth1` | 普通 NixOS 容器；VRRP BACKUP（priority 90，`noPreempt`），降级直连 NAT，兼降级态 DNS 转发 |
| `dnsmasq.nix` | dnsmasq | `lan0:eth0` | 全网唯一 DHCP；**option 3/6 都下发 VIP** |
| `tailscale.nix` | tailscale | `lan0:eth0` | 官方实例走 `services.tailscale`，headscale 实例手写单元（NixOS 不支持多实例） |
| `cloudflared.nix` | cloudflared | `lan0:eth0` | token 模式，`services.cloudflared` 不支持所以手写 |

**几条容易改错、且改了不会立刻报错的地方：**

- **VRRP 参数必须两边一致**：`vrid=51` / `auth_pass=aio-vrrp`（≤8 字节，VRRPv2 认证字段限制）/
  VIP `.1` / 单播互指。改完用一次 eval 交叉验证，别靠肉眼比对两个文件。
- **macvlan 的容器内接口名必须显式指定**：写 `macvlans = [ "lan0:eth0" ]`，冒号后半段不能省。
  省了 nspawn 会命名成 `mv-lan0`，与 keepalived/DNS 里的 `eth0` 对不上且**不报错**
  （yunshu-container 里有断言挡这个）。
- **MAC 必须逐个固定**（`02:00:00:02:00:XX`，按容器编号排）。nspawn 每次重建都随机生成，
  漂了的后果是 DHCP 租约变化、上游按 MAC 绑定失效、VRRP 对端认成本新设备。
  容器内用 `systemd.network.links`（**不是** `.network`——那个只有 networkd 会读，容器不开 networkd），
  文件名前缀 `10-` 是为了排在 NixOS 自动生成的 `40-<接口名>` 之前（udev 只应用最靠前的那个）。
- **DNS 链路不要"顺手优化"**：客户端 DNS 由 DHCP 下发为 VIP → main 持 VIP 时由 YunShu 隧道 DNS
  做分流，漂到 side 时由 side 把 53 转发给 dnsmasq。一旦把客户端 DNS 改成某个容器的固定地址，
  fake-IP 不再触发，域名级分流直接失效（AdGuard 方案就是因此被废弃的）。
- **side-router 的 WAN 健康检查权重是 `-100`**：keepalived 在"优先级+权重 < 1"时进 FAULT，
  这样 WAN 不通时它**永远不会**接管 VIP。只降一点权重的话，它会带着一个上不了网的网关接管。

### 宿主机服务与密钥

- `modules/services/`：Samba / NFS / Syncthing / WebDAV / Glance / Navidrome+Feishin / Beszel /
  OpenList / 下载（qBittorrent+aria2）/ 备份。**Cockpit 已删除**（含 9090 放行），Web 管理走 Glance。
- sops-nix：age 私钥 `/var/lib/sops-nix/key.txt`，`defaultSopsFile` = `secrets/secrets.yaml`。
- **网关容器的密钥注入**：宿主 sops 解密 → nspawn `--load-credential` → 容器内
  `/run/credentials/@system/<id>`（内存，不留副本）。三个密钥都带 `restartUnits`——
  激活脚本重写 `/run/secrets` 后容器**不重启就还用旧凭据**。
- QNAP 硬件支持来自 flake input `qnap8528`；风扇配置在求值时读该仓库的
  `examples/fancontrol.conf`（改那个仓库会影响本配置）。
- 磁盘按 label 挂载（`filesystem.nix`）：`nixos`/`boot`、`/srv/data`（**Btrfs 原生 RAID1**，
  每月自动 scrub）、`/srv/cache`、`/srv/backup`。**注意没有 `/persist`**——容器状态一律放
  `/srv/data/<服务>`。

### 与 `yunshu-container` 仓库的关系

main-router 由独立的 `yunshu-container` 仓库（公开，`github:allenmagic/yunshu-container`）提供，
它只做一件事：**macvlan 接入的 YunShu 透明网关容器**。它已独立维护、不跟随上游 `yunshu-nix`。

**改它的纪律**：输入是 `github:`，所以改动**必须 commit 且 push**，否则本仓库求值拉到的仍是
GitHub 上的旧版本——而报错常常是"option 不存在"这种指向不明的形式，容易查错方向。

## ⚠️ 当前状态与坑

1. **内网网段 `192.168.10.0/24` 硬编码在十几处**：宿主机侧（`shim.nix` 的 IP/网关、
   各服务的绑定地址、`glance.nix` 的面板链接）、`modules/gateway/*` 的容器地址与 DHCP 选项、
   以及 `yunshu-container` 里的默认值。改网段必须全局同步。
2. `hardware-configuration.nix` 被 `.gitignore` 忽略但**已强制入库**（占位模板，非真实硬件信息）。
   真机安装时用 `nixos-generate-config --root /mnt` 覆盖它。**flake 只认 git 跟踪的文件**——
   新增文件要先 `git add -N`，否则求值报 "not tracked by Git"。
3. `nas` 密码 hash 在 `modules/users/nas-user.nix`（`wheelNeedsPassword = true`，SSH 密码登录仅
   对内网与 Tailscale 网段放行）。**本仓库是私有的**，但 hash 仍属敏感——密码要强且不复用。
4. 数据盘为 Btrfs 原生 RAID1（无 mdadm）：`mkfs.btrfs -m raid1 -d raid1 -L data`，挂载靠卷标，
   多设备由内核自动组装。
5. `modules/security/sops.nix` 的 `defaultSopsFile` 是相对路径——移动该文件时同步改。
6. **改造遗留的未验证项**（真机首次部署前必须逐条验证，详见 `docs/gateway.md` §17）：
   macvlan 接口的 MAC 能否靠容器内 udev `.link` 固定、两个容器的单播 VRRP 是否真能互通、
   dnsmasq 能否收到广播 DHCP 请求、WAN 侧上游是否接受第二个 DHCP 客户端。

## 代码风格

- 模块文件是 NixOS module（`{ config, pkgs, lib, ... }: { ... }`），不是纯函数式 Nix 表达式。
- 注释使用中文，**写在"为什么"上**：踩过的坑、反直觉的取值、改了会静默出错的地方。
  那些恰恰是下次最容易被人"顺手优化"掉的。
- 磁盘和服务路径约定：`/srv/data`（不可再生数据）、`/srv/cache`（可重建状态）、`/srv/backup`；
  服务用户为 `nas`，tmpfiles 规则负责建目录。
