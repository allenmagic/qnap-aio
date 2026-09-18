# QNAP TS-564 NixOS 一体化网关宿主

基于 NixOS 的 QNAP TS-564 NAS 配置：一台机器同时做 NAS 与内网网关，
使用 Flakes 进行声明式管理。

## 特性

- **声明式配置**: 所有配置通过 Nix 管理，可重现、可回滚
- **QNAP 硬件支持**: 集成 qnap8528 内核模块，支持风扇控制、LED、温度传感器
- **透明网关容器**: 策略分流 VPN + 高可用浮动网关（VRRP），宿主机保持纯二层
- **旁路服务**: Tailscale（官方 + 自建 headscale）、Cloudflare Tunnel 各自独立容器
- **存储服务**: Samba、NFS、Syncthing、WebDAV、Navidrome
- **下载与网盘**: qBittorrent、aria2、OpenList
- **仪表盘**: Glance 起始页，汇总各服务入口，自带登录认证
- **安全管理**: sops-nix 加密密钥管理、SSH 密钥认证
- **自动化维护**: 定期垃圾回收、SMART 监控、SSD Trim

## 硬件配置

- **型号**: QNAP TS-564
- **CPU**: Intel N5095 (4核)
- **内存**: 8GB
- **网络**: 2×2.5G 网口（Intel igc / I225，配置中按 MAC 锚定命名为 `wan`/`lan`）
- **存储**:
  - 1×256GB SSD (系统盘)
  - 1×1TB SSD (缓存盘)
  - 2×3TB HDD (RAID1 数据盘)
  - 1×2TB HDD (备份盘)

## 目录结构

```
.
├── flake.nix                          # Flake 入口文件
├── flake.lock                         # 依赖锁定（必须提交）
├── CLAUDE.md                          # Claude Code 开发指引
├── configuration.nix                  # 主机配置
├── filesystem.nix                     # 文件系统挂载与维护配置
├── hardware-configuration.nix.example # 硬件配置模板
├── hardware-configuration.nix         # 硬件配置（安装时生成，不入库）
├── README.md                          # 本文档
├── INSTALL.md                         # 从零安装完整指南
├── modules/
│   ├── system/                        # 基础系统配置（语言、软件包、Nix 设置）
│   ├── hardware/                      # 硬件相关（风扇、传感器）
│   ├── network/                       # 网络配置（物理口命名、macvlan shim、防火墙）
│   ├── gateway/                       # 网关容器组（main/side/dnsmasq/tailscale/cloudflared）
│   ├── services/                      # Samba、NFS、Syncthing、WebDAV、Glance、Navidrome、下载、OpenList
│   ├── security/                      # SSH、sops-nix
│   └── users/                         # 用户配置
├── secrets/
│   ├── README.md                      # sops-nix 使用指南
│   └── secrets.yaml                   # 加密的密钥文件（需手动创建）

## 网关架构

宿主机**纯二层**（不做转发），三层全部在 systemd-nspawn 容器里。没有虚拟机、
没有网桥：容器用 macvlan 直接挂到物理口上。

```text
上游光猫 ── wan ─┬─ main-router.eth1   (VRRP MASTER, YunShu 策略分流)
                  └─ side-router.eth1   (VRRP BACKUP, 降级直连 NAT)

内网 ───── lan ─┬─ main-router.eth0   .2
                 ├─ side-router.eth0   .3   VRRP 浮动网关 .1
                 ├─ tailscale.eth0     .4
                 ├─ cloudflared.eth0   .6
                 ├─ dnsmasq.eth0       .7   DHCP（option 3/6 都下发 .1）
                 └─ 宿主机 mv-shim     .250 macvlan shim（管理通道）
```

| 容器 | 职责 |
|---|---|
| `main-router` | 主透明网关，按商业 VPN 的策略路由分流（被墙域名走隧道） |
| `side-router` | 备份直连网关，main 不可用时接管浮动网关，降级为纯直连 |
| `dnsmasq` | 全网唯一 DHCP；降级态由 side-router 把 53 转发给它 |
| `tailscale` | 两个 tailscale 实例（官方控制面 + 自建 headscale），子网路由器 |
| `cloudflared` | 内网服务的内网穿透隧道（token 模式，ingress 在 CF 面板管理） |

**DNS 链路是这套设计的核心**：客户端 DNS 由 DHCP 下发为浮动网关 `.1`——main 持有 VIP 时
由 YunShu 隧道 DNS 做 fake-IP 分流，漂到 side 时由 side 把 53 转给 dnsmasq。把客户端 DNS
改成任何容器的固定地址都会让分流静默失效，不要那样改。

`main-router` 由独立仓库 [yunshu-container](https://github.com/allenmagic/yunshu-container)
提供（本仓库通过 flake input 引用）。**改那个仓库必须 commit 且 push**，否则本仓库求值
拉到的还是旧版本。

> 📐 设计取舍、实测的性能与资源对比、编址迁移清单见 [`docs/gateway.md`](docs/gateway.md)。

## 快速开始

> 📖 完整的分步安装指南（含磁盘分区、RAID、网关容器配置、验收清单）见 **[INSTALL.md](INSTALL.md)**。以下为精简流程。

### 1. 准备工作

1. 下载 NixOS minimal ISO
2. 制作启动 U 盘
3. 仅插入 256GB SSD，从 U 盘启动

### 2. 磁盘分区和文件系统创建

```bash
# 数据盘：Btrfs 原生 RAID1（两块 3TB HDD，内建 checksum + 每月自动 scrub）
mkfs.btrfs -m raid1 -d raid1 -L data \
  /dev/disk/by-id/ata-WDC_WD30EFRX-xxx \
  /dev/disk/by-id/ata-WDC_WD30EFRX-yyy

# 缓存/备份盘
mkfs.ext4 -L cache /dev/disk/by-id/ata-KINGSTON_SA400S37480G-xxx
mkfs.ext4 -L backup /dev/disk/by-id/ata-ST2000LM007-xxx
```

### 3. 安装 NixOS

```bash
# 挂载文件系统
mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount /dev/disk/by-label/boot /mnt/boot

# 生成硬件配置
nixos-generate-config --root /mnt

# 克隆本配置仓库（私有仓库，需要凭证）
cd /mnt/etc/nixos
git clone git@github.com:allenmagic/qnap-aio.git .

# 将生成的 hardware-configuration.nix 移动到仓库根目录
mv hardware-configuration.nix .

# 重要：flake 只能读取 git 跟踪的文件，用 intent-to-add 让其可见（文件本身不会被提交）
git add -N -f hardware-configuration.nix

# 编辑 modules/users/nas-user.nix，添加你的 SSH 公钥

# 安装系统
nixos-install --flake .#default

# 重启
reboot
```

### 4. 首次启动配置

```bash
# SSH 登录
ssh nas@192.168.10.2

# 生成 sops age 密钥
sudo mkdir -p /var/lib/sops-nix
sudo age-keygen -o /var/lib/sops-nix/key.txt
sudo chmod 600 /var/lib/sops-nix/key.txt

# 显示公钥（用于加密 secrets.yaml）
sudo cat /var/lib/sops-nix/key.txt | grep "public key:"

# 设置 Samba 密码
sudo smbpasswd -a nas

# 设置 nas 系统密码（sudo/SSH 密码登录用；SSH 仍只对内网与 Tailscale 网段放行）
mkpasswd -m sha-512
# 将输出哈希填入 modules/users/nas-user.nix 的 hashedPassword，然后重建系统
sudo nixos-rebuild switch --flake .#default
```

### 5. 配置网关容器的密钥

三个密钥（`tailscale-auth-key` / `headscale-auth-key` / `cloudflared-token`）
由 sops-nix 加密存放，宿主解密后经 systemd-nspawn 的 `--load-credential` 注入容器，
容器内不留副本。配置方法与验收步骤见 [INSTALL.md](INSTALL.md)。

> ⚠️ **首次部署前必读**：接口改名与编址迁移都需要重启，且都可能让机器失联，
> 操作顺序见 [`docs/gateway.md`](docs/gateway.md) 附录 A。


## 日常使用

### 系统更新

```bash
# 更新 flake 依赖
nix flake update

# 重建系统
sudo nixos-rebuild switch --flake .#default

# 如果有问题，回滚
sudo nixos-rebuild switch --rollback
```

### 网关容器更新

```bash
# 改容器代码（main-router 在 yunshu-container 仓库）：
#   在那个仓库改完 → commit → push（本仓库通过 github: input 引用，
#   没 push 的话这里拉到的还是旧版本）
nix flake update yunshu-container
sudo nixos-rebuild switch --flake .#default

# 改宿主机侧的容器声明（modules/gateway/*.nix）：
sudo nixos-rebuild switch --flake .#default

# 改密钥：编辑 secrets/secrets.yaml → rebuild。
#   三个容器密钥都带 restartUnits，值变化时容器会自动重启；
#   若改了别的密钥（无 restartUnits），需要手动重启对应服务。

# 进容器排障
sudo nixos-container run main-router -- systemctl status keepalived
sudo nixos-container run main-router -- ip -br addr
sudo nixos-container root-shell main-router        # 交互式
```

### 服务管理

```bash
# 查看服务状态（宿主上的）
systemctl status samba
systemctl status nfs-server
systemctl status syncthing
systemctl status webdav
systemctl status glance
systemctl status navidrome

# 网关容器（NixOS 容器统一是 container@<名字>.service）
systemctl status container@main-router
systemctl status container@dnsmasq

# 重启
sudo systemctl restart samba
```

> 系统没有 Cockpit（已删除）。Web 管理走 Glance 仪表盘（8080），其余用 SSH。

### 监控

```bash
# 查看风扇转速和温度
sensors

# 查看磁盘 SMART 状态
sudo smartctl -a /dev/sda

# 查看 Btrfs RAID 状态
btrfs filesystem show
btrfs device stats /srv/data
```

## 自定义配置

### 修改网络 IP

网段散落在十几处，改之前先读 `docs/gateway.md` 附录 A（有一份完整清单）。
至少包括：

- `modules/network/shim.nix`：宿主机的地址/网关/DNS
- `modules/network/default.nix`：防火墙端口表（**按接口名匹配**，接口名改了这张表也要改）
- `modules/gateway/*.nix`：各容器的地址、DHCP option 3/6、VRRP 单播地址
- 各服务的绑定地址：`samba.nix` / `nfs.nix` / `syncthing.nix` / `webdav.nix` /
  `glance.nix` / `music*.nix` / `downloads.nix` / `openlist.nix`
- `modules/security/ssh.nix` 的 `Match Address`

> ⚠️ 浮动网关 VIP 同时是 DHCP 下发的默认网关与 DNS，改它等于改所有下游设备的配置。

### 添加 Samba 共享

编辑 `modules/services/samba.nix`，在 `settings` 中添加新的共享段（每个共享名对应一个 smb.conf 段）：

```nix
settings.newshare = {
  "path" = "/srv/data/newshare";
  "read only" = "no";
  "valid users" = "nas";
  "force user" = "nas";
  "force group" = "nas";
};
```

### WebDAV 服务

`modules/services/webdav.nix`（hacdias/webdav）把 `/srv/data/webdav` 以 WebDAV
协议暴露给 iOS「文件」App、Infuse、RaiDrive、rclone 等客户端，认证用户 `nas`。

**首次启用**：密码走 sops（明文，不是系统密码 hash），需先添加密钥再 rebuild：

```bash
# 在 NAS 上（需 /var/lib/sops-nix/key.txt）
sops -k /var/lib/sops-nix/key.txt set secrets/secrets.yaml \
  webdav-password 'WEBDAV_PASSWORD=<足够强的密码>'
cd /etc/nixos && git pull            # 或本仓库所在路径
sudo nixos-rebuild switch --flake .#default
```

内网访问：`http://192.168.10.2:4918`（端口仅对内网 mv-shim 放行）。

**公网访问（Cloudflare Tunnel）**：隧道在路由 VM 内以 token 托管模式运行——
`/etc/cloudflared/config.yml` 只有 token，**ingress 规则在 Cloudflare 面板配置**，
不在本仓库：

> Zero Trust → Networks → Tunnels → 对应隧道 → Public Hostnames → Add
> - Subdomain/Domain：如 `webdav.zyx1986.icu`
> - Service：`HTTP` → `192.168.10.2:4918`（路由 VM 与 NAS 同桥，可直连）

回源是内网明文 HTTP（仅内网一跳），公网侧由 Cloudflare 边缘自动 HTTPS，
NAS 上无需证书。`behindProxy = true` 让日志按 `X-Forwarded-For` 记录真实客户端 IP。

⚠️ 公网暴露注意：
- **Cloudflare 免费版请求体上限 100MB**，超出的大文件 `PUT` 会失败（Enterprise 500MB）——
  大文件同步仍应走内网或 Tailscale。
- 强烈建议在同一面板加 **Cloudflare Access** 策略（邮箱 OTP 等），在 WebDAV 认证之外
  再加一道门，避免只靠用户名密码扛公网扫描。

### Glance 仪表盘

`modules/services/glance.nix`（glanceapp/glance）是内网起始页：`bookmarks` widget
汇总本机各 Web 服务入口（Feishin / gonic / Syncthing / Beszel / WebDAV），另有
时钟、天气（Beijing）、服务器状态。

内网访问：`http://192.168.10.2:8080`，登录用户 `nas`。

**认证**：Glance 自带登录（不同于 WebDAV 的 Basic 认证），配置在 `settings.auth`：
- `secret-key`：base64 的 64 随机字节，必须是**正好 64 字节**（`glance secret:make` 的输出）
- `users.<name>.password-hash`：bcrypt（`glance password:hash '<密码>'`）

两个值都存 sops（`glance-secret-key` / `glance-password-hash`），模块的 ExecStartPre
以 root 跑 jq 把它们替换进 `/run/glance/glance.yaml`，明文不进 nix store。
⚠️ **sops 里的值不能带尾换行**——secret-key 多 1 字节即长度校验失败，password-hash
多一个 `\n` 则 bcrypt 比对恒失败。

改密码：

```bash
HASH=$(nix run nixpkgs#glance -- password:hash '<新密码>')
printf '%s' "$HASH" | python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))' \
  | sops set --value-stdin secrets/secrets.yaml '["glance-password-hash"]'
sudo nixos-rebuild switch --flake .#default && sudo systemctl restart glance
```

**公网访问**：和 WebDAV 同一套路，Cloudflare Zero Trust 面板加 Public Hostname →
`HTTP` → `192.168.10.2:8080`。`server.proxied = true` 已开启，Glance 会按
`X-Forwarded-For` 认客户端 IP——它自带的暴力破解防护（5 次失败封 IP 5 分钟）依赖这一点。

> ⚠️ `bookmarks` 里现在是**内网地址**，从公网打开 Glance 时这些链接点不开。
> 需要时再加一组走 Cloudflare 子域名的链接（lib 里的 `icon` 走 jsdelivr CDN，
> 出网不稳时图标会加载不出来，可去掉 icon 或改本地图标）。

### 添加 SSH 公钥

编辑 `modules/users/nas-user.nix`:

```nix
openssh.authorizedKeys.keys = [
  "ssh-ed25519 AAAAC3... your-key-here"
];
```

## 故障排查

### QNAP 模块未加载

```bash
# 检查模块是否已加载
lsmod | grep qnap8528

# 查看 dmesg 日志
dmesg | grep qnap8528

# 手动加载
sudo modprobe qnap8528
```

### 数据卷未自动挂载

```bash
# 重新扫描并挂载
sudo btrfs device scan
sudo mount /srv/data

# 确认卷标与 filesystem.nix 一致
btrfs filesystem show
```

### 网关/网络问题

```bash
# 宿主机侧接口
ip -br addr                      # 应有 mv-shim 192.168.10.2/24
ip -br link                      # wan / lan 应为 UP

# 浮动网关在谁手里
sudo nixos-container run main-router -- ip -br addr show eth0
sudo nixos-container run side-router -- ip -br addr show eth0

# VRRP 心跳（两个容器应互相看得到对方）
sudo nixos-container run main-router -- tcpdump -i eth0 -n proto 112

# 连通性
ping 192.168.10.1                # 浮动网关
sudo nixos-container run dnsmasq -- journalctl -u dnsmasq -n 50

# 进容器
sudo nixos-container root-shell main-router
```

排查 DNS 分流前先 `systemctl stop nscd`：宿主机与容器都跑 nscd，`getent`/`curl`
会走 nscd 的 socket（由 nscd 在宿主命名空间里查），容易得出"分流生效"的假象。

## 设计决策

- **容器而非虚拟机**：网关全部是 systemd-nspawn 容器，共享宿主内核，没有 guest 内核、
  没有 qcow2 镜像副本、没有 isolcpus 独占核（实测对比见 `docs/gateway.md` §4.1）。
  改造前是 cloud-hypervisor MicroVM 方案。
- **macvlan 而非桥接**：容器直接拿到物理口的子接口，宿主机不进数据面。
  宿主机自己用一个 macvlan shim 保留管理通道。
- **浮动网关 + 双角色 DNS**：VIP 是下游唯一感知的网关；DNS 跟着 VIP 走——
  main 持有时分流，漂到 side 时降级为直连解析。这是"客户端 DNS 必须经过网关"的必然结果。
- **职责拆分成多个容器**：网关、DNS、隧道、穿透各自独立，互不牵连；
  tailscale 的两个实例则合并进一个容器（同一类东西，拆开只是多付一份开销）。
- **模块化**：每个功能独立一个模块文件（`modules/`）；main-router 的实现在
  [yunshu-container](https://github.com/allenmagic/yunshu-container) 仓库。

## 参考文档

- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [qnap8528 模块文档](https://github.com/allenmagic/qnap8528)
- [sops-nix 使用指南](https://github.com/Mic92/sops-nix)

## License

MIT
