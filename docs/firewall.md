# 防火墙分层实施细则

设计原则见 [`gateway.md`](gateway.md) §14。本文是落地细节。

## 0. 为什么这样切

三条**硬约束**决定了分工，不是偏好问题：

| 约束 | 后果 |
|---|---|
| XDP 没有 conntrack | 做不了有状态的 default deny——会把回包一起丢掉 |
| macvlan 让容器间流量走内核内部软交换 | **宿主机看不见容器间流量**，XDP 更看不见 |
| XDP 没有日志 | 丢包静默，排查难度远高于 nftables |

换句话说：**宿主机已经从数据面上被摘出去了**（这是选 macvlan 换性能的代价），
所以"唯一的策略点"这个目标不成立，只能分层。

## 1. 现状盘点

### 容器内 nftables（已就位，不需要动）

| 项 | 来源 |
|---|---|
| `input` 链 policy drop + `ct state` | NixOS firewall 模块 |
| `forward` 链 policy drop + `ct state` | `networking.firewall.filterForward = true` |
| 每服务最小放行（DNS/DHCP/VRRP/隧道） | yunshu gateway 模块 + `side-router.nix` + `dnsmasq.nix` |
| masquerade / DNS DNAT | 同上 |
| **MSS clamping** | 本轮补上（`extraForwardRules`） |
| 兜底日志 `limit rate N/minute log + drop` | ⚠️ **待补**：原 router-vm 有，新模块还没加 |

### 宿主机

**目前零过滤**。纯二层，不参与转发，nftables 也看不到 macvlan 流量。

## 2. 目标形态

| 层 | 挂载点 | 职责 | 状态 |
|---|---|---|---|
| XDP | `wan` 物理口（native） | flood 限速、IP 黑名单、畸形包、WAN 入向端口白名单 | 待做 |
| tc egress | `wan` / `tun0` | 防泄漏：`tun0` 未就绪时禁止 WAN 发包 | 待做 |
| nftables | 每个容器内 | **default deny** + 有状态 + 每服务放行 + 日志 | 已有 |

**关键约定：XDP 默认动作是 `PASS`，不是 `DROP`。** default deny 留在容器的
nftables 里——XDP 只做"名单内的坏流量"和"超限流量"的丢弃。

## 3. 第一阶段：`wan` 口 XDP 粗过滤

风险最低（只影响外网入向），先做这个。

### 3.1 程序

`xdp/wan-filter.c`，libbpf 风格，约 150 行：

```c
// 伪代码骨架，展示关键决策
SEC("xdp")
int wan_filter(struct xdp_md *ctx) {
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    if (parse_eth(&data, data_end) < 0) return XDP_PASS;   // 畸形包 → 交给内核栈，不自己判
    if (eth->h_proto != htons(ETH_P_IP)) return XDP_PASS;  // 只处理 IPv4

    if (parse_ip(&data, data_end) < 0) return XDP_PASS;

    // ① 静态黑名单（BPF_MAP_TYPE_LPM_TRIE，由 Nix 生成后 loader 灌入）
    if (bpf_map_lookup_elem(&blacklist, &ip->saddr)) return XDP_DROP;

    // ② 每源 IP 的 SYN 令牌桶（LRU hash + bpf_ktime_get_ns）
    if (ip->protocol == IPPROTO_TCP && is_syn(&tcp)) {
        if (!token_bucket_allow(ip->saddr)) {
            bump(&stats.syn_dropped);
            return XDP_DROP;
        }
    }

    // ③ 其余一律放行——default deny 不在这里
    return XDP_PASS;
}
```

三条设计决策：

- **默认 `PASS`**：不在这里做 default deny（见 §0）
- **畸形包 `PASS`**：解析失败时交给内核栈判断，而不是自己丢——XDP 里写错
  裁剪逻辑静默丢合法包的风险，比放过去大
- **不用 `XDP_REDIRECT`**：会把帧直接送到别的接口、绕过 macvlan 分发，容器就收不到了

### 3.2 构建与挂载

```nix
# modules/security/xdp.nix（新增）
{ pkgs, lib, config, ... }:
let
  wanFilter = pkgs.stdenv.mkDerivation {
    name = "xdp-wan-filter";
    src = ../xdp;
    nativeBuildInputs = [ pkgs.clang pkgs.libbpf pkgs.llvm ];
    buildInputs = [ pkgs.libbpf pkgs.linuxHeaders ];
    buildPhase = ''
      clang -O2 -g -target bpf -D__TARGET_ARCH_x86 \
        -c wan-filter.c -o wan-filter.o
    '';
    installPhase = "install -D wan-filter.o $out/wan-filter.o";
  };
in {
  # 只在 wan 存在后挂载；native 模式（igc 已确认支持，见 §6）
  systemd.services.xdp-wan-filter = {
    wantedBy = [ "multi-user.target" ];
    after = [ "network-pre.target" ];
    bindsTo = [ "sys-subsystem-net-devices-wan.device" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.iproute2}/bin/ip link set dev wan xdpdrv obj ${wanFilter}/wan-filter.o sec xdp";
      ExecStop = "${pkgs.iproute2}/bin/ip link set dev wan xdp off";
    };
  };
}
```

用 `xdpdrv`（native）而不是 `xdpgeneric` ✓——后者在 2.5G 线速下会明显掉速。

⚠️ **默认不 enable**。写成选项（`modules/security/xdp.nix` 里的 `xdp.enable`），
真机上单独验证通过后再打开——理由见 §7。

### 3.3 可观测性（必须有，否则等于没有）

```bash
# 统计计数器（程序里 per-CPU map 维护）
bpftool map dump name xdp_stats
# 程序是否挂着
ip link show dev wan | grep xdp
bpftool prog show | grep wan_filter
```

没有日志的前提下，**计数器就是唯一的事后证据**。至少要区分：
`blacklist_dropped` / `syn_dropped` / `rate_limited` / `total`。

### 3.4 回滚

```bash
ip link set dev wan xdp off        # 立即摘除，不影响其他任何东西
```

这是 XDP 相对 nftables 的**唯一优势场景**：出问题时一条命令摘掉，
不会像 nftables 那样可能已经把管理通道锁在外面。

## 4. 第二阶段：tc egress 防泄漏

XDP 只有入向，防不了出向。"`tun0` 未就绪时禁止 WAN 发包"这类需求走 tc：

```bash
tc qdisc add dev wan clsact
tc filter add dev wan egress bpf da obj leak-guard.o sec egress
```

判据与 `main-router` 的健康检查保持一致（`yunshu -i` 的连接状态，不是 `ip link
show tun0`——接口存在 ≠ 已连接）。

内核侧 `NET_CLS_BPF=y`/`NET_ACT_BPF=m` 已确认 ✓。

## 5. 第三阶段（可选）：`lan` 口 XDP

风险高得多——**丢错包会直接断掉管理通道和 NAS 服务**。

只有在内网设备出现异常流量（中毒设备扫描、IoT 设备风暴）时才值得做，且必须：

- 先只做**限速**不做**丢弃**（`XDP_PASS` + 计数，观察一段时间）
- 确认无副作用后再改成丢弃
- 全程保留一个 console 兜底（kmscon 有已知的 DRM 热插拔崩溃问题，别指望它）

## 6. 验证方法

**测试机可用** ✓——virtio-net 支持 XDP（native），所以 QEMU 里能验：

```bash
# 挂载是否成功、模式是否为 native
ip link show dev wan | grep -o "xdp/id:[0-9]*"
# 从另一台机器打流量，看计数器变化
bpftool map dump name xdp_stats
```

**真机上已确认的前置条件**（2026-09-16 实测）：

| 项 | 结论 |
|---|---|
| 驱动 | Intel igc，符号表含完整 XDP 实现（`igc_xdp_run_prog`/`set_prog`/`setup_pool`/`metadata_ops`） |
| 模式 | native（不是 generic） |
| 内核依赖 | `BPF_SYSCALL=y` `BPF_JIT=y` `XDP_SOCKETS=y` `DEBUG_INFO_BTF=y` `NET_CLS_BPF=m` 全部就位 |

**不需要改内核** ✓。

## 7. 明确不做的事

| 不做 | 原因 |
|---|---|
| XDP 里做 default deny | 无 conntrack、会丢回包 |
| XDP 里做 NAT / DNAT | XDP 改不了，也不该改 |
| 用 `XDP_REDIRECT` | 绕过 macvlan 分发，容器收不到 |
| 用 generic 模式跑生产 | 2.5G 线速下明显掉速 |
| 把容器内 nftables 的策略上移到宿主机 | 容器间流量宿主机看不见，且策略会与它保护的容器脱节 |

## 8. 待补的小项（不依赖 XDP）

容器内 nftables 缺一条原 router-vm 有的兜底日志：

```nix
# 两个路由器的 extraForwardRules 末尾
limit rate 10/minute log prefix "FORWARD_DROP: " drop
```

它不改变任何放行行为（policy 本来就是 drop），只是让"什么被挡了"可见。
在 XDP 没有日志的前提下，这条更值得补。
