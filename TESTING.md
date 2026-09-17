# QEMU 测试机预演指南

在正式上 NAS 之前，先用本机的 QEMU/libvirt 测试机把部署流程走一遍。

验证目标：接口改名、编址迁移、五个网关容器启动、VRRP 主备、DHCP、降级 DNS。

## ⚠️ 先读这条：测试机是 NAS 的完整克隆

测试机与**真实 NAS 同名、同 IP、同密钥、同 secrets**，按 IP 操作分不出是哪台：

| 判据 | 真实 NAS | 测试机 |
|---|---|---|
| `uname -r` | `6.18.50-QNAP-TS-564` | `6.18.44`（通用内核） |
| `br-lan` MAC | `9e:c5:bf:66:75:55` | 由 virtio 网卡派生 |
| uptime | 数天 | 测试期间会重启 |

**任何按 IP 操作前先验证身份。** 曾经因为只给 `.2` 加了指向 virbr0 的路由、
想当然地以为 `.1` 也在测试环境里，结果把私钥写进了**生产 router VM**、
还在真实 NAS 上加了一条无用路由。

另外：加 `/32` 路由期间工作站够不到真实 NAS 的 `.2`（NFS 重连会失败）。

## 环境

- libvirt 域 `nixos-26.05`，两块 virtio 网卡都挂在 virbr0（`192.168.122.0/24`）
- 磁盘标签与生产一致：`nixos`/`boot`/`data`(btrfs RAID1)/`cache`/`backup`
- 已有 sops age 私钥 `/var/lib/sops-nix/key.txt`，可解密 secrets

### 访问方式一：控制台（最可靠，无认证问题）

```bash
virsh screenshot nixos-26.05 /tmp/vm.png     # 截图看当前画面
virsh send-key   nixos-26.05 KEY_A           # 发送按键
```

`send-key` 的实测行为：
- 字母/数字/`KEY_ENTER`/`KEY_SPACE`/`KEY_DOT`/`KEY_SLASH`/`KEY_MINUS` 可用
- **上档键可用**：`KEY_LEFTSHIFT KEY_EQUAL` 能出 `+`
- **组合键不可用**：`KEY_LEFTCTRL KEY_X` 在 systemd-boot 编辑器里不生效

### 访问方式二：网络（给 VM 加一个工作站够得到的地址）

控制台里执行：

```bash
ip a a 192.168.122.250/24 dev br-lan        # 部署后会换成 mv-shim
```

然后从工作站 `ssh root@192.168.122.250` ✓（这条不碰生产网段）。

测试机的 `/etc/ssh/sshd_config` 只放行 `192.168.10.0/24` 与 Tailscale 网段的密码登录，
其它来源仅密钥——所以要么用密钥，要么从控制台补公钥：

```bash
mkdir -p /root/.ssh
echo "ssh-ed25519 AAAA..." > /root/.ssh/authorized_keys
```

## 测试机专属补丁（与正式配置的差异）

放在 `/root/qnap-aio`（从工作站 scp 的工作树），**不进正式仓库**：

| 补丁 | 原因 |
|---|---|
| `flake.nix` 去掉 `qnap-kernel` / `qnap8528` 输入 | 测试机没有 qnap-kernel 的 Cachix 缓存，从源码编要一小时+；且与网络架构无关 |
| `configuration.nix` 去掉 `hardware.qnap8528` | 没有 QNAP EC 硬件 |
| 用测试机自己的 `hardware-configuration.nix` | 正式仓库那份占位模板的 initrd 只有 SATA/USB，**缺 `virtio_blk` 会开不了机** |
| `flake.nix` 去掉 `./modules/services` | Samba/NFS/Syncthing/WebDAV/qBittorrent… 与网络测试无关，却把闭包撑到几 GB |
| `.link` 的 MAC 改成 VM 两块网卡（`52:54:00:13:83:94` / `52:54:00:ae:56:87`） | 规则按生产 MAC 匹配，不改则 `wan0`/`lan0` 不会出现 |
| 加 `vm-test.nix`：把 `192.168.122.250` 挂到 `mv-shim` | 保命地址——部署后 `br-lan` 被删、宿主机搬到 `.250`，不留这个地址就断线 |

生产与测试保留的模块：`system` / `network` / `gateway` / `security` / `users`。

## 测试局限

**两块网卡都在同一个 virbr0 上**，所以 `wan0`/`lan0` 没有真正隔开。因此：

- ❌ 测不了：上游是否接受两个 DHCP 客户端、WAN/LAN 隔离相关的行为
- ✅ 能测：接口改名、macvlan 容器启动、容器内 MAC 固定、单播 VRRP、
  广播 DHCP、side-router 的 WAN 健康检查进 FAULT

要真隔离，得给测试机加一个 libvirt isolated 网络接到第二块网卡。

## 步骤

```bash
# 1. 从工作站送代码进测试机（工作树，不含 .git；用 path: 引用使未跟踪文件也可见）
tar czf /tmp/qnap-aio.tar.gz --exclude=.git --exclude=result -C ~/Projects/qnap-nas/qnap-aio .
scp /tmp/qnap-aio.tar.gz root@192.168.122.250:/root/
ssh root@192.168.122.250 'mkdir -p /root/qnap-aio && tar xzf /root/qnap-aio.tar.gz -C /root/qnap-aio'

# 2. 应用上表的补丁（flake.nix / configuration.nix / hardware-configuration.nix / vm-test.nix）

# 3. 先求值，再构建（只 build 不 switch）
ssh root@192.168.122.250 'cd /root/qnap-aio && nix flake lock'
ssh root@192.168.122.250 'cd /root/qnap-aio && nixos-rebuild build --flake .#default'

# 4. 切换 + 重启（接口改名必须重启）
ssh root@192.168.122.250 'cd /root/qnap-aio && nixos-rebuild switch --flake .#default && reboot'
```

## 重启后的验收

```bash
ip -br link                                   # 应出现 wan0 / lan0 / mv-shim
ip -br addr show mv-shim                      # 192.168.10.2/24
systemctl list-units 'container@*'            # 五个容器
sudo nixos-container run main-router -- ip -br addr show eth0   # .2 + 浮动 .1
sudo nixos-container run main-router -- ip link show eth0       # 核对 MAC 是否等于配置值
sudo nixos-container run dnsmasq -- cat /var/lib/dnsmasq/dnsmasq.leases
```

**最不确定的一项**：容器内 macvlan 接口的 MAC 能否被 udev 的 `.link` 固定住。
若不生效，退路是宿主侧 `ExecStartPost` 里 `nixos-container run ... ip link set`。

## 构建卡住时先看这条

`/root/build.log` 里若出现大量：

```
Operation too slow. Less than 1 bytes/sec transferred the last 300 seconds; retrying
```

那不是慢，是连接被掐死、正在重试，每次白等 5 分钟。实测外因是**局域网里有别的主机在跑
BT 下载**——把 NAT 连接表/上行占满后，新连接就退化成这种僵死状态；关掉后下载速率立刻从
0.2 MB/s 回到 ~2 MB/s。与测试环境本身无关。

若反复僵死又找不到占用方，可试 `--option http-connections 1`（减少并发、单连接更稳）。
