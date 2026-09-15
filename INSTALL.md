# 从零安装指南

从一台全新的 QNAP TS-564 裸机开始，到运行着完整 NAS 服务 + 一组网关容器的 NixOS 系统。

## 0. 准备清单

**硬件**

- QNAP TS-564（含全部 5 块硬盘）
- U 盘（≥ 4GB，制作启动盘）
- 笔记本一台（后续通过 SSH 操作）
- 网线 2 根
- 显示器 + USB 键盘（可选，备用控制台）

**软件（提前下载）**

- [NixOS minimal ISO](https://nixos.org/download/)（x86_64）

**信息准备**

- 你的 SSH 公钥（写入 `modules/users/nas-user.nix`）
- 规划好的密码：root 密码（仅控制台）、nas 系统密码（sudo/SSH 密码登录用）、Samba 密码
- 三个网关密钥：Tailscale authkey、Headscale authkey、Cloudflare Tunnel token

**网络规划**

```
上行（光猫/上级路由）
  │
  │ wan0（原 enp2s0，宿主机不配 IP）
  ▼
  ├── main-router 容器 eth1   VRRP MASTER，策略分流
  └── side-router 容器 eth1   VRRP BACKUP，降级直连

内网
  │
  │ lan0（原 enp3s0，宿主机不配 IP）
  ▼
  ├── main-router.eth0  .2 ┐
  ├── side-router.eth0  .3 ├─ VRRP 浮动网关 .1（下游的默认网关与 DNS）
  ├── tailscale.eth0    .4 │
  ├── cloudflared.eth0  .6 │
  ├── dnsmasq.eth0      .7 ┘  DHCP 服务器
  └── 宿主机 mv-shim    .250（macvlan shim，管理通道）
     内网设备 .100-.200（dnsmasq 提供 DHCP）
```

> ⚠️ 接口名 `wan0`/`lan0` 是**按 MAC 锚定**的（`modules/network/links.nix`），
> 不是内核给的 `enpXsY`。改名由 udev 在设备出现时处理，**必须重启才生效**，
> 生效后旧名消失。

## 1. 制作启动盘并进入安装环境

```bash
# 在笔记本上制作启动盘（假设 U 盘为 /dev/sdb，请确认设备名！）
sudo dd if=nixos-minimal-xxx-x86_64.iso of=/dev/sdb bs=4M status=progress && sync
```

1. 插入**全部 5 块硬盘**和 U 盘，QNAP 开机进 BIOS/引导菜单，从 U 盘启动
2. **网线：把接上级路由的那根插到 QNAP 的 WAN 口**（安装阶段需要 DHCP 上网下载包）
3. 进入 ISO 后确认网络：

```bash
ip a          # 确认有接口拿到了 DHCP 地址
ping -c 3 8.8.8.8
```

> 备注：ISO 环境下网口都自动 DHCP，装完系统后才会按配置变成 `wan0`/`lan0` 并交给容器。

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

git clone git@github.com:allenmagic/qnap-aio.git .   # 私有仓库，需要凭证
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

> ⚠️ **此时内网上还没有 DHCP 和网关**（dnsmasq 容器还没起来）。NAS 自身也没有外网
> ——它的默认路由指向浮动网关 `.1`，而 `.1` 要等 main-router 或 side-router 接管。

**登录方式（二选一）**：

- **方案 A（推荐）**：笔记本网线接到 QNAP 的**内网口**，手动设置静态 IP `192.168.10.100/24`，然后：

  ```bash
  ssh nas@192.168.10.250    # 用第 3.3 步配置的密钥
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
#    sudo/SSH 密码登录共用）。如需更换：openssl passwd -6
#    （或 mkpasswd -m sha-512）重新生成替换后 rebuild。
sudo nixos-rebuild switch --flake .#default

# 4. 硬件检查
lsmod | grep qnap8528
sensors
btrfs filesystem show          # 数据卷 RAID1 应显示两块成员盘
btrfs device stats /srv/data   # 校验错误计数应为 0
```

## 5. 部署网关容器

网关容器全声明式（`modules/gateway/*.nix`），随 `nixos-rebuild switch` 一起生效。

```bash
# 1. 重建系统
sudo nixos-rebuild switch --flake .#default

# 2. 重启宿主 —— **必须**：物理口改名（enpXsY → wan0/lan0）由 udev 在设备
#    出现时处理，switch 不会重命名一个正在用的接口
sudo reboot
```

重启后五个容器自动启动。验证：

```bash
# 接口名已切换（应看到 wan0 / lan0 / mv-shim，不再是 enp2s0/enp3s0）
ip -br link

# 宿主机自己的地址与路由
ip -br addr show mv-shim                   # 应有 192.168.10.250/24
ip route                                   # 默认路由应指向 192.168.10.1

# 五个容器都起来了
systemctl list-units 'container@*'

# 浮动网关在 main-router 手里（正常态）
sudo nixos-container run main-router -- ip -br addr show eth0   # 应有 .2 与 .1

# side-router 待命
sudo nixos-container run side-router -- systemctl status keepalived

# 下游能拿到地址（笔记本改成 DHCP 后）
ping -c 3 192.168.10.1
```

> ⚠️ WAN 侧第一次起会有两个容器同时要 DHCP 租约（改造前只有一个 VM 在拨号）。
> 上游只允许单客户端时需要改用串行方案，见 `docs/gateway.md` §15.2。

## 6. 配置密钥（sops-nix）

密钥由宿主 sops-nix 加密进 git、解密到 `/run/secrets`，容器启动时由
systemd-nspawn 的 `--load-credential` 读入容器（落在
`/run/credentials/@system/`，内存，容器内不留副本）。

```bash
# 1. 生成 age 密钥（第 4 步已生成过则跳过）
sudo mkdir -p /var/lib/sops-nix
sudo age-keygen -o /var/lib/sops-nix/key.txt

# 2. 创建 secrets/secrets.yaml 并用 age 公钥加密（内容示例见
#    modules/security/sops.nix 的注释）：
#      tailscale-auth-key: tskey-auth-xxxxxxxxxxxxxxxx
#      headscale-auth-key: tskey-auth-xxxxxxxxxxxxxxxx
#      cloudflared-token:  eyJhIjoi...
cd secrets && sops -e secrets.yaml  # 或 sops edit secrets.yaml 交互编辑

# 3. 重建生效
sudo nixos-rebuild switch --flake .#default
```

> 密钥值**不要带尾换行**（`sops set` 容易带上）。当前三个消费方都是
> `$(cat ...)` 取值、命令替换会剥掉换行；换成直接把文件当 token 读的写法
> 就会把换行一起送进去，认证失败且报错指向不明。

### Tailscale / Headscale 登录

两个实例都由各自的 `tailscale up` 自动登录（authkey 从凭据目录读取）。

**key 建议用「可复用（Reusable）」类型**：节点身份虽然持久化在
`/srv/data/tailscale/`，但容器重建或状态盘丢失时会重新注册，一次性 key
第二次就失效。子网路由（`192.168.10.0/24`）需要在 Tailscale admin 与
Headscale 侧分别 approve。

```bash
sudo nixos-container run tailscale -- tailscale status
sudo nixos-container run tailscale -- tailscale --socket=/run/headscale/tailscaled.sock status
```

### 验证

**容器内部**：

```bash
# main-router：分流与 VRRP
sudo nixos-container run main-router -- ip -br addr        # eth0=.2 + .1(VIP)，eth1=DHCP
sudo nixos-container run main-router -- nft list ruleset | head
sudo nixos-container run main-router -- systemctl status keepalived

# dnsmasq：DHCP 与租约
sudo nixos-container run dnsmasq -- cat /var/lib/dnsmasq/dnsmasq.leases

# side-router：待命与 DNS 转发规则
sudo nixos-container run side-router -- systemctl status keepalived
sudo nixos-container run side-router -- nft list ruleset | grep -A3 prerouting
```

**客户端验证**（笔记本从静态 IP 改回 DHCP，接内网口）：

```bash
ip a                       # 应拿到 192.168.10.100-200，网关 192.168.10.1，DNS 192.168.10.1
ping -c 3 8.8.8.8          # 外网连通（经 main-router 的 NAT/分流）
ping -c 3 192.168.10.250   # 内网到 NAS 连通
```

> 测 DNS 分流前先 `systemctl stop nscd`：宿主机与容器都跑 nscd，
> `getent`/`curl` 的解析会走 nscd 的 socket（由 nscd 在宿主命名空间里查），
> 容易得出"分流生效"的假象。

> 此时 NAS 宿主机也通过浮动网关获得了外网访问（默认路由指向 `.1`）。

## 7. 收尾

1. 浏览器访问 **http://192.168.10.250:8080**，用 `nas` 登录 Glance 仪表盘
   （系统没有 Cockpit，Web 管理走它；其余用 SSH）

> ⚠️ **必须逐条验证的真机项**（这些在开发机上无法验证，只能上机确认）：
> - macvlan 接口的 MAC 能否靠容器内 udev `.link` 固定住（`ip link` 看是否等于配置值）
> - 两个容器的**单播 VRRP** 是否真能互通（`tcpdump -i eth0 -n proto 112`）
> - dnsmasq 能否收到**广播** DHCP 请求（macvlan 下广播是否正常送达）
> - WAN 侧上游是否接受两个容器各自的 DHCP 租约
> - side-router 的 WAN 健康检查失败时是否真的进 FAULT（不会接管 VIP）

## 8. 验收清单

- [ ] 重启 NAS 后 Btrfs RAID1 数据卷自动挂载（`btrfs filesystem show` 显示两个成员）
- [ ] 接口名已是 `wan0`/`lan0`（不再是 `enp2s0`/`enp3s0`），且 `mv-shim` 有 `192.168.10.250/24`
- [ ] 五个容器全部 running（`systemctl list-units 'container@*'`）
- [ ] 浮动网关 `.1` 在 main-router 的 eth0 上；停掉它之后漂移到 side-router
- [ ] 下游客户端自动获取 DHCP 地址，网关与 DNS 都是 `.1`
- [ ] 被墙域名走隧道、境内直连（分流生效；测之前先 `systemctl stop nscd`）
- [ ] Samba 共享可挂载（`\\192.168.10.250\data`，用户名 nas）
- [ ] NFS 共享可挂载（`mount -t nfs -o vers=4.2 192.168.10.250:/ /mnt`，应看到 data/cache/backup 三个目录）
- [ ] Syncthing(8384)、Navidrome(4533)、Feishin(9180)、Glance(8080) 端口可达
- [ ] 宿主 `sensors` 有风扇/温度读数，qnap8528 模块已加载

## 附录 A：默认地址与端口

| 项目 | 值 |
|---|---|
| 浮动网关 VIP（下游网关/DNS） | 192.168.10.1（VRRP，main-router 或 side-router 持有） |
| main-router | 192.168.10.2 |
| side-router | 192.168.10.3 |
| tailscale 容器 | 192.168.10.4 |
| cloudflared 容器 | 192.168.10.6 |
| dnsmasq 容器 | 192.168.10.7 |
| NAS 宿主机 | 192.168.10.250（mv-shim） |
| DHCP 池 | 192.168.10.100 - 192.168.10.200（dnsmasq） |
| SSH | 22（内网与 Tailscale 可密码登录，其他来源仅密钥） |
| Glance | 8080 |
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
| 宿主完全没有网络 | `ip -br addr show mv-shim`；`ip link show lan0`；若改名没生效说明没重启 |
| 容器起不来 | `journalctl -u container@<名字> -b`；多半是 bindMount 源目录不存在 |
| 浮动网关没接管 | 两个容器各自 `ip -br addr`；`tcpdump -i eth0 -n proto 112` 看心跳是否互通（收不到 ⇒ 防火墙/接口名） |
| DHCP 客户端拿不到地址 | dnsmasq 容器内 `systemctl status dnsmasq`、`cat /var/lib/dnsmasq/dnsmasq.leases`；确认 67/udp 已放行 |
| 外网不通但容器正常 | 容器内 `nft list ruleset` 看 masquerade 是否打在 WAN 口上、`ip route` 看默认路由 |
| 分流失效（境内网站也走代理） | 先 `systemctl stop nscd` 再测；确认 DHCP 下发的 option 6 是 `.1` 而不是某个容器地址 |
| 隧道容器登录失败 | `nixos-container run tailscale -- journalctl -u tailscaled -n 50`；确认密钥已注入且无尾换行 |
| qnap8528 未加载 | `sudo modprobe qnap8528`，`dmesg \| grep qnap8528` |
