# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

QNAP TS-564 的 NixOS 一体化网关宿主：**纯二层宿主机 + 一组 systemd-nspawn 网关容器**。
主机配置直接在仓库根目录，flake 只输出 `nixosConfigurations.default`。设计取舍与验收依据见
[`docs/gateway.md`](docs/gateway.md)（含实测的性能/资源对比与编址迁移清单）。

> **⚠️ 2026-09-17/18：收敛为单网关容器。** side-router/VRRP 与 dnsmasq 容器均已删除，
> main-router 一人做网关 + DHCP + DNS，静态持 `.1`；DNS 是本机 dnsmasq（上游
> `strict-order`：隧道 DNS → 公网 DNS），不再用跨容器 DNAT（实测不通）。
> tailscale / cloudflared 保持独立容器。
>
> **`docs/gateway.md` 里 §7（VRRP/浮动网关）、§7.3/§7.4、附录 A 的编址部分已过时**，
> 只作历史参考，尚未重写。

## 常用命令

```bash
nix flake update                                  # 更新全部 flake 依赖（含 router-container）
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

- `flake.nix`：唯一入口。inputs = nixpkgs / qnap8528 / qnap-kernel / sops-nix / router-container。
  导入 `./configuration.nix` 与 `./modules/{system,hardware,network,gateway,services,security,users}`。
- `modules/gateway/`：**网关容器组**，一个文件一个容器（见下）。这是本仓库与旧仓库最大的差异。
- `modules/network/`：只有 `links.nix`（物理口按 MAC 命名）。宿主机的桥、地址、默认路由
  由 `router-container` 的 `bridge.nix` 声明。
- `modules/<分组>/default.nix` 是聚合入口，只做 imports。

### 网络拓扑（关键设计）

**物理口按 MAC 锚定命名**（`modules/network/links.nix`）：两颗同型号 Intel igc（I225/I226）
网卡分别挂 WAN 和 LAN，内核给的 `enpXsY` 只对 PCI 位置稳定，发现顺序一翻转就是内外网对调。

| 名字 | MAC | 位置 | 给谁 |
|---|---|---|---|
| `wan` | `24:5e:be:88:1e:79` | 原 `enp2s0` | main-router 的 WAN 侧 macvlan 父口 |
| `lan` | `24:5e:be:88:1e:78` | 原 `enp3s0` | **`br-lan` 的物理端口**（宿主地址也在桥上） |

- 用 `MACAddress` 而非 `PermanentMACAddress` 匹配：这对网卡在当前内核上不暴露 `perm_address`。
- ⚠️ 改名**必须重启才生效**（`.link` 由 udev 在设备出现时处理），生效后旧名消失。
- ⚠️ 防火墙按**接口名**匹配：宿主机地址在 `br-lan` 上，`modules/network/default.nix`
  那张端口表必须用同一个名字。漏改不报错，只会让 Samba/NFS/Syncthing 静默被挡在门外。

**LAN 走 bridge，宿主地址在 `br-lan`（`.2`）**，物理口 `lan` 只做二层端口。
这样宿主机**看得见容器间流量**（`tcpdump -i br-lan`）——macvlan 下看不见，
是上一轮排障最大的障碍。容器内的 LAN 口是 nspawn 的 veth，固定叫 `host0`。

WAN 侧仍是 macvlan：nspawn 的 `--network-bridge` 只作用于 `--network-veth` 那一个接口，
容器只能有一个桥接口。macvlan 侧的 DHCP 实测一直正常。

"宿主机纯二层"的准确含义是**不做三层转发**，不是"没有地址"——它必须有地址、默认路由和
DNS，否则 flake update / sops 解密 / NTP 对时全都做不了。默认路由与 DNS 都指向网关 `.1`。

**编址**（详见 `docs/gateway.md` §3）：

| 角色 | 地址 | 说明 |
|---|---|---|
| 网关 | `192.168.10.1` | main-router 的 LAN 地址；下游设备的默认网关与 DNS |
| 宿主机 | `.2` | `br-lan`（与旧系统同址，SSH/脚本不用改） |
| tailscale | `.4` | 两个 tailscale 实例 |
| cloudflared | `.6` | 隧道 |

> `.3` 已释放：原 side-router 已删除，网关不再做 VRRP 漂移。

### 网关容器组（`modules/gateway/`）

| 文件 | 容器 | 接法 | 要点 |
|---|---|---|---|
| `main-router.nix` | main-router | `br-lan`(veth `host0`) + `wan`(macvlan `eth1`) | 由 **`router-container`** 构建；唯一网关 |
| `tailscale.nix` | tailscale | `br-lan`(`host0`) | 官方实例走 `services.tailscale`，headscale 实例手写单元（NixOS 不支持多实例） |
| `cloudflared.nix` | cloudflared | `br-lan`(`host0`) | token 模式，`services.cloudflared` 不支持所以手写 |

`main-router` 的全部配置就是十几个 `router.*` 选项 + **一行 VPN**：
`router.vpn = inputs.router-container.vpns.yunshu`。路由器本体不认识 YunShu，
VPN 通过契约（`transit.{interface,fakeIpCidrs,dnsUpstream}` + `guestModules`）接入，
换实现只改这一行。

**几条容易改错、且改了不会立刻报错的地方：**

- **网关地址只在 `router.address` 写一次**：`router-container` 据此设置 LAN 接口地址，
  并让本机解析器监听它。别在容器 config 里再写一份
  `networking.interfaces.*.ipv4.addresses`——两处不一致时 DNS 会静默失效。
- **容器内 LAN 口叫 `host0`，不是 `eth0`**：nspawn 的 `--network-veth` 固定给这个名字。
  不要试图改名——macvlan 时代那套 udev `.link` 改名静默失效过一次，不值得再赌。
- **网关容器的 MAC 必须固定**（`router.macAddresses`，`02:00:00:02:00:XX`）。nspawn 每次
  重建都随机生成，漂了的后果是上游 DHCP 租约变化、按 MAC 绑定失效。用 oneshot 直接
  `ip link set`，不用容器内 udev `.link`（对这类接口静默无效）。
- **DNS 链路不要"顺手优化"**：客户端 DNS 由 DHCP 下发为网关 `.1`，main-router 再按 tun0
  有无决定上游用「YunShu 隧道 DNS」还是公网 DNS。一旦把客户端 DNS 改成别的地址
  （绕开网关），fake-IP 不再触发，域名级分流直接失效（AdGuard 方案就是因此被废弃的）。
- **DNS 由网关本机解析器提供，不要改回跨容器 DNAT**：`router-container/modules/guest/dns.nix`
  在网关地址上起 dnsmasq，上游 `strict-order` 排成「隧道 DNS → 公网 DNS」。真机实测过
  跨容器 DNAT 根本不通（指向别的容器或公网地址一律超时），而且目标不可达时客户端 DNS
  会整个断掉而不是降级。本地监听器永远在场，选错上游最多是慢。
- **tailscale / cloudflared 靠 resolv.conf 保持直连**：它们的默认网关是 `.1`，但
  `/etc/resolv.conf` 写死公网 DNS，拿不到 fake-IP 就不会被 YunShu 分流。改它们的
  resolv.conf 等于把它们塞进隧道。

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

### 与 `router-container` / `yunshu-nix` 的关系

`main-router` 由独立的 **`router-container`** 仓库提供
（公开，`git+https://github.com/allenmagic/router-container`——不要用 `github:` 简写，
它走 tarball 下载，国内会被截断）：**声明式路由器容器**，只管桥/容器/NAT/DHCP/DNS，
VPN 以契约接入。

VPN 实现来自 **`yunshu-nix`**：`router-container` 的 flake 输出
`vpns.yunshu` 把它包成 `{ transit; guestModules; }` 描述符。`yunshu-nix` 同时服务
旧系统（`qnap-nixos-nas`），所以**不要为了本仓库去改它的容器/模式部分**——本仓库只用
它的 `yunshu-headless` 模块。

**改它们的纪律**：输入是远程 git，改动**必须 commit 且 push**，否则本仓库求值拉到的仍是
GitHub 上的旧版本——而报错常常是"option 不存在"这种指向不明的形式，容易查错方向。

## ⚠️ 当前状态与坑

1. **内网网段 `192.168.10.0/24` 硬编码在十几处**：`main-router.nix` 的地址与 DHCP 选项、
   各服务的绑定地址、`glance.nix` 的面板链接、`router-container` 的示例值。改网段必须全局同步。
2. `hardware-configuration.nix` 被 `.gitignore` 忽略但**已强制入库**（占位模板，非真实硬件信息）。
   真机安装时用 `nixos-generate-config --root /mnt` 覆盖它。**flake 只认 git 跟踪的文件**——
   新增文件要先 `git add -N`，否则求值报 "not tracked by Git"。
3. `nas` 密码 hash 在 `modules/users/nas-user.nix`（`wheelNeedsPassword = true`，SSH 密码登录仅
   对内网与 Tailscale 网段放行）。**本仓库是私有的**，但 hash 仍属敏感——密码要强且不复用。
4. 数据盘为 Btrfs 原生 RAID1（无 mdadm）：`mkfs.btrfs -m raid1 -d raid1 -L data`，挂载靠卷标，
   多设备由内核自动组装。
5. `modules/security/sops.nix` 的 `defaultSopsFile` 是相对路径——移动该文件时同步改。
6. **真机已实测确认的项**（2026-09-18）：WAN 侧上游接受多个 DHCP 客户端、
   **YunShu 登录后 fake-IP 分流确实生效**（google 拿到 198.19.0.0，curl 返回 200）。
   **未验证**：① 隧道断开时 `strict-order` 回落到公网 DNS 是否如预期（要主动停掉
   yunshu-daemon 才能测）；② **bridge 改造后的真机表现**（桥可见性、跨容器通信）。
   **README / INSTALL / TESTING 三份文档尚未跟上最近的几次改造**，以本文与代码为准。

## 代码风格

- 模块文件是 NixOS module（`{ config, pkgs, lib, ... }: { ... }`），不是纯函数式 Nix 表达式。
- 注释使用中文，**写在"为什么"上**：踩过的坑、反直觉的取值、改了会静默出错的地方。
  那些恰恰是下次最容易被人"顺手优化"掉的。
- 磁盘和服务路径约定：`/srv/data`（不可再生数据）、`/srv/cache`（可重建状态）、`/srv/backup`；
  服务用户为 `nas`，tmpfiles 规则负责建目录。
