# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

> **⚠️ 本仓库正在改造中（2026-09-15 起），当前不可部署。**
>
> 目标：把现有的 `router-vm`（cloud-hypervisor MicroVM）+ `yunshu` 容器组合，改成
> **纯二层宿主机 + 一组 systemd-nspawn 网关容器**。设计见 [`docs/gateway.md`](docs/gateway.md)。
>
> **已完成的边界重划**：去掉 `router-image` flake input、删除 `modules/virtualization/`
> 与 `fix-net.py`、新增 `modules/gateway/`（空壳，待填）。
>
> **尚未替换的旧假设**（下方架构描述里这些部分暂时仍然有效，但都将在步骤 2/3 被推翻）：
> `modules/network/bridges.nix` 的 `br-lan`/`br-wan` 桥接、`modules/services/yunshu.nix`
> 指向 `192.168.10.1` 的 veth 网关、以及下面整节「路由 VM」。
> **改造完成前不要对 NAS 执行 `nixos-rebuild switch`。**

QNAP TS-564 NAS 的 NixOS 单机配置仓库，使用 Flakes 声明式管理。注意：仓库已从 `hosts/ts564/` 多机结构**扁平化为单设备结构**（见 commit 8111ae7）——主机配置直接放在仓库根目录，flake 只输出 `nixosConfigurations.default`。完整的从零安装流程见 `INSTALL.md`。

## 常用命令

```bash
nix flake update                                  # 更新全部 flake 依赖
nix flake check                                   # 验证配置求值

sudo nixos-rebuild switch --flake .#default       # 重建系统（flake 输出名为 default，不是 .#ts564）
sudo nixos-rebuild switch --rollback              # 回滚

sops secrets/secrets.yaml                         # 编辑加密密钥（需要 age 私钥）
```

**flake.lock 已提交并锁定依赖**（nixos-26.05）。升级依赖时运行 `nix flake update` 重新生成 lock 文件。

## 架构

### 入口与模块组织

- `flake.nix`：唯一入口。imports qnap8528 和 sops-nix 的 nixosModules，然后导入 `./configuration.nix` 和 `./modules/{system,hardware,network,gateway,services,security,users}`。通过 `specialArgs` 传入 `inputs`（所有 flake 输入，qnap8528 模块用它读 fancontrol 配置）。
- `modules/gateway/`：改造目标所在的容器组（目前只有占位 `default.nix`，逐步填入 main-router / side-router / dnsmasq / tailscale / headscale / cloudflared）。
- `configuration.nix`：主机级配置（hostname、stateVersion、boot loader、QNAP 硬件开关），imports `./hardware-configuration.nix` 和 `./filesystem.nix`。
- `modules/<分组>/default.nix` 是每个分组的聚合入口，只做 imports；具体配置在分组内的各个文件里。

### 网络拓扑（关键设计）

- **物理网口按 MAC 锚定命名为 `wan0` / `lan0`**（`modules/network/links.nix`）：内核给的 `enp2s0`/`enp3s0` 只对 PCI 位置稳定，而这两颗是同型号 Intel igc（I225/I226）网卡、分别挂 WAN 和 LAN，发现顺序一翻转就是内外网对调。
  - 对应关系：`wan0` = `24:5e:be:88:1e:79`（原 `enp2s0`，接上游）；`lan0` = `24:5e:be:88:1e:78`（原 `enp3s0`，接内网）。
  - 用 `MACAddress` 而非 `PermanentMACAddress` 匹配：这对网卡在当前内核上不暴露 `perm_address`。
  - ⚠️ 改名**必须重启才生效**（`.link` 由 udev 在设备出现时处理），且生效后旧名消失。
- 双网口各绑定一个桥：`wan0 → br-wan`、`lan0 → br-lan`（systemd-networkd 管理，`modules/network/bridges.nix`）。
- **宿主机在 br-wan 上不配置 IP**——WAN（DHCP/NAT/防火墙）完全由路由 VM 负责。宿主机只在 br-lan 上有静态 IP `192.168.10.2/24`，**网关与 DNS 都指向浮动网关 `192.168.10.254`**（yunshu 容器 VRRP MASTER 持有，容器不可用时路由 VM BACKUP 接管）。`192.168.10.1` 是路由 VM 自己的 LAN 地址，不是宿主机的网关。
- 防火墙只在 br-lan 接口开放服务端口（`modules/network/default.nix`），端口列表对应 SSH/Samba/NFS/Syncthing/WebDAV/Glance/Navidrome/Cockpit。

### ~~Alpine 路由 VM~~（已从本仓库移除）

> 本节描述的路由 VM 已随改造退役：`router-image` input 已删除、`modules/virtualization/`
> 已删除。下面的内容保留**仅供迁移期参考**（对照旧实现、理解要替换掉什么），
> 不要再照它修改本仓库。路由 VM 的实现仍在 `router-image` 仓库和 `qnap-nixos-nas` 仓库里。


- **路由 VM 的全部实现都在 router-image 仓库**（原 alpine-router-image，2026-08-28 GitHub 改名）：配置权威源（`base/` + `network.env`，CI 烙进镜像）+ microvm 消费端模块（`nixosModules.router`，含镜像 fetchurl/CH 声明/disk-prep/tap 挂桥）+ deploy 密钥注入资产（`deploy-assets/`，模块内打包为 `/etc/libvirt/alpine-router-deploy.tar.gz` 并提供 `alpine-router-deploy`/`alpine-router-shell` 命令）。VM 全声明式（cloud-hypervisor 后端），libvirtd/virt-install 方案已退役。本仓库零 VM 实现代码。**改配置**：router-image（base/network.env）→ CI（`router-build`，release tag `router-vm-YYYYMMDD`，自动同步模块内 tag+sha256）→ NAS `nix flake update` → rebuild → 重启 VM（disk-prep 重装状态）→ deploy 注入密钥；**改密钥**：编辑 `/etc/libvirt/alpine-router.env` → `alpine-router-deploy`。**软件包列表（package.list）上游权威在 nanopi-r3s-rootfs 仓库**，router-image 的副本已按 VM 场景分叉（alpine 链无 sing-box 段；gentoo 链独立清单）。
- `install.sh` 在 VM 内只执行密钥注入（lib/secrets.sh）：SSH 公钥 → `/root/.ssh/authorized_keys`、Tailscale authkey、Cloudflared token；结束（含失败）即删除 env 文件。
- 密钥经 env 文件注入：NAS 上 `/etc/libvirt/alpine-router.env`（模板 `env.example`，chmod 600）由 `alpine-router-deploy` scp 到 VM，install.sh 结束（含失败）即删除；密钥不进入部署包和 nix store。
- `alpine-router-deploy` 包装脚本：ping 检查 VM 在线 → scp tarball → scp 可选 env 密钥文件 → ssh 解包执行 install.sh。VM_IP 来自模块常量。
- 更新路由配置的完整流程：修改 router-image 的 `base/` → 触发 CI → NAS `nix flake update` + rebuild（详见上一段）。
- **MicroVM 方案**（POC 已转正，默认关闭）：消费端声明在 **router-image 仓库的 `nixosModules.router`**（本仓库通过 flake input 引用，`modules/virtualization/default.nix` imports；本地 router.nix 已删除）。模块内含镜像 fetchurl 三资产（tag+sha256 与 CI 同仓库锁定）、`alpine-router-disk` 状态盘服务（复制到 `/var/lib/alpine-router/rootfs.qcow2`，release 升级自动重装）、tap 自动挂桥 networkd、CH 声明（cpu 隔离/affinity/balloon/vsock cid 3）。启用：`microvm.router.enable = true`（参数见模块 options：os/cpu/vcpus/mem/initialBalloonMem/wanBridge/lanBridge/三资产覆盖；os=alpine|gentoo 双发行版，均为 musl+OpenRC）。deploy 是唯一密钥注入通道。
- MicroVM 后端为 **cloud-hypervisor**（更轻量）：VM 内选项挂 `microvm.*` 下（经 `microvm.vms.<name>.config` 模块传入，**不是**直接写在 vms.<name> 下）。CPU：`cpu`（默认 0）经 isolcpus/rcu_nocbs 隔离并由 vcpu0 affinity（`affinity=[0@[N]]`，CH v53 语法）pin 独占，其余 vCPU（`vcpus` 选项，默认 2）动态调度。内存：balloon（128M 对齐粒度，初始 256M + deflateOnOOM）。网络：CH 不支持 qemu 的 bridge 接口类型，用 tap 接口 + networkd（`50-router-wan/lan`）在 tap 出现时自动挂 br-wan/br-lan。内核包装要提供 dev 输出（CH runner 取 `${kernel.dev}/vmlinux`，内容实为 bzImage 自动识别）；volumes 必须显式 `imageType = "qcow2"`（CH 默认 raw）。

### YunShu 透明网关容器（浮动网关）——待改造为 `main-router`

> 下面描述的是**当前实现**（veth 挂 br-lan、指向路由 VM 的 `upstreamGateway`、与
> 路由 VM 组 VRRP）。改造后将变成 `modules/gateway/main-router.nix`：LAN/WAN 改走
> macvlan、直连物理 WAN 自己做 NAT、与 `side-router` 容器组 VRRP。
> 参数差异（浮动 IP `.254`→`.1`、vrid `10`→`51`、priority `150`→`100`）见 `docs/gateway.md`。


- **NixOS declarative container**（`modules/services/yunshu.nix`，flake input `yunshu-router`——公开仓库，github: URL 匿名拉取）：策略分流 VPN + 透明代理（gatewayMode：容器开 ip_forward/nftables 转发、YunShu 自带 TUN 路由，禁用独立 7890 代理）。veth 挂 br-lan，静态 `192.168.10.3`；直连流量默认路由 = 路由器 VM（`upstreamGateway`）。
- **浮动网关（VRRP/keepalived）**：内网设备 DHCP 网关 = 浮动 IP `192.168.10.254`（`network.env` 的 `LAN_GATEWAY`）。yunshu 容器为 MASTER（priority 150，持有 .254，策略分流）；Alpine VM 为 BACKUP（`base/keepalived/keepalived.conf`，priority 100，nopreempt——容器不可用时接管 .254，**降级为纯直连 NAT** 保连通）。VRRP 参数（vrid=10/auth_pass=alpine-float/floatIp）三处同步：`network.env` + VM `base/keepalived/` + yunshu-nix 的 container 模块 options。
- 系统 Web 管理通过 **Cockpit**（9090，`modules/services/cockpit.nix`），当前无插件（cockpit-machines 与 libvirtd 已随 VM 方案迁移退役——CH VM 不归 Cockpit 管）；可按需加 podman/files/zfs 等插件。

### 硬件与密钥

- QNAP 硬件支持来自 flake input `qnap8528`；风扇配置在**求值时**直接读取外部仓库：`builtins.readFile "${inputs.qnap8528}/examples/fancontrol.conf"`（`modules/hardware/fancontrol.nix`）——修改该仓库会影响本配置。
- sops-nix：age 私钥位于 `/var/lib/sops-nix/key.txt`，`defaultSopsFile` 指向 `secrets/secrets.yaml`（见 `modules/security/sops.nix`）。
- 磁盘按 label 挂载（`filesystem.nix`）：`nixos`/`boot`（系统盘）、`/srv/data`（**Btrfs 原生 RAID1**，无 mdadm，卷标 `data`，每月自动 scrub）、`/srv/cache`、`/srv/backup`。

## ⚠️ 当前状态与坑

1. **内网网段为 `192.168.10.0/24`，且在多个文件硬编码**：`bridges.nix`（宿主机 IP/网关）、`samba.nix`（hosts allow）、`nfs.nix`（exports）、`syncthing.nix`（guiAddress）、`webdav.nix`（绑定地址）、`glance.nix`（绑定地址）、`music.nix`（Navidrome/Feishin 绑定地址）、`microvm.router.vmIp` 选项（router-image 模块，deploy 脚本 ssh 目标）、**router-image 仓库的 `network.env`**（VM 网络参数权威源，含 TS_ADVERTISE_ROUTES 与 LAN_GATEWAY 浮动网关）、**yunshu 容器参数**（`modules/services/yunshu.nix` 的 lanAddress/upstreamGateway/floatIp）。修改网段时必须全局同步这些位置，否则服务绑定错 IP 或防火墙/共享拒绝访问。
2. `hardware-configuration.nix` 被 `.gitignore` 忽略（规则 `/hardware-configuration.nix`），但当前已通过 `git add -N -f` 以 intent-to-add 状态暂存——**内容仍是占位模板**（空 kernelModules），不能用于真实安装。安装时用 `nixos-generate-config --root /mnt` 生成真实配置**覆盖**它并保持 intent-to-add 状态；`hardware-configuration.nix.example` 是占位模板。**flake 求值只能看到 git 跟踪的文件**——未暂存时 `nixos-rebuild --flake` 报 "not tracked by Git"。
3. `secrets/secrets.yaml` 尚不存在。sops 模块引用了它但 `secrets` 集合为空；在 `modules/security/sops.nix` 中取消注释 secret 定义前，须先按 `secrets/README.md` 生成 age 密钥并创建加密文件。
4. `modules/users/nas-user.nix` 的 SSH 公钥是占位注释——无任何密钥则无法 SSH 登录（密码登录已禁用）。`wheelNeedsPassword = true`。
5. 数据盘为 Btrfs 原生 RAID1（无 mdadm）：`mkfs.btrfs -m raid1 -d raid1 -L data` 创建，挂载靠卷标，多设备由内核自动组装；`services.btrfs.autoScrub` 每月自动校验修复。
6. `modules/security/sops.nix` 中 `defaultSopsFile = ../../secrets/secrets.yaml` 是相对路径——移动该文件时必须同步改路径。
7. **Cockpit/nas 密码已配置**：`nas` 用户的 hash 已填在 `modules/users/nas-user.nix` 的 `hashedPassword`（安装即用，Cockpit/sudo/SSH 密码登录共用）。**⚠️ 仓库是公开的，hash 可被离线爆破——密码必须足够强且不复用；旧 hash 会永久留在 git 历史里**。改密码：`mkpasswd -m sha-512` 重新生成替换；需要加密管理时可用 sops-nix（`secrets/README.md`）。SSH 密码登录仅对内网与 Tailscale 网段放行（`ssh.nix` 的 Match Address 192.168.10.0/24,100.64.0.0/10），其他来源仅允许密钥。
8. 配置权威源已移至 **router-image 仓库**：`base/` 的 `__XXX__` 占位符由该仓库构建时（network.sh 按 network.env）替换；本仓库已无 postPatch。R3S 遗留已全部清除（LED/hw-tweak 硬件脚本、PROXY 死规则均已删）。

## 代码风格

- 模块文件是 NixOS module（`{ config, pkgs, lib, ... }: { ... }`），不是纯函数式 Nix 表达式。
- 注释使用中文；配置内嵌 shell 脚本（install.sh、部署脚本）通过 `pkgs.writeShellScript` / `writeShellScriptBin` 生成。
- 磁盘和服务路径约定：数据 `/srv/data`（Btrfs RAID1，不可再生数据）、缓存 `/srv/cache`（SSD，性能敏感/可重建状态）、备份 `/srv/backup`；服务运行用户为 `nas`（在 `users/` 模块中定义），tmpfiles 规则负责建目录。
