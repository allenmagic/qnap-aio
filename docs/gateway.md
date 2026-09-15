# NixOS 纯二层宿主机 + systemd-nspawn 容器 + Macvlan/VRRP 高可用解耦网关设计

> **实施前必读：三个前置决策已定，正文已按结论重写。这是破坏性变更，与当前
> 运行的 `router-image` + `yunshu-nix` 部署冲突，迁移清单见附录 A。**
>
> | 决策 | 结论 |
> |---|---|
> | DNS / DHCP 归属 | **网关持有**。客户端的默认网关与 DNS 都指 VIP；DHCP 与降级态 DNS 由常驻的 `dnsmasq-container` 提供；AdGuard 方案已废弃（§6.5~§6.7、§11） |
> | 备机位置 | **同机双容器**。失败域 = 容器级故障与维护窗口，**不覆盖宿主机故障**（§7.4、§18） |
> | 编址 | **按本文重编**：VIP `.1`、宿主机 `.250`、main `.2`、side `.3`（附录 A） |

## 1. 需求与约束

- 宿主机是 NixOS。
- 两个物理网口：`enp2s0`、`enp3s0`，未统一命名为 `eth0/eth1`。
- 宿主机希望保持纯二层：
  - 不开启 `ip_forward`
  - 不加载 `br_netfilter`
  - 不参与三层路由、NAT、DHCP、DNS
  - 只做二层转发、接口移交和容器生命周期管理
- 透明网关需要主备：
  - `main-router` 为主网关，流量按商业 VPN 策略路由走 `tun0` 或直连。
  - `side-router` 为备份直连网关，常驻 standby。
  - 通过 VRRP 共享 VIP，下游的**默认网关与 DNS 都指向 VIP**（DHCP 下发）——
    DNS 必须随之在节点间切换，见 §6.7。
  - **DHCP 服务器常驻 `dnsmasq-container`**，不随 VIP 漂移，见 §6.6。
- main-route：
  - 使用当前已有的yunshu-nix，可以进行改造优化
- Tailscale、Cloudflared 独立容器化（AdGuard Home 已从需求中移除）：
  - tailscale需要有两个，一个是自建的headscale，作为主要使用方案，一个是使用官方的tailscale作为backup节点
  - tailscale/cloudflared 可参考router-image中base部分的配置
  - 出站直连物理 WAN，不经过商业 main。
  - 不参与 VRRP 漂移。
  - DNS 服务器（dnsmasq）不能顶替客户端的 DNS —— 客户端 DNS 必须经过网关
    才能触发 fake-IP 分流（§6.7、§11）。
- DHCP 与降级态 DNS 由一个常驻的 `dnsmasq-container` 提供。
- 密钥管理继续使用 sops-nix。
- 原先 Tailscale/Cloudflared 在 cloud-hypervisor MicroVM 中运行，密钥解密到 `/run/secret` 后注入 VM。
- 希望迁移到 systemd-nspawn 容器后，仍保持声明式、安全、可维护。
- 希望宿主机可用 eBPF/XDP 构建第一道粗粒度防火墙。

## 2. 核心设计原则

1. **宿主机纯二层**
   - 宿主机只创建 macvlan 接口或 bridge（首选macvlan），不配置三层 IP。
   - 不开启 `net.ipv4.ip_forward`。
   - 关闭 `br_netfilter`，避免 bridge 流量经过宿主机 nftables。
   - 物理网卡保持 UP，必要时开启 PROMISC，接纳 macvlan 多 MAC。

2. **容器按职责解耦**
   - `main-router`：主透明网关，VRRP MASTER。
   - `side-router`：备份直连网关，VRRP BACKUP，常驻。
   - `headscale-container`：Subnet Router，独立直连。
   - `tailscale-container` ：Subnet Router，独立直连。
   - `cloudflared-container`：内网隧道，独立直连。
   - `dnsmasq-container`：DHCP 服务器 + 降级态 DNS，独立直连，不参与 VRRP
     （客户端 DNS 仍指 VIP，见 §6.5~§6.7）。

3. **网络接口尽量精简**
   - LAN 侧优先使用 macvlan 模式，容器直接获得 LAN 子接口。
   - WAN 侧根据上游兼容性选择：
     - 若上游允许多 MAC、多 DHCP，可用 macvlan + 容器内 DHCP。
     - 若上游只允许单 MAC，或使用 PPPoE，建议退回 veth + bridge。
   - 宿主机保留一个管理 shim 接口，避免无 IP 无法 SSH。

4. **主备切换由 VRRP 负责**
   - VIP 是下游唯一感知的网关。
   - `main-router` 健康时持有 VIP。
   - `tun0` 不通或计划维护时，VIP 漂移到 `side-router`。
   - Keepalived 健康检查必须检查 `tun0` 真实连通性。

5. **密钥不落盘**
   - 宿主机用 sops-nix 解密。
   - 通过 systemd-nspawn `--load-credential` 注入容器。
   - 容器内服务从 `/run/credentials/@system/` 读取。
   - 避免使用 `bindMounts` 挂载 sops-nix 的符号链接密钥文件。

6. **状态持久化用 bindMounts**
   - Tailscale / headscale 状态目录、Cloudflared 凭据、dnsmasq 租约库等持久化到宿主机目录。
   - 注意 `privateUsers` 下的 UID/GID 映射。

## 3. 推荐拓扑与编址

```text
上游光猫 / 上级路由
  │
enp2s0
  │
  ├─ main-router.wan0       动态 DHCP / main endpoint 出站
  └─ side-router.wan0     动态 DHCP / 备用直连出站

物理 LAN
  │
enp3s0
  │
  ├─ main-router.eth0       192.168.10.2    VRRP MASTER，持有 VIP
  ├─ side-router.eth0       192.168.10.3    VRRP BACKUP
  ├─ tailscale-container.eth0   192.168.10.4   Subnet Router（官方控制面）
  ├─ headscale-container.eth0   192.168.10.5   Subnet Router（自建控制面）
  ├─ cloudflared-container.eth0 192.168.10.6   隧道
  ├─ dnsmasq-container.eth0     192.168.10.7   DHCP + 降级态 DNS
  └─ 下游设备                 网关 = 192.168.10.1 (VIP)

宿主机管理:
  └─ macvlan shim @ enp3s0    192.168.10.250/32 + 默认路由
                              （宿主机自身要出网做 nix flake update / sops / NTP）
```

| 角色 | 接口 | IP | 默认网关 | 说明 |
|---|---|---|---|---|
| 上游路由 | enp2s0 | 192.168.1.1 | ISP | WAN 侧 DHCP |
| VIP | LAN 虚拟 | 192.168.10.1 | - | 下游默认网关 |
| main-router | eth0/eth1 | DHCP / 192.168.10.2 | 上游 | 主网关，VRRP MASTER |
| side-router | eth0/eth1 | DHCP / 192.168.10.3 | 上游 | 备网关，VRRP BACKUP |
| tailscale-container | eth0 | 192.168.10.4 | 192.168.10.3 | Subnet Router（官方） |
| headscale-container | eth0 | 192.168.10.5 | 192.168.10.3 | Subnet Router（自建） |
| cloudflared-container | eth0 | 192.168.10.6 | 192.168.10.3 | 内网穿透 |
| dnsmasq-container | eth0 | 192.168.10.7 | 192.168.10.3 | DHCP + 降级态 DNS |
| 下游设备 | - | 192.168.10.100~200 | 192.168.10.1 | 终端 |

> **容器内接口名不是 `eth0`**：systemd-nspawn 的 `--network-macvlan=` 在未显式指定时，
> 把容器内接口命名为 `mv-<父接口>`（`enp3s0` → `mv-enp3s0`）。NixOS 的
> `containers.<name>.macvlans` 把列表元素原样透传给该参数，所以统一写成
> `macvlans = [ "enp3s0:eth0" ]`（冒号后半段才是容器内名字），下文所有
> keepalived `interface eth0`、IP 表和示例里的 `eth0`/`eth1` 才成立。

## 4. 为什么选择 systemd-nspawn，而不是 Quadlet/OCI

对于本项目，systemd-nspawn 更合适：

- **原生声明式 macvlan 支持**：NixOS `containers.<name>.macvlans` 可直接声明。
- **无需构建 OCI 镜像**：现有 Nix flake 模块可直接作为容器配置复用。
- **与 systemd 深度集成**：`ExecStopPre`、`ExecStartPost`、依赖顺序、Keepalived 编排都原生支持。
- **密钥注入更自然**：systemd-nspawn 支持 `--load-credential`。
- **状态持久化简单**：`bindMounts` 直接挂载宿主机目录。
- **维护成本低**：`nixos-rebuild switch` 一次更新宿主机和所有容器。
- **生态丰富性不是关键**：服务固定为 DNS、Tailscale、Cloudflared、main 网关和备份路由，不需要大量第三方 OCI 镜像。

Quadlet 的优势在于 Podman 生态、OCI 镜像复用和大规模编排；本项目服务少、长期稳定、深度定制，因此 systemd-nspawn 更方便。

### 4.1 与现状（router-vm + yunshu-container）的性能与资源对比

> 以下为 2026-09-15 在跑的生产机上的实测数据（开机 5.7 天），不是估算。

#### 数据面路径：新方案少一跳

先纠正一个常见误解——**当前的 VPN 流量本来就穿过 router VM**，并非绕开它。
yunshu 容器的默认路由指向 router VM（`upstreamGateway = 192.168.10.1`），
而 router VM 的 nftables 里有 `oifname @wan_interfaces masquerade`：

```text
当前正常态：
  客户端 ─enp3s0─> br-lan ─> yunshu 容器 veth
                              ├─ 分流 + TUN 加密 + masquerade
                              └─ 出 eth0 → br-lan ─> router VM 的 LAN tap
                                                       ├─ VM 内核转发 + masquerade
                                                       └─ WAN tap ─> br-wan ─enp2s0─> 上行

新方案正常态：
  客户端 ─enp3s0─> macvlan ─> main-router eth0
                              ├─ 分流 + TUN 加密 + NAT
                              └─ eth1（macvlan @ enp2s0） ─enp2s0─> 上行
```

新方案少掉：**一次跨 VM 往返、一次桥接、一次 NAT**。这次往返还不便宜——
`vm-service.nix` 用的是 `--net tap=router-wan,mac=...`，**没有 `vhost=on`**，
走的是 cloud-hypervisor 自带的用户态 virtio-net 后端，每个包都要经过 VMM 进程；
而 nspawn 的 macvlan/veth 路径是纯内核的，没有进程上下文。

| 路径 | 变化 |
|---|---|
| 主转发路径（VPN 流量） | 快：少一次 VM 往返 + 少一次 NAT |
| 旁路服务（tailscale/cloudflared） | 快：从 VM 的 virtio 搬到 nspawn macvlan |
| 宿主机自身出网（下载/更新） | 快：同样少一次 VM 往返 |
| 隧道加解密（YunShu TUN） | 不变（今天已经在 nspawn 容器里跑） |
| DNS 正常态 | 不变 |
| DNS 降级态 | 慢一跳（side 转发 53 到 dnsmasq 容器），仅在 main 失效时生效 |
| VRRP 心跳 / GARP | 可忽略（1 包/秒） |

#### 资源占用：省的是"预留"，不是"日常占用"

| | router VM | yunshu 容器 |
|---|---|---|
| anon 内存（不可回收） | 257 MB | 62 MB |
| file（页缓存，可回收） | 328 MB | 87 MB |
| kernel | 3 MB | 10 MB |
| 累计 CPU（5.7 天） | 2365 s ≈ 0.48% 单核 | 4290 s ≈ 0.87% 单核 |
| 磁盘 | `/var/lib/router-vm` **1.1 GB** | 0（closure 与宿主共享 nix store） |

**CPU：净赚一个核。** `/proc/cmdline` 里有 `isolcpus=0`——整整 25% 的机器被划给
VM 的 vcpu0，宿主调度器不用它，而 VM 实际只吃 0.48% 单核。新方案没有 isolcpus，
4 个核全部回到共享池；网关容器合计才消耗 1.35% 单核。

**内存：大致持平，性质不同。** VM 那 257 MB anon 里装着 tailscale×2 + cloudflared
+ dnsmasq + NAT/keepalived + 一整个 guest 内核；拆成多个容器后每份都要付一份
systemd 与网络栈，新增总量粗估 150~200 MB。净省的是 guest 内核（约 30~60 MB）。

真正的差别在性质：

- VM 的 256 MB 是**硬预留**（`mem = 256` 且 `initialBalloonMem = 0`，宿主侧回收
  未实现），实测 anon 正好顶到上限，与负载无关；
- 容器是**按需**，空闲时几乎不占，NAS 需要内存时可以借用。

⚠️ 代价是反向风险：**容器默认没有内存上限**，YunShu 一旦内存泄漏会直接压到宿主，
OOM 时连累 NAS 服务。必须给容器配 `MemoryMax` / `MemoryHigh`——这是新方案要主动
补、而 VM 天然具备的东西。

**磁盘：净省 1.1 GB。** `/var/lib/router-vm` 由 **5 份 206 MB 的 rootfs 副本**
（对应 5 次镜像更新）+ 64 MB state 盘构成。`vm-service.nix` 按内容哈希命名副本，
清理逻辑只删 `.tmp.*` 残留、**从不删旧哈希**——每 `nix flake update` 一次就永久
多 206 MB。新方案没有 qcow2 副本、没有 state 盘（换成 bindMount 目录，实际内容
只有几百 KB），镜像的 CI 构建/发布/sha256 同步链路也一并消失。

#### 可能变慢的三处

1. **CPU 隔离消失**（唯一需要主动应对的）。`isolcpus` 那个独占核回到共享池：
   NAS 多一个核可用，但旁路服务与降级路径少了一个保底核。N5095 只有 4 核，
   下载与 NFS 大文件传输同时跑时，网关的软中断与隧道加解密会排队。
   应对：给网关容器配 CPU 资源控制（`AllowedCPUs` / `CPUWeight`），默认不会有。
   注意这条**对今天的热路径本来就不成立**——yunshu 容器今天已经在共享核上跑。
2. **generic XDP**：native XDP 每包一次程序执行，开销可忽略；但 generic XDP 是在
   skb 路径上额外分配 + 拷贝，2.5G 线速下会明显掉速。r8169/RTL8125 的 native XDP
   支持有限——**先确认驱动支持的模式，再决定做不做**（§14）。
3. **macvlan 单 TX 队列**：macvlan 子接口默认单队列（`IFF_NO_QUEUE`），物理口的
   RSS 多队列用不上。单核跑隧道加密时无所谓；若将来要上多核转发，
   veth（`numtxqueues`）+ bridge 更好扩展。当前不是问题。

#### 顺带的优化

方案里列了 6 个容器，其中 **tailscale 与 headscale 可以合成一个**——现在的
router VM 就是这么干的（两个实例、两个接口 ts0/tailscale0、两份 state 目录，
互不冲突）。少一个 systemd、少一份网络栈，能把内存开销压回去一点。

## 5. 宿主机 NixOS 配置方向

```nix
{ config, pkgs, lib, ... }:

{
  # 1. 禁用宿主机内核转发与 bridge netfilter
  # 注意：本设计不建 bridge，br_netfilter 正常不会被加载。blacklistedKernelModules
  # 只拦 modprobe 且需重启才生效；若 WAN 侧回退 veth+bridge（见 §15），该黑名单
  # 形同虚设，应改为关闭 bridge 流量进 netfilter 的钩子：
  #   "net.bridge.bridge-nf-call-iptables" = 0;（ip6tables/arptables 同理）
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 0;
    "net.ipv6.conf.all.forwarding" = 0;
  };
  boot.blacklistedKernelModules = [ "br_netfilter" ];

  # 2. 物理网卡保持纯二层，禁用 DHCP 与静态 IP
  networking = {
    useDHCP = false;
    interfaces.enp2s0.useDHCP = false;
    interfaces.enp3s0.useDHCP = false;
  };

  # 3. 物理网卡保持 UP（macvlan 要求父接口存在且 UP；挂 macvlan 时内核会自行
  #    处理父接口混杂模式，这里显式设置只是幂等兜底，不是必需项）
  systemd.services.macvlan-physical-nics = {
    description = "Bring physical NICs up for macvlan containers";
    wantedBy = [ "network-pre.target" ];
    before = [ "network-pre.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "nics-promisc-up" ''
        ${pkgs.iproute2}/bin/ip link set enp2s0 up promisc on
        ${pkgs.iproute2}/bin/ip link set enp3s0 up promisc on
      '';
    };
  };

  # 4. 宿主机管理 shim，避免无 IP 无法 SSH
  systemd.services.macvlan-shim = {
    description = "Macvlan shim for host management";
    after = [ "macvlan-physical-nics.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "macvlan-shim-up" ''
        ${pkgs.iproute2}/bin/ip link add link enp3s0 name mv-shim type macvlan mode bridge
        ${pkgs.iproute2}/bin/ip addr add 192.168.10.250/32 dev mv-shim
        ${pkgs.iproute2}/bin/ip link set mv-shim up
        ${pkgs.iproute2}/bin/ip route add 192.168.10.0/24 dev mv-shim
        # 默认路由必须有：宿主机要出网做 nix flake update / sops 解密 / NTP 对时，
        # 命令式配 IP 时不会有任何东西替它补上。走 VIP 即与下游设备同一出口，
        # 网关随 VRRP 漂移；也可指 side-router 换取不受漂移影响的稳定出口。
        ${pkgs.iproute2}/bin/ip route add default via 192.168.10.1
      '';
      ExecStop = pkgs.writeShellScript "macvlan-shim-down" ''
        ${pkgs.iproute2}/bin/ip link del mv-shim 2>/dev/null || true
      '';
    };
  };

  # 宿主机不走 DHCP，DNS 必须显式配置，否则容器之外的解析全部失败
  networking.nameservers = [ "192.168.10.1" ];
}
```

## 6. 容器角色与网络

### 6.1 main-router

- LAN 侧：`eth0` 接 `enp3s0` macvlan，IP `192.168.10.2`。
- WAN 侧：`eth1` 接 `enp2s0` macvlan 或 veth+bridge，DHCP/静态。
- 开启 `net.ipv4.ip_forward=1`。
- 信任商业 main 自带策略路由。
- 运行 Keepalived，VRRP MASTER，持有 VIP `192.168.10.1`。
- 健康检查 `tun0`。

### 6.2 side-router

- LAN 侧：`eth0` 接 macvlan，IP `192.168.10.3`。
- WAN 侧：`eth1` 接 WAN，DHCP/静态。
- 开启 `net.ipv4.ip_forward=1`。
- 独立配置 NAT 和防火墙。
- 运行 Keepalived，VRRP BACKUP，优先级低于 main。
- 常驻 standby，不关闭。
- 接管 VIP 时额外承担一件事：把 53 交给 dnsmasq-container（§6.7），
  因为客户端 DNS 指向 VIP 而不是某个固定地址。

### 6.3 tailscale-container / headscale-container

- 仅 LAN 侧：`eth0` 接 macvlan，IP `192.168.10.4`/`192.168.10.5`。
- 默认网关指向 `192.168.10.3`，出站直连。
- 作为 Subnet Router 广告 `192.168.10.0/24`。
- 不参与 VRRP。

### 6.4 cloudflared-container

- 仅 LAN 侧：`eth0` 接 macvlan，IP `192.168.10.6`。
- 默认网关指向 `192.168.10.3`，出站直连。
- 隧道 ingress 指向 LAN 内网服务。
- 不参与 VRRP。

### 6.5 dnsmasq-container（DHCP + DNS 服务器）

- 仅 LAN 侧：`eth0` 接 macvlan，IP `192.168.10.7`。
- 默认网关指向 `192.168.10.3`，出站直连。
- 职责：**全网唯一的 DHCP 服务器** + **降级态 DNS 解析器**（§6.6、§6.7）。
- 常驻、不参与 VRRP。正常态它不参与 DNS 链路（分流由 main-router 的 YunShu 做），
  只在 VIP 漂到 side-router 时才被用到。
- 地址池与上游 DNS 写在 Nix 里（声明式）；**租约库必须持久化到宿主目录**（§13）。

> 早先的 AdGuard Home 方案已废弃：它无法既做客户端解析器又保住 fake-IP 分流
> （§11 有完整说明）。dnsmasq 一个进程同时覆盖 DHCP 与降级 DNS，反而更简单。

### 6.6 DHCP 归属：常驻 dnsmasq-container

DHCP **不随 VIP 漂移**，固定由 dnsmasq-container 提供。理由：

- 只有一份租约库，天然不会出现"两台服务器各自发地址、租约库分裂"；
- 不需要 keepalived `notify_*` 编排；
- DHCP 应答走广播，不需要持有 VIP —— 放在固定地址的容器上是它最自然的位置；
- main-router 是升级/重启最频繁的容器（跑 YunShu），DHCP 不该跟着它走。

代价：dnsmasq-container 重启期间**新设备拿不到地址**（已持有租约的设备不受影响，
继续经 VIP 上网）。接受。

容器内 dnsmasq 的配置要点：

```conf
dhcp-range=eth0,192.168.10.100,192.168.10.200,255.255.255.0,12h
dhcp-option=eth0,3,192.168.10.1      # 默认网关 = VIP
dhcp-option=eth0,6,192.168.10.1      # DNS = VIP（必须，分流靠它）
dhcp-option=eth0,28,192.168.10.0/24  # 广播地址
no-resolv                            # 上游用固定公网 DNS，不要读 /etc/resolv.conf
server=223.5.5.5
server=119.29.29.29
```

- **地址池必须排除基础设施地址**：`.1`(VIP)、`.2`(main)、`.3`(side)、`.7`(自己)、
  `.250`(宿主机)。池从 `.100` 起天然满足，但以后扩大池子时要记得。
- 反模式：`dhcp-option=6,192.168.10.7`（把 DNS 指向自己）。DNS 一旦绕开 VIP，
  YunShu 的 fake-IP 就不触发，域名级分流直接失效 —— 这正是 AdGuard 方案被废弃的原因。
  现有 `network.env` 用 `__LAN_GATEWAY__` 的写法是对的。
- `dhcp-authoritative` 建议开启：单服务器场景下能更快纠正客户端缓存的错误租约。

### 6.7 DNS 链路：客户端 → VIP →（按节点角色切换）

客户端 DNS 由 DHCP 下发为 **VIP**，因此 DNS 服务必须"谁持有 VIP 谁应答"。这正是
`yunshu-nix/docs/VRRP-DNS-Failover.md` 里已经确立的**双角色 DNS**，本设计沿用：

| VIP 所在节点 | DNS 由谁应答 | 效果 |
|---|---|---|
| main-router（MASTER） | YunShu 隧道 DNS（容器内 nftables 把 53 透明 DNAT 到隧道 DNS） | 分流：被墙域名 → fake-IP `198.18.0.0/15` → tun0 |
| side-router（BACKUP） | side 把 53 交给 dnsmasq-container（`.7`） | 降级：纯公网 DNS，无分流 |

要点：

- 降级态的 53 转发有两种做法，选一种即可：
  - **DNAT**（推荐）：side-router 内 nftables
    `iifname "eth0" udp dport 53 dnat to 192.168.10.7` （TCP 同理），
    conntrack 负责回包还原，客户端看到的应答仍来自 VIP。
  - side-router 自己跑一个 dnsmasq 实例（`bind-dynamic` 监听 VIP），
    上游 `server=192.168.10.7`。多一个解析器，但不用写转发规则。
- **绝不能写 `server=192.168.10.1`** —— 降级态下那是 side 自己，会形成回环。
- main-router 侧保持 `services.yunshu.dns.transparentRedirect = true`，
  不要另外对 LAN 暴露 53，全部走 DNAT。
- 降级态没有 fake-IP，客户端拿到真实 IP 直连可用 —— 与今天的降级行为一致。
- 转发规则依赖 side-router 的 forward 链放行 `eth0 → .7:53`，写防火墙时别漏。

## 7. VRRP 与 systemd 编排

### 7.1 VIP 规划

```text
VIP: 192.168.10.1/24
main-router.eth0    优先级 100，MASTER
side-router.eth0 优先级 90，BACKUP
```

### 7.2 Keepalived 健康检查

main-router 内：

```conf
global_defs {
    router_id vpn_gw
    enable_script_security
    script_user root
}

# 健康检查不要用 ping 探 tun0：很多商业 VPN 的 TUN 不转发 ICMP，隧道完全正常
# 也会判失败 → VIP 白漂到 side-router → 全内网流量改走直连。对这个项目来说
# "漂到直连"是降级（流量不再受商业 main 保护），不是等价切换，必须避免误判。
# 改用 TCP 探测；更准确的判据是客户端自身的连接状态（yunshu -i），接口存在 ≠ 已连接。
vrrp_script chk_tun {
    script "${pkgs.curl}/bin/curl -sf -o /dev/null --max-time 2 --interface tun0 http://www.gstatic.com/generate_204"
    interval 3
    weight -30
    fall 3
    rise 3
}

vrrp_instance VI_LAN {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 100
    advert_int 1
    garp_master_refresh 5
    garp_master_delay 1

    authentication {
        auth_type PASS
        auth_pass SecNetKey51
    }

    virtual_ipaddress {
        192.168.10.1/24 dev eth0
    }

    track_script {
        chk_tun
    }
}
```

side-router 内：

```conf
global_defs {
    router_id router_gw
}

vrrp_instance VI_LAN {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority 90
    advert_int 1
    nopreempt
    garp_master_refresh 5
    garp_master_delay 1

    authentication {
        auth_type PASS
        auth_pass SecNetKey51
    }

    virtual_ipaddress {
        192.168.10.1/24 dev eth0
    }
}
```

注意：

- macvlan 上建议禁用 `use_vmac`，避免 GARP 被内核 macvlan 代码吞掉。
- 必须验证 VRRP 多播和 GARP 在 macvlan bridge 模式下可正常收发。
- 如果多播不通，考虑 LAN 侧退回 veth+bridge。
- `auth_pass` 受 VRRPv2 认证字段 8 字节限制，超长会被截断（两侧截断后一致即可，
  不会报错）；且 PASS 认证是明文，不提供实际安全性——不必在这里放"像密钥"的值。
- 两个容器挂在同一父口上，互为 macvlan 兄弟，可以直接用 `unicast_peer` 显式指定
  对端地址，不必依赖 macvlan 内部软交换对 `224.0.0.18` 的组播复制行为。这比调通
  组播更容易验证，建议优先。
- side-router 侧也要有 track_script（自身 WAN 可达性）。否则 main 失效而 side 的 WAN
  也不通时，VIP 照样漂过去，结果是全网断——比不漂移更糟；应让它进 FAULT 态。

### 7.3 systemd 计划性维护编排

main-router 停止前：

- 先停止 main 内 keepalived，让 VIP 漂移到 side-router。
- 等待 side-router 接管。
- 再停止 main container。

main-router 启动后：

- 等 `tun0` 就绪。
- 再启动 main 内 keepalived。
- main 优先级恢复 100，抢回 VIP。

示例方向：

```nix
systemd.services.main-router = {
  after = [ "network-online.target" "macvlan-physical-nics.service" ];
  wants = [ "network-online.target" ];
  serviceConfig = {
    ExecStopPre = pkgs.writeShellScript "main-pre-stop" ''
      ${pkgs.nixos-container}/bin/nixos-container run main -- \
        systemctl stop keepalived 2>/dev/null || true
      # 等 VIP 漂到 side-router：要查的是 side 容器里的 macvlan 口。
      # 不能查宿主机的 mv-shim —— 那上面只有自己的 .250，永远看不到 VIP。
      for i in $(seq 1 20); do
        ${pkgs.nixos-container}/bin/nixos-container run side -- \
          ip -4 addr show eth0 2>/dev/null | grep -q "192.168.10.1" && exit 0
        sleep 0.5
      done
      echo "VIP 未在 10s 内漂移到 side-router" >&2
    '';
    ExecStartPost = pkgs.writeShellScript "main-post-start" ''
      # 判据与 keepalived 健康检查保持一致：tun0 接口存在 ≠ 已登录已连接
      # （headless 版断连时 tun0 仍在）。yunshu -i 的输出串以实际版本为准。
      tunnel_up() {
        ${pkgs.nixos-container}/bin/nixos-container run main -- \
          yunshu -i 2>/dev/null | grep -q "已连接"
      }
      for i in $(seq 1 60); do tunnel_up && break; sleep 1; done
      # 隧道没就绪就不启动 keepalived：抢回一个上不了网的网关，
      # 比让 side-router 继续直连待命更糟（priority 100 会无条件抢走 VIP）。
      tunnel_up && ${pkgs.nixos-container}/bin/nixos-container run main -- \
        systemctl start keepalived
    '';
  };
};
```

### 7.4 失败域与切换语义

本方案是**容器级冗余 + 维护窗口零中断**，不是宿主机级高可用。必须写明，否则会
在下一次断电时按"高可用失效"去排查：

| 故障 | 是否覆盖 | 说明 |
|---|---|---|
| YunShu 进程崩溃 / 隧道断开 | ✅ | 健康检查降权 → VIP 漂到 side-router |
| main-router 容器重启 / 升级 | ✅ | §7.3 的编排保证先让出 VIP 再停容器 |
| side-router 容器重启 | ✅ | VIP 立刻让给 main，已建立的连接断开 |
| dnsmasq-container 重启 | ✅ | 新设备暂时拿不到地址；已持有租约的设备不受影响。正常态分流不受影响 |
| **宿主机宕机 / 断电 / 内核 panic / 网卡故障** | ❌ | **两个路由器容器都在这台机器上，一起消失** |
| 上游光猫 / 上级路由故障 | ❌ | 不在本文范围 |

要覆盖宿主机故障只有两条路：把 side-router 挪到独立硬件（手上有 NanoPi R3S），
或明确接受"NAS 挂了全网断"。

切换语义：

- 漂移 = **所有已建立的连接断开**（两个网关的 conntrack 不同步）。不要上
  conntrackd 做会话同步，家庭场景不划算；按"漂移即断流"设计并验收。
- 漂移方向是"从分流降到直连"，对依赖代理的场景是**降级不是等价切换** ——
  所以 §7.2 的健康检查绝不能误判（ICMP 探测会把健康的隧道判死）。
- 漂移是静默的（内网只是"变得不走代理了"），建议加告警。

## 8. main 容器与策略路由

main 容器职责：

- 作为主透明网关。
- 开启 `net.ipv4.ip_forward=1`。
- 信任商业 main 工具自带策略路由。
- 不要手动覆盖工具的 `eth0 -> tun0` 规则。
- 如果工具没有做 NAT，可补：

```bash
nft add rule ip nat postrouting oifname tun0 masquerade
nft add rule ip nat postrouting oifname eth1 masquerade
```

流量路径：

```text
下游 -> VIP -> main-router.eth0 -> main 工具策略路由
                                  ├─ 代理流量 -> tun0
                                  └─ 直连流量 -> eth1
```

## 9. Tailscale 容器

职责：

- 独立容器，LAN 侧 macvlan。
- 出站走默认网关 `192.168.10.3` 直连，不经过商业 main。
- 作为 Subnet Router 广告 LAN 网段。

NixOS 配置方向：

```nix
containers.tailscale = {
  autoStart = true;
  privateNetwork = true;
  macvlans = [ "enp3s0" ];
  bindMounts."/var/lib/tailscale" = {
    hostPath = "/srv/data/tailscale";
    isReadOnly = false;
  };
  extraFlags = [
    "--load-credential=tailscale-auth-key:${config.sops.secrets.tailscale-auth-key.path}"
  ];
  config = { pkgs, ... }: {
    services.tailscale = {
      enable = true;
      useRoutingFeatures = "server";
      authKeyFile = "/run/credentials/@system/tailscale-auth-key";
      extraUpFlags = [
        "--advertise-routes=192.168.10.0/24"
        "--snat-subnet-routes=true"
      ];
    };
  };
};
```

步骤：

1. 容器内开启 Tailscale，广告 LAN 网段。
2. 在 Tailscale 管理后台批准 subnet route。
3. 远程客户端执行：

```bash
sudo tailscale set --accept-routes
```

建议：

- 保持 `--snat-subnet-routes=true`。
- 不要让 Tailscale 默认路由指向 main-router。
- 如果确实要让部分流量走 main，用策略路由做选择性分流。

## 10. Cloudflared 容器

职责：

- 独立容器，LAN 侧 macvlan。
- 出站走默认网关 `192.168.10.3` 直连。
- ingress 指向 LAN 内网服务。

示例：

```yaml
tunnel: <tunnel-id>
credentials-file: /etc/cloudflared/<tunnel-id>.json
ingress:
  - hostname: app.example.com
    service: http://192.168.10.10:8080
  - service: http_status:404
```

密钥注入：

```nix
containers.cloudflared = {
  autoStart = true;
  privateNetwork = true;
  macvlans = [ "enp3s0:eth0" ];
  # 不要 bindMount /etc/cloudflared：它是宿主持久目录，任何写进去的
  # token 都会明文落盘，直接违反 §12 的"密钥不落盘"。
  extraFlags = [
    "--load-credential=cf-token:${config.sops.secrets.cloudflare-token.path}"
  ];
  config = { pkgs, ... }: {
    # NixOS 的 cloudflared 模块原生就把 credentialsFile 作为 systemd credential
    # 交给服务（生成配置里的 credentials-file 直接指向
    # /run/credentials/cloudflared-tunnel-<n>.service/credentials.json），
    # 不需要 preStart 拷贝那一步。
    services.cloudflared = {
      enable = true;
      tunnels."<tunnel-id>" = {
        credentialsFile = "/run/credentials/@system/cf-token";
        default = "http_status:404";
        ingress."app.example.com" = "http://192.168.10.10:8080";
      };
    };
  };
};
```

注意：`--load-credential` 注入的是容器内 PID 1 的凭据，服务再通过
`LoadCredential=<id>:/run/credentials/@system/<id>`（或 `ImportCredential`）取用；
模板里的 `credentialsFile` 正是这条路径。宿主机侧 sops 轮换密钥后，凭据只在容器
重启时才更新——而 rebuild 不改变容器定义时 systemd 不会重启它，需要显式 restart。

## 11. dnsmasq 容器（DHCP + DNS 服务器）

> **本方案曾计划用 AdGuard Home 做全网 DNS，已废弃。** 原因见 §6.6/§6.7：
> 客户端 DNS 必须指向 VIP 才能触发 YunShu 的 fake-IP 分流，而 AdGuard 作为
> 客户端解析器会让 DNS 绕开网关，域名级分流退化为按 IP 匹配。顺带一提，
> 想在链路里插广告过滤也走不通——`services.yunshu.dns` 只暴露
> `listen`/`port`/`transparentRedirect`，**没有上游配置项**，隧道内被墙域名的
> 解析结果由厂商决定，插不进第三方解析器。过滤只能对明确不走代理的设备
> （NAS 自身、IoT）用 `dhcp-host` 打标签单独下发，成本高于收益，暂不做。

职责收敛成两件事，一个 dnsmasq 进程全包：

1. **DHCP 服务器**（全网唯一，常驻，不随 VIP 漂移）—— §6.6
2. **降级态 DNS 解析器**（VIP 漂到 side-router 时被转发到它）—— §6.7

```nix
containers.dnsmasq = {
  autoStart = true;
  privateNetwork = true;
  macvlans = [ "enp3s0:eth0" ];       # 容器内接口名 eth0（见 §3 注）
  bindMounts = {
    # 租约库必须持久化：容器重建后 DHCP 不能把已发出的地址再发一遍
    "/var/lib/misc" = {
      hostPath = "/srv/data/dnsmasq";
      isReadOnly = false;
    };
  };
  config = { pkgs, ... }: {
    # 静态 IP + 默认网关（出站直连，走 side-router）
    networking = {
      interfaces.eth0.ipv4.addresses = [
        { address = "192.168.10.7"; prefixLength = 24; }
      ];
      defaultGateway = "192.168.10.3";
      nameservers = [ "223.5.5.5" "119.29.29.29" ];
    };

    services.dnsmasq = {
      enable = true;
      settings = {
        interface = "eth0";
        bind-dynamic = true;          # 见 §6.7：需要能应答转发过来的 53
        dhcp-authoritative = true;
        dhcp-range = [ "eth0,192.168.10.100,192.168.10.200,255.255.255.0,12h" ];
        dhcp-option = [
          "eth0,3,192.168.10.1"       # 默认网关 = VIP
          "eth0,6,192.168.10.1"       # DNS = VIP，绝不能写成自己的 .7
          "eth0,28,192.168.10.0/24"
        ];
        no-resolv = true;
        server = [ "223.5.5.5" "119.29.29.29" ];
      };
    };
  };
};
```

要点：

- **`dhcp-option` 的 3 和 6 都是 VIP**，这是整条分流链路的起点，写错等于放弃代理。
- **租约文件必须落宿主持久目录**。容器用 `bindMounts` 把 `/var/lib/misc`
  （dnsmasq 默认的租约目录）挂到 `/srv/data/dnsmasq`；否则容器一重建，
  dnsmasq 忘了发过哪些地址，会和还活着的客户端撞 IP。
- `bind-dynamic` 而不是 `bind-interfaces`：前者能跟随接口/地址变化，
  以后调整网络不需要重启服务。
- 容器只需要一个 LAN 口，它的上游（公网 DNS）经 side-router 出去，与 VIP 无关，
  所以它不参与 VRRP 也不影响分流。

## 12. 密钥管理：sops-nix + LoadCredential

推荐流程：

1. 宿主机用 sops-nix 解密密钥到 `/run/secrets/`。
2. systemd-nspawn 用 `--load-credential=ID:PATH` 将宿主机文件注入容器。
3. 容器内服务从 `/run/credentials/@system/ID` 读取。
4. 密钥仅存在于内存，不落盘。

示例：

```nix
sops.secrets."tailscale-auth-key" = {
  sopsFile = ../secrets/tailscale.yaml;
};

containers.tailscale = {
  extraFlags = [
    "--load-credential=tailscale-auth-key:${config.sops.secrets.tailscale-auth-key.path}"
  ];
  config = {
    services.tailscale = {
      authKeyFile = "/run/credentials/@system/tailscale-auth-key";
    };
  };
};
```

注意：

- 不要用 `bindMounts` 挂载 sops-nix 的符号链接密钥文件到 `privateUsers` 容器，可能因 idmapping 失败。
- 优先使用 `LoadCredential`。
- 每个容器使用独立密钥条目。

## 13. 状态持久化：bindMounts

Tailscale：

```nix
containers.tailscale = {
  bindMounts."/var/lib/tailscale" = {
    hostPath = "/srv/data/tailscale";
    isReadOnly = false;
  };
};
```

Cloudflared：

```nix
containers.cloudflared = {
  bindMounts."/etc/cloudflared" = {
    hostPath = "/srv/data/cloudflared";
    isReadOnly = false;
  };
};
```

dnsmasq（DHCP 租约库）：

```nix
containers.dnsmasq = {
  bindMounts."/var/lib/misc" = {
    hostPath = "/srv/data/dnsmasq";
    isReadOnly = false;
  };
};
```

必须持久化的理由和别处不同：**租约库丢了不是"配置丢失"，是会把已经发出去的地址
再发一遍**，直接把冲突的设备怼下线。容器用 `nixos-container update` 重建时尤其容易
踩到。

注意：

- 如果启用 `privateUsers`，宿主机目录属主 UID 需要与容器内用户 UID 映射一致。
- 否则容器内可能显示为 `nobody`，导致权限错误。
- 简单场景可以关闭 `privateUsers`，降低权限管理复杂度。

## 14. 防火墙：eBPF/XDP + 容器内 nftables

宿主机纯二层，关闭 `br_netfilter` 后，nftables 看不到 bridge 转发流量。因此：

- 宿主机 eBPF/XDP 做第一道粗粒度防线。
- 容器内 nftables 做第二道细粒度防线。

挂载点：

```text
enp2s0 / enp3s0      -> XDP（native 优先；驱动不支持时退 generic，语义/性能都打折）
br-*、宿主机侧 veth  -> 仅当 WAN 侧回退 veth+bridge（§15）时才存在，
                        eBPF 挂 TC ingress + egress
```

适合 eBPF/XDP 的规则（**均为入向**）：

- DDoS 缓解：SYN flood、UDP flood、ICMP flood、异常分片。
- IP/CIDR 黑名单。
- 速率限制：按源 IP 限 PPS/BPS。
- 畸形包丢弃。
- 端口白名单。

不适合 XDP 的：

- **出向策略**：XDP 是收包路径的钩子，"禁止 tun0 未就绪时 WAN 发包"这类出站防泄漏
  挂 XDP 上做不到，要用 TC egress eBPF 或放进容器内 nftables。
- 复杂 conntrack。
- NAT。
- TLS SNI / HTTP 层过滤。
- 依赖 socket / cgroup 的策略。

两个必须记住的边界：

- **macvlan 兄弟之间的流量 XDP 看不见**。容器 ↔ 容器、容器 ↔ 宿主机 shim 的帧走内核
  内部软交换，不经过物理口。第一道防线只覆盖"从线上进来的"。
- **落地方式本文没有给出**。NixOS 里声明式部署 XDP 需要自写程序 + systemd 加载，或
  直接用现成的 `xdp-filter`/`xdp-tools`；TS-564 的网卡驱动（RTL8125/r8169）是否支持
  native XDP 也要先确认。建议这一层排到最后做。

容器内 nftables 注意：

- 不要写无条件 `iif eth0 oif tun0 accept`，否则会覆盖商业 main 的策略路由。
- 让 main 工具管理转发规则，nftables 只做兜底 drop 或基于 connmark 的规则。
- 典型兜底：

```nft
table inet filter {
    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
        iif "eth0" oif "tun0" accept
        iif "eth0" oif "eth1" ip daddr <VPN_SERVER_IP> accept
    }
}
```

但若商业 main 已处理策略路由，建议只保留 `ct state established,related accept` 和最终 `drop`。

## 15. WAN 侧选择：macvlan vs veth+bridge

### 15.1 为什么 WAN 侧 macvlan 有风险

- Podman/Netavark 的 macvlan 对 DHCP 支持有限。
- 上游 DHCP 可能按 MAC 绑定，只允许一个客户端。
- 交换机端口安全可能限制多 MAC。
- PPPoE 通常与物理接口 MAC 强绑定，macvlan 可能导致拨号失败。

### 15.2 推荐策略

- **LAN 侧**：使用 macvlan bridge 模式，减少 veth，性能更好。
- **WAN 侧**：
  - 若上游允许多 MAC 多 DHCP，可用 macvlan + 容器内 DHCP。
  - 若上游只允许单 MAC，或使用 PPPoE，建议退回 veth + bridge。
  - 也可以只让主网关 DHCP，备网关静态或按需启用。

WAN 侧是本方案唯一必须**上线前实测**的环节，因为 §7.4 选定的"同机双容器"意味着
WAN 口上会出现**两个 DHCP 客户端**（现状只有一个 router VM 在 WAN 侧 DHCP）：

1. **先固定 MAC**。nspawn 每次创建 macvlan 都会生成随机 MAC，直接后果是上游租约
   每次都变、按 MAC 绑定的上游直接失败。必须在容器内用 networkd 显式固定
   （`yunshu-nix` 的 `macAddress` 选项就是干这个的，`systemd.network` 里设
   `linkConfig.MACAddress`），两个容器各用一个固定且不重复的 MAC。
2. **实测上游给几个租约**：起一个 macvlan 容器发 DHCP，看光猫/上级路由是否给
   第二个地址、是否按 MAC 绑定。给 → 两个容器各自持有一个 WAN IP，切换零延迟；
   不给 → 退回下面的串行方案。
3. **串行方案**（上游只允许单客户端时）：只有持 VIP 的节点在 WAN 侧活跃，
   用 keepalived `notify_master` / `notify_backup` 启停 WAN 侧 DHCP 客户端。
   代价是接管时多 1~2 秒 DHCP 往返。
4. PPPoE 与 MAC 强绑定，**不要**用 macvlan 试（`network.env` 目前是 `WAN_MODE=dhcp`，
   暂无此问题）。

### 15.3 宿主机管理通道

宿主机无 IP 时无法 SSH。建议：

- 加一个 macvlan shim 接口，例如 `192.168.10.250/32`。
- 或使用独立管理 VLAN/接口。

## 16. 从 MicroVM 迁移注意事项

迁移的收益（性能与资源实测）见 §4.1；本节只讲"怎么迁、别踩什么"。

原先：

- Tailscale/Cloudflared 在 cloud-hypervisor MicroVM 中。
- 密钥解密到 `/run/secret` 后注入 VM 的 `/etc/`。
- Tailscale 状态持久化到 `state.raw` 磁盘，VM 挂载该磁盘。

迁移到 systemd-nspawn 后：

1. **密钥注入**
   - 保留 sops-nix 在宿主机解密。
   - 用 `--load-credential` 注入容器。
   - 容器内从 `/run/credentials/@system/` 读取。
   - 不再需要“注入 VM 配置文件”的脚本。

2. **状态持久化**
   - 用 `bindMounts` 将宿主机目录挂载到容器内状态目录。
   - Tailscale：`/var/lib/tailscale`。
   - Cloudflared：`/etc/cloudflared` 或凭据目录。
   - dnsmasq：`/var/lib/misc`（租约库，必须持久化，见 §13）。

3. **权限**
   - 注意 UID/GID 映射。
   - 若使用 `privateUsers`，宿主机目录属主需匹配容器内 UID。
   - 简化方案可关闭 `privateUsers`。

4. **网络**
   - MicroVM 需要 TAP/virtio，容器用 macvlan/veth。
   - 容器网络更轻量，但多 MAC 兼容性需要验证。

5. **router-image（Alpine/Gentoo 路由 VM）的去留**
   - 本设计把它的全部职责（WAN 拨号/NAT、LAN DHCP/DNS、Tailscale×2、Cloudflared、
     keepalived BACKUP）拆到了 main-router / side-router / 四个旁路容器里，
     结论上应当**整体退役**（`services.router-vm.enable = false`）。
   - 但本文没给出退役与切换的顺序。过渡期若两者并存，会同时出现：两个 VRRP 域
     （旧 vrid=10 持 `.254`、新 vrid=51 持 `.1`）、**两个 DHCP 服务器**
     （分别下发 `.254` 和 `.1`，谁先应答谁生效）、两个 tailscale subnet router
     （广告同一网段）。**不要让两者并行超过一个维护窗口。**
   - 退役前确认新链路验收通过，且密钥已从 `/etc/libvirt/alpine-router.env`
     的注入通道迁到 sops + `--load-credential`。

## 17. 验证与排障

1. 重建并生效：

```bash
nixos-rebuild switch
systemctl daemon-reload
```

2. 检查物理网卡与接口命名：

```bash
ip link
# 确认 enp2s0 / enp3s0 存在且 UP（混杂模式由内核挂 macvlan 时自动处理）
# 确认没有多余 veth 或 br-*（纯 macvlan 方案下不该有）
nixos-container run main -- ip -br link
# 确认容器内接口叫 eth0（即 macvlans 写的是 "enp3s0:eth0"），不是 mv-enp3s0
```

3. 检查 VIP：

```bash
nixos-container run main -- ip addr show eth0
# 确认 192.168.10.1 在 main 容器上
```

4. 漂移测试：

```bash
systemctl stop main-router
# 下游 ping 192.168.10.1，观察丢包
nixos-container run side -- ip addr show eth0
# 确认 side-router 已接管 VIP
```

同时挂一条长连接（大文件传输 / 下载任务）再断：两个网关的 conntrack 不同步，
VIP 漂移必然切断所有已建立的会话。这是本设计的既定语义，要确认能接受，
而不是当故障去修（上 conntrackd 做会话同步的复杂度不划算）。

5. 检查 Tailscale：

```bash
nixos-container run tailscale -- tailscale status
# 确认 subnet route 已广告
```

6. 检查 VRRP：

```bash
nixos-container run main -- tcpdump -i eth0 vrrp -n
nixos-container run side -- tcpdump -i eth0 vrrp -n
# 若改用 unicast_peer，这里应看到的是单播的心跳，而不是 224.0.0.18
```

7. 检查 GARP：

```bash
nixos-container run main -- tcpdump -i eth0 arp -n
```

8. 检查密钥：

```bash
nixos-container run tailscale -- ls -l /run/credentials/@system/
```

9. 检查宿主机自身出口（宿主机无 DHCP，默认路由和 DNS 都要显式配）：

```bash
ip route                      # 应有 default via <VIP>（或 via side-router）
cat /etc/resolv.conf          # 不应是空的
curl -sfI https://cache.nixos.org | head -1   # 宿主机能出网
```

10. 检查 DHCP 与降级 DNS（整条链路里最容易"看着正常其实已失效"的一段）：

```bash
# 租约里下发的网关与 DNS 必须都是 VIP，不是 .7
nixos-container run dnsmasq -- cat /var/lib/misc/dnsmasq.leases
# 抓一次 DHCP 应答，确认 option 3 / option 6
nixos-container run dnsmasq -- tcpdump -i eth0 -nvv port 67 or port 68

# 模拟降级：停掉 main 后，客户端 DNS 仍应能解析（side 把 53 转给 .7）
systemctl stop main-router
nixos-container run side -- nft list ruleset | grep 53   # 转发规则在不在
dig @192.168.10.1 www.baidu.com +short                   # 应返回真实 IP
```

> 测 DNS 前先 `systemctl stop nscd`：宿主机和容器都在跑 nscd，`getent`/`curl`
> 的解析会走 nscd 的 socket（由 nscd 在宿主命名空间里查），绕开容器 netns，
> 容易得出"分流生效"的假象。

## 18. 最终结论

- 本项目最适合 **NixOS 原生 systemd-nspawn 容器**，而不是 Quadlet/OCI。
- **不是单纯的成本转移**：相比现状，新方案在主转发路径上少一次 VM 往返和一次
  NAT，净省一个 CPU 核（`isolcpus`）和 1.1 GB 磁盘；内存大致持平，但改为按需
  分配，代价是必须自己补 `MemoryMax`。实测数据见 §4.1。
- 宿主机"纯二层"的准确含义是**不做转发**，不是"没有三层"——它必须有 shim 地址、
  默认路由和 DNS，否则 `nix flake update` 都做不了（§5）。
- LAN 侧优先 macvlan bridge；WAN 侧必须先实测上游是否接受第二个 DHCP 客户端，
  并固定容器 MAC（§15.2）。容器内接口名要么写 `macvlans = [ "enp3s0:eth0" ]`，
  要么就把全文的 `eth0` 改成 `mv-enp3s0`。
- `main-router` 主网关（VRRP MASTER，持 VIP，跑分流），`side-router` 备份直连网关
  （BACKUP，常驻，**兼 DHCP 服务器**）。
- **客户端的默认网关和 DNS 都指 VIP**：VIP 在 main 时分流，漂到 side 时由
  `bind-dynamic` 的 dnsmasq 兜底（双角色 DNS，§6.7）。DNS 一旦独立出去，
  域名级分流就没了 —— 这是本设计最容易被"顺手优化"毁掉的地方。
- DHCP 与降级态 DNS 由常驻的 `dnsmasq-container` 统一提供，不参与 VRRP；
  正常态的 DNS 仍由 main-router 的 YunShu 在 VIP 上接管（§6.6、§6.7、§11）。
- Tailscale、Cloudflared 独立旁路容器，出站直连，不参与 VRRP；注意它们的默认网关
  写死在 side-router 上，等于最需要常驻的服务依赖了最可牺牲的节点（§6.3、§6.4）。
- 密钥用 sops-nix + `--load-credential`，状态用 `bindMounts`；**不要把凭据写进
  bindMount 的宿主目录**（§10）。
- 防火墙分两层：宿主机 eBPF/XDP 粗粒度（**仅入向**，且看不到容器间流量），
  容器内 nftables 细粒度。XDP 这一层的落地方式和网卡支持都要先确认，建议排最后。
- 不要写死 `eth0 -> tun0` 转发规则，信任商业 main 自带策略路由。
- **这不是宿主机级高可用**：两个网关容器都在同一台 NAS 上，失败域见 §7.4。
- 如果未来需要大量第三方 OCI 镜像，再考虑 Quadlet；当前固定服务场景下，systemd-nspawn 维护成本最低。



# Macvlan 环境下 VRRP 组播与 GARP 穿透机制深度解析

---

## 1. 结论

**VRRP 组播与免费 ARP（GARP）完全可以穿透 Macvlan**，但必须依赖特定的工作模式与内核配置：

* **主备心跳（VRRP 组播）**：仅在 `macvlan bridge` 模式下生效。同一物理父接口下的各子接口之间能互相复制组播与广播包，避免双主脑裂。
* **VIP 漂移生效（GARP 广播）**：可无阻碍穿透物理母网卡送达外部物理交换机与 AP，实时刷新下游客户端与交换机的 ARP 表项。
* **致命红线**：在 Macvlan 模式下运行 Keepalived 时，**严禁启用 VMAC（`use_vmac`）**，且物理网卡必须开启**混杂模式（Promiscuous Mode）**。

---

## 2. 二层底层穿透机制与原理

### 2.1 VRRP 组播心跳穿透（容器 ⟷ 容器）

* **协议特征**：VRRP 心跳包默认发送至组播地址 `224.0.0.18`，目标 MAC 为 `01:00:5e:00:00:12`。
* **工作模式依赖**：
  * **必须使用 `mode bridge`**：Linux 内核会在共享同一物理父设备（如 `enp3s0`）的所有 macvlan 子接口之间构建一个内部二层软交换模块。任何子接口发出的组播或广播帧，内核都会直接将其拷贝并分发给同网卡下的其他 macvlan 容器。
  * **禁止使用其他模式**：
    * `mode private`：子接口之间完全隔离，组播无法互通，导致 Keepalived 瞬间双主脑裂。
    * `mode vepa`：组播帧强制打向外部物理交换机，若交换机不支持 Hairpin 反射模式，对端容器将无法收到心跳。

### 2.2 GARP 广播穿透（容器 ⟷ 外部下游网络）

* **协议特征**：VIP 发生漂移时，新接管的 MASTER 节点会向二层网络广播 ARP 响应包，目标 MAC 为 `ff:ff:ff:ff:ff:ff`。
* **穿透逻辑**：
  * Macvlan 驱动会自动将容器内部接口发出的二层广播帧推向物理母口 `enp3s0`。
  * 外部物理交换机与无线 AP 接收到该广播后，会立即更新自身的 CAM/FDB（MAC 转发表）。
  * 下游 PC、手机等终端设备接收到广播后，刷新本地 ARP 缓存表，将 VIP 对应的 MAC 指向新节点。

---

## 3. Macvlan 下 VRRP 的关键配置陷阱与解决方案

### 3.1 陷阱一：开启 `use_vmac` 引发丢包与静默失效（核心痛点）

* **原因分析**：
  * Keepalived 默认或推荐的 `use_vmac` 机制会为 VIP 创建类似 `vrrp.51` 的虚拟接口，并使用虚拟 MAC 地址（如 `00:00:5e:00:01:33`）。
  * 但 Macvlan 子接口在内核注册时，已经独占绑定了一个特定 MAC。
  * 若容器在固定的 macvlan 接口上强行发出源 MAC 为 VMAC 的数据包，物理网卡驱动或宿主机内核过滤机制往往会判定该帧为非法源地址并直接将其丢弃。
* **避坑配置**：
  * 强制禁用 VMAC，全程使用容器 macvlan 接口的**真实物理级 MAC**。
  * 显式开启免费 ARP 周期性广播刷新。

```conf
# Keepalived 正确配置示例 (严禁添加 use_vmac)
vrrp_instance VI_LAN {
    state MASTER
    interface eth0               # 容器内 macvlan 接口名（由 macvlans = ["enp3s0:eth0"] 指定）
    virtual_router_id 51
    priority 100
    advert_int 1

    # 关键：强制依赖真实 MAC 定期广播刷新下游交换机与客户端
    garp_master_refresh 5
    garp_master_delay 1

    virtual_ipaddress {
        192.168.10.1/24 dev eth0
    }
}
```

---

## 附录 A：编址迁移清单

正文采用新编址，与当前运行的部署冲突。这次重编**必须单独立项、与网关改造解耦**，
否则出问题时无法分辨是网关逻辑还是编址变更引起的。

### A.1 编址对照

| 角色 | 旧（当前运行） | 新（本文） |
|---|---|---|
| VIP / 下游默认网关 | `192.168.10.254` | `192.168.10.1` |
| 宿主机 | `192.168.10.2` | `192.168.10.250`（macvlan shim） |
| main-router | —（新增） | `192.168.10.2` |
| side-router | —（新增） | `192.168.10.3`（现被 yunshu 容器占用） |
| dnsmasq-container | —（新增） | `192.168.10.7`（DHCP + 降级态 DNS） |
| 路由 VM | `192.168.10.1`（LAN_IP） | 退役（§16.5） |

### A.2 必须同步修改的位置

`qnap-nixos-nas`：

- `modules/network/bridges.nix` —— 宿主机地址/网关/DNS（`.2` → `.250`，网关
  `.254` → `.1`）；若同时切 macvlan，接口名一并改。
- `modules/network/default.nix` —— **防火墙整张 `interfaces.br-lan` 端口表**。
  宿主机换到 macvlan shim 后接口名不再是 `br-lan`，这张表不改 =
  Samba / NFS / Syncthing / WebDAV / Glance / Navidrome / qBittorrent / OpenList
  全部被挡。
- 服务绑定地址：`samba.nix`(hosts allow)、`nfs.nix`(exports)、`syncthing.nix`
  (guiAddress)、`webdav.nix`、`glance.nix`、`music.nix`。
- `modules/security/ssh.nix` 的 `Match Address`。
- `modules/services/yunshu.nix` 的 `lanAddress` / `upstreamGateway`。

`yunshu-nix`：

- `container.gateway.floatIp`（默认 `192.168.10.254`）、`lanAddress`、
  `upstreamGateway`；`vrrpId` 若与旧 VM 并存要避让。

`router-image`：

- `network.env` 的 `LAN_IP` / `LAN_GATEWAY` / `TS_ADVERTISE_ROUTES`（仅当该 VM
  保留时）。

配置之外：

- **cloudflared 隧道的 ingress 回源地址**（现在指向 `192.168.10.2:4918` 一类）。
- 下游静态配置的设备（AP、打印机、交换机管理地址）与任何 `known_hosts`、书签。
- 工作站已挂载的 NFS（`nfsvers=4.2`）。
- DHCP 租约：option 3/6 改完后客户端要续租或重连才生效，`12h` 租期意味着最坏
  要等半天。

### A.3 顺序建议

1. 先让 main/side 容器按新地址起好（`.2` / `.3` / VIP `.1`），与旧网关并存 ——
   此时新旧 VIP 各持一个，互不干扰（vrid 不同）。
2. 确认 `ping 192.168.10.1` 通、分流正常、`tcpdump` 能看到 GARP。
3. 再把 DHCP 的 option 3/6 切到新 VIP。这一步决定"新拿租约的设备走新网关"，
   已持有旧租约的设备要等续租（或手动重连）才生效。
4. 最后搬宿主机：先确认 `mv-shim` 起来且 `ping .1` 通，然后把**防火墙端口表和
   `bridges.nix` 放在同一次 rebuild 里**改完 —— 宿主机搬家瞬间 SSH 会断，
   分两次改会出现"IP 已变、防火墙还按老接口名挡着"的失联状态。
5. 清理：退役路由 VM、清旧租约、改下游静态配置。