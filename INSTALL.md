# 从零安装指南

从一台全新的 QNAP TS-564 裸机开始，到运行着完整 NAS 服务 + Alpine 路由 VM 的 NixOS 系统。

## 0. 准备清单

**硬件**

- QNAP TS-564（含全部 5 块硬盘）
- U 盘（≥ 4GB，制作启动盘）
- 笔记本一台（后续通过 SSH 操作）
- 网线 2 根
- 显示器 + USB 键盘（可选，备用控制台）

**软件（提前下载）**

- [NixOS minimal ISO](https://nixos.org/download/)（x86_64）
- [Alpine virt ISO 3.24.1](https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/alpine-virt-3.24.1-x86_64.iso)（拷到 NAS 的 `/srv/data` 或临时目录备用）

**信息准备**

- 你的 SSH 公钥（写入 `modules/users/nas-user.nix`）
- 规划好的密码：root 密码（仅控制台）、nas 系统密码（Cockpit 用）、Samba 密码

**网络规划**

```
上行（现有路由器 LAN 口）
  │
  │ eno1（QNAP 网口1，无宿主机 IP）
  ▼
br-wan ── Alpine VM eth0 (DHCP)
              │ NAT/防火墙
           Alpine VM eth1: 192.168.10.1
  │
br-lan（eno2，QNAP 网口2）
  ├── NAS 宿主机 192.168.10.2
  └── 内网设备 192.168.10.100-200（VM 提供 DHCP）
```

## 1. 制作启动盘并进入安装环境

```bash
# 在笔记本上制作启动盘（假设 U 盘为 /dev/sdb，请确认设备名！）
sudo dd if=nixos-minimal-xxx-x86_64.iso of=/dev/sdb bs=4M status=progress && sync
```

1. 插入**全部 5 块硬盘**和 U 盘，QNAP 开机进 BIOS/引导菜单，从 U 盘启动
2. **网线：eno1 接到现有路由器 LAN 口**（安装阶段需要 DHCP 上网下载包）
3. 进入 ISO 后确认网络：

```bash
ip a          # 确认有接口拿到了 DHCP 地址
ping -c 3 8.8.8.8
```

> 备注：ISO 环境下网口都是自动 DHCP 的，装完系统后才会按配置变成 br-wan/br-lan。

## 2. 磁盘分区与 RAID 创建

> 本节及之后所有命令都需要 root 权限：进入安装环境后先执行 `sudo -i`（ISO 的 `nixos` 用户免密 sudo），之后的命令无需再加 sudo。

**可选：使用代理加速 GitHub（国内网络）**。Nix 无代理配置项，走标准环境变量（libcurl）。代理地址按实际改（VirtualBox NAT 下宿主机是 `10.0.2.2`；真机为内网代理 IP）：

```bash
export http_proxy=http://10.0.2.2:7890
export https_proxy=http://10.0.2.2:7890
export no_proxy=localhost,127.0.0.1,192.168.0.0/16,mirrors.tuna.tsinghua.edu.cn
curl -I https://github.com    # 验证代理可用后继续
# 若下载仍不走代理（部分下载由 nix-daemon 完成）：
#   systemctl set-environment http_proxy=$http_proxy https_proxy=$https_proxy no_proxy=$no_proxy
#   systemctl restart nix-daemon
```

先用 `lsblk` 确认磁盘名（本文假设：`/dev/sda`=256GB 系统盘、`/dev/sdb` `/dev/sdc`=3TB×2、`/dev/sdd`=1TB 缓存、`/dev/sde`=2TB 备份）。

### 2.1 系统盘分区（GPT + EFI + root）

```bash
parted /dev/sda -- mklabel gpt
# ESP 用 1GiB：NixOS 的 systemd-boot 会把每个 generation 的内核+initrd 都放这里，
# 默认保留 10 个 generation，512MiB 偏紧，1GiB 留足余量
parted /dev/sda -- mkpart ESP fat32 1MiB 1GiB
parted /dev/sda -- set 1 esp on
parted /dev/sda -- mkpart primary ext4 1GiB 100%

mkfs.fat -F 32 -n boot /dev/sda1
mkfs.ext4 -L nixos /dev/sda2
```

### 2.2 数据盘 Btrfs 原生 RAID1

```bash
# 用 by-id 更稳妥（ls /dev/disk/by-id/ 确认）
# Btrfs 内建 RAID1（-m raid1 -d raid1），不需要 mdadm；
# 数据带 checksum，配合每月自动 scrub 可检测并修复静默损坏
mkfs.btrfs -m raid1 -d raid1 -L data \
  /dev/disk/by-id/ata-WDC_WD30EFRX-xxx \
  /dev/disk/by-id/ata-WDC_WD30EFRX-yyy
```

无需记录任何 UUID——Btrfs 卷按卷标挂载，多设备成员由内核自动发现组装。

### 2.3 缓存盘与备份盘

```bash
mkfs.ext4 -L cache /dev/sdd
mkfs.ext4 -L backup /dev/sde
```

## 3. 安装 NixOS

### 3.1 挂载并生成硬件配置

```bash
mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount /dev/disk/by-label/boot /mnt/boot

nixos-generate-config --root /mnt
```

### 3.2 克隆本仓库并放置硬件配置

```bash
cd /mnt/etc/nixos
# nixos-generate-config 已在此生成 configuration.nix + hardware-configuration.nix，
# 目录非空会导致 git clone 失败——先把生成的真硬件配置移出去、删掉生成版配置
mv hardware-configuration.nix /tmp/hardware-configuration.nix
rm configuration.nix

git clone https://github.com/allenmagic/qnap-nixos-nas.git .
mv /tmp/hardware-configuration.nix .

# 关键：flake 只能读取 git 跟踪的文件
git add -N -f hardware-configuration.nix
```

### 3.3 必改的配置

**`modules/users/nas-user.nix`**：填入你的 SSH 公钥：

```nix
openssh.authorizedKeys.keys = [
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... you@laptop"
];
```

> Btrfs 数据卷无需任何 UUID 配置——挂载靠卷标（label），多设备成员由内核自动组装。

### 3.4 安装

```bash
# 国内网络建议带 TUNA 镜像安装：安装阶段的下载由 ISO 里的 nix 完成，
# 目标系统的 nix-settings.nix（TUNA 优先）要等装完激活后才生效，
# 所以这里必须显式传 --option（ISO 上是 root，substituter 会被接受）。
# 用仓库绝对路径作为 flake 引用（当前目录不含 flake.nix 时会报
# "could not find a flake.nix file"，绝对路径可避免该坑）。
nixos-install --flake /mnt/etc/nixos#default \
  --option substituters "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store https://cache.nixos.org/"
# 安装器会提示设置 root 密码 —— 设置并记住（仅控制台登录用，SSH 已禁 root 密码登录）

# 备选：写 root 用户级 nix 配置后直接 nixos-install（不要改 /etc/nix/nix.conf——
# ISO 上它是指向只读 store 的符号链接，echo >> 会报 Read-only file system）：
#   mkdir -p ~/.config/nix
#   echo 'substituters = https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store https://cache.nixos.org/' >> ~/.config/nix/nix.conf
#   nixos-install --flake .#default

reboot
# 拔掉 U 盘
```

## 4. 首次启动与基础配置

> ⚠️ **此时 br-lan 上没有 DHCP 和网关**（Alpine 路由 VM 还没创建）。NAS 自身也没有外网（网关指向还不存在的 192.168.10.1）。

**登录方式（二选一）**：

- **方案 A（推荐）**：笔记本网线接 **eno2**，手动设置静态 IP `192.168.10.100/24`，然后：

  ```bash
  ssh nas@192.168.10.2    # 用第 3.3 步配置的密钥
  ```

- **方案 B**：HDMI 接显示器 + USB 键盘，控制台用 root 登录（第 3.4 步设的密码）。控制台已启用 kmscon + Noto Sans CJK 字体（`modules/system/console.nix`），可正常显示中文；若开机后 TTY 无显示，说明 i915 DRM 初始化异常，排查 `journalctl -u kmsconvt@tty1`。

**登录后依次执行**：

```bash
# 1. 生成 sops age 密钥（记录输出的 public key，将来加密 secrets.yaml 用）
sudo mkdir -p /var/lib/sops-nix
sudo age-keygen -o /var/lib/sops-nix/key.txt
sudo chmod 600 /var/lib/sops-nix/key.txt
sudo cat /var/lib/sops-nix/key.txt | grep "public key:"

# 2. 设置 Samba 密码（与系统密码相互独立）
sudo smbpasswd -a nas

# 3. nas 系统密码已预填（modules/users/nas-user.nix 的 hashedPassword，
#    Cockpit/sudo/SSH 密码登录共用）。如需更换：openssl passwd -6
#    （或 mkpasswd -m sha-512）重新生成替换后 rebuild。
sudo nixos-rebuild switch --flake .#default

# 4. 硬件检查
lsmod | grep qnap8528
sensors
btrfs filesystem show          # 数据卷 RAID1 应显示两块成员盘
btrfs device stats /srv/data   # 校验错误计数应为 0
```

## 5. 启用 Router VM

VM 全声明式：镜像与消费端模块都在 router-image 仓库（flake input 已引用，
`services.router-vm` 已在 `modules/virtualization/default.nix` 中启用）。

```bash
# 1. 重建系统
sudo nixos-rebuild switch --flake .#default

# 2. 重启宿主（isolcpus 内核参数生效需要）
sudo reboot
```

重启后 VM 自动启动（fetchurl 拉镜像 → rootfs 只读副本 → cloud-hypervisor →
tap 自动挂桥）。验证：

```bash
systemctl status router-vm                 # VM 服务状态
systemctl status router-vm-deploy          # 密钥注入（无密钥时为空注入，属正常）
router-vm-console                          # VM 串口输出（网络故障时的排障通道）
ping -c 3 192.168.10.1                     # VM LAN 口可达
```

## 6. 配置密钥（sops-nix）

密钥由宿主 sops-nix 加密进 git、解密到 `/run/secrets`，`router-vm-deploy`
在 **每次 VM 启动后自动注入** guest（guest 无状态，重启即清、重新注入）。

```bash
# 1. 生成 age 密钥（首次）
sudo mkdir -p /var/lib/sops-nix
sudo age-keygen -o /var/lib/sops-nix/key.txt

# 2. 创建 secrets/secrets.yaml 并用 age 公钥加密（内容示例见
#    modules/security/sops.nix 的注释）：
#      ssh-public-key: |
#        ssh-ed25519 AAAA... deploy-key
#      tailscale-auth-key: tskey-auth-xxxxxxxxxxxxxxxx
#      cloudflared-token: eyJhIjoi...
cd secrets && sops -e secrets.yaml  # 或 sops edit secrets.yaml 交互编辑

# 3. 在 modules/security/sops.nix 中取消对应 secrets 声明的注释

# 4. 重建生效
sudo nixos-rebuild switch --flake .#default
sudo systemctl restart router-vm-deploy    # 立即补注入（或重启 VM 自动触发）
```

### Tailscale 登录（自动）

注入 authkey 后 deploy 自动启动 tailscaled 并后台 `tailscale up` 登录
（authkey 经 config.json 的 `file:` 机制被读取）。**key 必须是「可复用
（Reusable）」类型**——guest 无状态，每次重启都重新登录，一次性 key 第二次
注入即失效；建议勾选「Ephemeral」，重启产生的旧节点离线后自动移除。设备
审批（Device approval）在 Tailscale admin 侧处理，或配 ACL auto-approve。

```bash
ssh root@192.168.10.1 'tailscale status'   # 确认已登录（每次 VM 重启 = 新节点身份）
```

### 验证

**VM 内部**（`router-vm-shell`）：

```bash
rc-status                  # dnsmasq/chronyd/sshd/nftables 应已启动
ip -brief addr             # eth0=DHCP(WAN)、eth1=192.168.10.1
nft list ruleset | head    # 规则应包含 eth0/eth1 和 192.168.10.0/24
cat /root/.ssh/authorized_keys   # deploy 注入的 SSH 公钥
```

**客户端验证**（笔记本从静态 IP 改回 DHCP，仍接 eno2）：

```bash
ip a                       # 应拿到 192.168.10.100-200 的地址，网关 192.168.10.1，DNS 192.168.10.1
ping -c 3 8.8.8.8          # 外网连通（经 VM NAT）
nslookup baidu.com 192.168.10.1   # DNS 解析正常
ping -c 3 192.168.10.2      # 内网到 NAS 连通
```

> 此时 NAS 宿主机也通过 VM 网关获得了外网访问。

## 7. Cockpit 与收尾

1. 浏览器访问 **http://192.168.10.2:9090**，用 `nas` + 第 4 步设置的系统密码登录
   （VM 管理不在 Cockpit——router VM 由 systemd 声明式管理：`systemctl status router-vm`）


## 8. 验收清单

- [ ] 重启 NAS 后 Btrfs RAID1 数据卷自动挂载（`btrfs filesystem show` 显示两个成员）
- [ ] br-lan 客户端自动获取 DHCP 地址，外网与 DNS 正常
- [ ] Samba 共享可挂载（`\\192.168.10.2\data`，用户名 nas）
- [ ] NFS 共享可挂载（`mount -t nfs -o vers=4 192.168.10.2:/ /mnt`，应看到 data/cache/backup 三个目录）
- [ ] Syncthing(8384)、Navidrome(4533)、Feishin(9180) 端口可达
- [ ] Cockpit 登录正常
- [ ] 宿主 `sensors` 有风扇/温度读数，qnap8528 模块已加载

## 附录 A：默认地址与端口

| 项目 | 值 |
|---|---|
| NAS 宿主机 | 192.168.10.2（br-lan） |
| Alpine VM LAN | 192.168.10.1（网关/DNS） |
| DHCP 池 | 192.168.10.100 - 192.168.10.200 |
| SSH | 22（内网与 Tailscale 可密码登录，其他来源仅密钥） |
| Cockpit | 9090（br-lan） |
| Samba | 139/445 |
| NFS | 2049 |
| Syncthing | 8384（UI）/ 22000（同步） |
| Navidrome | 4533 |
| Feishin | 9180 |

## 附录 B：故障排查

| 现象 | 处理 |
|---|---|
| 重启后数据卷未挂载 | `btrfs device scan && mount /srv/data`；确认 filesystem.nix 卷标与 `mkfs.btrfs -L` 一致 |
| flake 报 not tracked by Git | `git add -N -f hardware-configuration.nix` |
| VM 无法启动 | `journalctl -u router-vm -b`、`router-vm-console`（串口输出）、`systemctl status router-vm-deploy`（密钥注入） |
| DHCP 客户端拿不到地址 | VM 内检查 `rc-service dnsmasq status`、`cat /etc/dnsmasq.d/10-dhcp-eth1.conf` |
| 外网不通但 VM 正常 | VM 内 `nft list ruleset` 检查 NAT 规则、`ip route` 检查默认路由 |
| Cockpit 登录失败 | 确认 nas 系统密码已设置并 `nixos-rebuild switch` 过 |
| qnap8528 未加载 | `sudo modprobe qnap8528`，`dmesg \| grep qnap8528` |
