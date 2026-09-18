# 测试机预演指南

在正式上 NAS 之前，先用本机的 libvirt 测试机把部署流程走一遍。
装配/构建/部署/验证都由 [`scripts/vm-test.sh`](scripts/vm-test.sh) 完成。

验证目标：接口改名、编址迁移、bridge 改造、三个网关容器启动、veth 改名与 MAC 固定。
`vm-test.sh verify` 的判据就是这几条（宿主地址在 `br-lan`、`wan`/`lan` up、三个容器
running、main-router 的 `NRestarts=0`、`lan` 有 `.1` 且 MAC 是配置值、tailscale `.4`）。

脚本没覆盖、需要手工看的：DHCP 租约、宿主 `tcpdump -i br-lan` 的可见性、
启动排序（`journalctl -D /var/lib/nixos-containers/main-router/var/log/journal -b`）。

## ⚠️ 先读这条：测试机是 NAS 的完整克隆

测试机与**真实 NAS 同名、同 IP、同密钥、同 secrets**，按 IP 操作分不出是哪台：

| 判据 | 真实 NAS | 测试机 |
|---|---|---|
| `uname -r` | `6.18.50-QNAP-TS-564` | 通用内核（如 `6.18.44`） |
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

从脚本或控制台补上保命地址：

```bash
ip a a 192.168.122.250/24 dev br-lan
```

然后从工作站 `ssh root@192.168.122.250` ✓（这条不碰生产网段）。
脚本里的 `vm-test.nix` 已经把它做成开机自动加的 oneshot。

测试机的 `/etc/ssh/sshd_config` 只放行 `192.168.10.0/24` 与 Tailscale 网段的密码登录，
其它来源仅密钥——所以要么用密钥，要么从控制台补公钥：

```bash
mkdir -p /root/.ssh
echo "ssh-ed25519 AAAA..." > /root/.ssh/authorized_keys
```

## 跑一遍（推荐）

```bash
./scripts/vm-test.sh              # 装配 + 构建 + 部署 + 验证
./scripts/vm-test.sh build        # 只装配 + 构建（改完配置先跑这个）
./scripts/vm-test.sh deploy       # 只 boot + 重启
./scripts/vm-test.sh verify       # 只验证（等 boot_id 变化后跑检查）
./scripts/vm-test.sh status       # 看一眼 VM 现状
```

脚本处理了三个**踩过的坑**：

| 坑 | 脚本的做法 |
|---|---|
| **VM 拉不到 GitHub**。VM 是直连出口（自己那套配置没有 YunShu），`github.com` / cachix 都不通，而 flake input 默认走 `git+https` | 把 `router-container` / `yunshu-nix` 的源码 scp 进去，用 `--override-input path:` 覆盖 |
| **三份 VM 专属文件不能被覆盖**：`configuration.nix`（去掉 qnap8528）、`vm-sops-stub.nix`（没有 age 私钥）、`hardware-configuration.nix`（真实 virtio 盘） | 装配时保留 VM 上的这三份；`flake.nix` 与 `vm-test.nix` 每次重写 |
| **保命地址挂错接口**：bridge 改造后 `mv-shim` 不存在，`192.168.122.250` 必须挂 `br-lan`，否则失去 SSH 入口（只能 `virsh console`） | `vm-test.nix` 里挂 `br-lan` |

`vm-test.nix` 里另外两处覆盖：网卡 MAC 换成 VM 的两块 virtio（`52:54:00:13:83:94` /
`52:54:00:ae:56:87`，生产 MAC 匹配不上就不会出现 `wan`/`lan`），宿主 DNS 指向
libvirt 网关 `192.168.122.1`（不走隧道）。

## 测试局限

**两块网卡都在同一个 virbr0 上**，所以 `wan`/`lan` 没有真正隔开。因此：

- ❌ 测不了：上游是否接受多个 DHCP 租约、WAN/LAN 隔离相关的行为
- ❌ 测不了：**内核相关项**。VM 用 nixpkgs 通用内核，不是 `qnap-kernel` 的裁剪内核
  （缺 nftables 表达式模块那类问题在 VM 里永远复现不出来）
- ❌ 测不了：**YunShu 分流**。VM 里没有登录态（也不该拷——同一账号两个会话可能把
  生产那台踢掉），隧道与 fake-IP 那条路只能靠 NAS 验
- ❌ 测不了：**子网路由**（需要控制面批准）
- ✅ 能测：接口改名、bridge/编址、容器启动、容器内 veth 改名与 MAC 固定、DHCP、
  状态挂载、启动排序

要真隔离，得给测试机加一个 libvirt isolated 网络接到第二块网卡。

## 构建卡住时先看这条

`/tmp/vm-build.log`（或 VM 上的 `/root/build.log`）里若出现大量：

```
Operation too slow. Less than 1 bytes/sec transferred the last 300 seconds; retrying
```

那不是慢，是连接被掐死、正在重试，每次白等 5 分钟。实测外因是**局域网里有别的主机在跑
BT 下载**——把 NAT 连接表/上行占满后，新连接就退化成这种僵死状态；关掉后下载速率立刻从
0.2 MB/s 回到 ~2 MB/s。与测试环境本身无关。

若反复僵死又找不到占用方，可试 `--option http-connections 1`（减少并发、单连接更稳）。
