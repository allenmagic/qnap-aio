# VirtualBox 全新安装测试指南

在 VirtualBox 中验证 INSTALL.md 的安装流程（不依赖 QNAP 真实硬件）。
可验证：`nixos-install` 成功、重启进系统、RAID 组装、宿主机服务、**以及大部分网关容器行为**。

## ⚠️ 先读这条：网卡 MAC 必须设成生产值

接口名是**按 MAC 锚定**的（`modules/network/links.nix`），不是按 PCI 位置。VM 里网卡的
默认 MAC 与生产机不同，`wan0`/`lan0` 就**永远不会被创建** —— 后果是宿主机没有任何网络、
五个网关容器全部起不来。

所以 VM 的两块网卡必须手工把 MAC 改成生产值（VirtualBox：设置 → 网络 → 高级 → MAC 地址）：

| VM 网卡 | 设为 | 附着方式 | 对应 |
|---|---|---|---|
| 网卡 1 | `24:5E:BE:88:1E:79` | NAT | `wan0`（WAN 侧） |
| 网卡 2 | `24:5E:BE:88:1E:78` | 内部网络 `intnet`（或仅主机） | `lan0`（LAN 侧） |

> 这两条 MAC 只用于让配置里的 `.link` 规则命中。VM 里它们不代表真实硬件。

## 与真实 QNAP 的差异

| 项目 | VM 里的情况 | 处理 |
|---|---|---|
| qnap8528 / fancontrol | 无 QNAP EC 硬件 | **预期报错**，不影响安装与其他功能 |
| 内核 | `hardware-configuration.nix` 生成的是 VM 的配置 | 安装时覆盖为生成的版本（见 3.2） |
| WAN 侧 | VirtualBox NAT 会正常发 DHCP 租约 | main-router 与 side-router 会各拿一个 |
| LAN 侧客户端 | 用第二台 VM 或宿主机接 `intnet` | 需手动指定 `192.168.10.100/24` 验证 |
| WAN 冗余测试 | 无法测"上游只允许单 DHCP 客户端" | 真机才能确认 |
| 磁盘 | 容量随意，**卷标必须照做** | RAID1 可正常测试 |

## 0. 准备

- 下载 [NixOS minimal ISO](https://nixos.org/download/)（x86_64）
- 新建 VM：Linux 64-bit、**开启 EFI**、4 CPU、4GB 内存
- 虚拟盘：`20G`（系统）+ `4G`×2（RAID1）+ `2G`（缓存）+ `2G`（备份）
- **两块网卡，MAC 按上表设置**
- 挂 ISO 启动

## 1. 进入安装环境

```bash
ip a && ping -c 3 8.8.8.8   # 自动登录 nixos 用户
sudo -i
lsblk                        # 确认磁盘名（一般 sda/sdb/sdc/sdd/sde）
```

> 此时网卡还是 `enp0s3`/`enp0s8`（安装环境不读本仓库的 `.link` 规则），
> 装完首次重启后才会变成 `wan0`/`lan0`。

## 2. 磁盘分区与 RAID

```bash
# 2.1 系统盘
parted /dev/sda -- mklabel gpt
parted /dev/sda -- mkpart ESP fat32 1MiB 512MiB
parted /dev/sda -- set 1 esp on
parted /dev/sda -- mkpart primary ext4 512MiB 100%
mkfs.fat -F 32 -n boot /dev/sda1
mkfs.ext4 -L nixos /dev/sda2

# 2.2 数据盘 Btrfs 原生 RAID1（不需要 mdadm）
mkfs.btrfs -m raid1 -d raid1 -L data /dev/sdb /dev/sdc

# 2.3 缓存/备份盘
mkfs.ext4 -L cache /dev/sdd
mkfs.ext4 -L backup /dev/sde
```

## 3. 挂载 + 克隆仓库

```bash
# 3.1 挂载并生成硬件配置
mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount /dev/disk/by-label/boot /mnt/boot
nixos-generate-config --root /mnt

# 3.2 克隆仓库（私有仓库，需要凭证）
# ⚠️ 必须先把生成的配置移出/删除，否则目录非空会导致 git clone 失败
cd /mnt/etc/nixos
mv hardware-configuration.nix /tmp/hardware-configuration.nix
rm configuration.nix
git clone git@github.com:allenmagic/qnap-aio.git .
mv /tmp/hardware-configuration.nix .
git add -N -f hardware-configuration.nix   # flake 只能读 git 跟踪的文件

# 3.3 可选改动
# a) modules/users/nas-user.nix：填 SSH 公钥（不填只能控制台 root 登录）
# b) ⚠️ VM 特有必删：生成的 hardware-configuration.nix 检测到 VirtualBox 会自动加
#    virtualisation.virtualbox.guest.enable = true;，要求为当前内核编译 Guest
#    Additions 模块，编译失败会拖垮整个 linux-modules 闭包导致安装失败：
sed -i '/virtualbox.guest/d' hardware-configuration.nix
```

## 4. 安装

```bash
nixos-install --flake /mnt/etc/nixos#default \
  --option substituters "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store https://cache.nixos.org/"
# 提示设置 root 密码 → 设置并记住
reboot   # 重启前移除 ISO / 调整启动顺序
```

## 5. 重启验证

```bash
# 接口名已切换（这是整份配置能否工作的前提）
ip -br link            # 应有 wan0 / lan0 / mv-shim

# 宿主机地址与路由
ip -br addr show mv-shim      # 192.168.10.250/24
ip route                      # 默认路由 → 192.168.10.1

# 五个容器
systemctl list-units 'container@*'
journalctl -u container@main-router -b | tail -30

# 浮动网关
sudo nixos-container run main-router -- ip -br addr show eth0   # .2 + .1

# 磁盘
btrfs filesystem show          # 两块成员盘
btrfs device stats /srv/data   # 错误计数应为 0
```

**验收要点**（与 INSTALL.md 第 8 节同一份清单，VM 里能测的部分）：

- [ ] 接口名是 `wan0`/`lan0`，`mv-shim` 拿到了 `192.168.10.250/24`
- [ ] 五个容器全部 running
- [ ] `.1` 在 main-router 的 eth0 上；`systemctl stop container@main-router` 后漂到 side-router
- [ ] dnsmasq 拿到租约（`nixos-container run dnsmasq -- cat /var/lib/dnsmasq/dnsmasq.leases`）
- [ ] 第二台 VM 接 `intnet`，DHCP 拿到的网关与 DNS 都是 `192.168.10.1`
- [ ] Tailscale/Cloudflared 容器的密钥已注入（`nixos-container run tailscale -- ls /run/credentials/@system/`）

> 真机才能验证的项：WAN 侧上游是否接受两个 DHCP 客户端、macvlan 下 MAC 固定是否真的生效、
> 分流在真实网络下的表现。见 INSTALL.md 第 7 节的清单。

## 常见问题

| 现象 | 原因与处理 |
|---|---|
| `wan0`/`lan0` 没出现，宿主机完全没网 | VM 网卡 MAC 没设成生产值（见开头）——这是最常见的原因 |
| `could not find a flake.nix file` | 3.2 的 clone 因目录非空失败；或用了相对路径。用绝对路径 `/mnt/etc/nixos#default` |
| `echo >> /etc/nix/nix.conf` 报 Read-only file system | ISO 上该文件是指向只读 store 的符号链接；用 `--option` 或 `~/.config/nix/nix.conf` |
| flake 报 not tracked by Git | 未 `git add -N -f hardware-configuration.nix` |
| 容器起不来 | `journalctl -u container@<名字> -b`；多为 bindMount 源目录不存在或接口名对不上 |
| 重启后数据卷未挂载 | `btrfs device scan && mount /srv/data`；确认卷标与 filesystem.nix 一致 |
| qnap8528 模块加载失败 | VM 无 QNAP EC 硬件，预期现象 |
| `VirtualBox-GuestAdditions` 构建失败 | 生成的 hardware-configuration.nix 带 `virtualisation.virtualbox.guest.enable = true;`，删掉再装 |
