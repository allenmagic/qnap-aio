{ config, lib, pkgs, ... }:

let
  backupDir = "/srv/backup";

  # 备份盘按「备份对象」分顶层目录，日期快照放在各自目录下：
  #   <backupDir>/<job>/<YYYY-MM-DD>/…
  # 脚本只遍历这张表：盘上其它目录（比如 PVE 自己写的 pve/）不读不写，
  # 过期清理也就不会误删外来备份。
  # 成员 = { src 的内容镜像到快照里的 dst }；dst = "." 表示直接放进日期目录。
  jobs = [
    {
      name = "nas";
      members = [
        { src = "/srv/data/documents"; dst = "documents"; }
        { src = "/srv/data/music"; dst = "music"; }
        { src = "/srv/data/photos"; dst = "photos"; }
        { src = "/srv/data/webdav"; dst = "webdav"; }
      ];
    }
    {
      name = "state";
      # 网关容器状态：tailscale/headscale 节点密钥、YunShu 登录态、dnsmasq 租约
      members = [ { src = "/srv/state"; dst = "."; } ];
    }
  ];

  # 保留策略：30 天内的快照全留，更早的每月只留最早一份，最多回溯 12 个月
  keepDaily = 30;
  keepMonthly = 12;

  # 排除项：备份与校验共用同一份，两边不一致会把排除掉的文件在校验里报成缺失
  excludes = [ "@eaDir" ".DS_Store" ".Trash" "*.tmp" ];
  excludeArgs = lib.concatMapStringsSep " " (e: "--exclude=${lib.escapeShellArg e}") excludes;
  findExcludes = lib.concatMapStringsSep " -o " (e: "-name ${lib.escapeShellArg e}") excludes;

  # 生成「<函数名> <任务名> "源<TAB>目标" …」的调用，backup/verify 两个脚本共用
  jobCalls = fn: lib.concatMapStringsSep "\n" (j:
    "${fn} ${lib.escapeShellArg j.name}"
    + lib.optionalString (j.members != [ ])
      (" " + lib.concatMapStringsSep " "
        (m: lib.escapeShellArg "${m.src}\t${m.dst}") j.members)) jobs;

  # 快照内的目标路径：dst = "." 表示直接放进日期目录
  insideFn = ''
    inside() {
      if [[ "$2" == "." ]]; then printf '%s' "$1"; else printf '%s/%s' "$1" "$2"; fi
    }
  '';

  backupScript = pkgs.writeShellApplication {
    name = "nas-backup";
    runtimeInputs = with pkgs; [ rsync coreutils findutils util-linux ];
    text = ''
      set -euo pipefail

      backup_dir=${lib.escapeShellArg backupDir}
      keep_daily=${toString keepDaily}
      keep_monthly=${toString keepMonthly}

      # 目标盘没挂载时必须失败退出：否则会静默写进根分区
      if ! mountpoint -q "$backup_dir"; then
        echo "错误：$backup_dir 未挂载，中止备份" >&2
        exit 1
      fi

      today=$(date +%F)
      failed=0

      ${insideFn}

      # 任务下的快照日期目录名，升序
      list_snapshots() {
        find "$1" -maxdepth 1 -type d \
          -regextype posix-extended -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}' \
          -printf '%f\n' | sort
      }

      # 上一份快照作为 --link-dest 基准：未变化的文件在两份之间共享 inode，
      # 不额外占空间。排除今天自己，避免重跑时指向正在重建的目录。
      prev_snapshot() {
        local d prev=""
        while IFS= read -r d; do
          if [[ "$d" == "$today" ]]; then continue; fi
          prev="$d"
        done < <(list_snapshots "$1")
        printf '%s' "$prev"
      }

      # 清理过期快照。遍历升序，每月遇到的第一份即该月最早的一份
      prune() {
        local job_dir="$1" snap month last_month=""
        local cutoff month_cutoff
        cutoff=$(date -d "$keep_daily days ago" +%F)
        month_cutoff=$(date -d "$keep_monthly months ago" +%Y-%m)
        while IFS= read -r snap; do
          if [[ "$snap" > "$cutoff" || "$snap" == "$cutoff" ]]; then continue; fi
          month="''${snap%-*}"
          if [[ "$month" == "$last_month" || "$month" < "$month_cutoff" ]]; then
            echo "删除过期快照：$job_dir/$snap"
            rm -rf -- "''${job_dir:?}/$snap"
            continue
          fi
          last_month="$month"
        done < <(list_snapshots "$job_dir")
      }

      backup_job() {
        local job="$1"; shift
        local job_dir="$backup_dir/$job"
        local dest="$job_dir/$today"
        local stage="$job_dir/.incomplete"
        local member src dst prev base target
        local link_dest=() ok=1

        mkdir -p "$job_dir"
        prev=$(prev_snapshot "$job_dir")

        rm -rf "''${stage:?}"
        mkdir -p "$stage"

        for member in "$@"; do
          IFS=$'\t' read -r src dst <<< "$member"
          if [[ ! -d "$src" ]]; then
            echo "错误：源目录不存在：$src" >&2
            ok=0
            continue
          fi

          target=$(inside "$stage" "$dst")
          link_dest=()
          if [[ -n "$prev" ]]; then
            base=$(inside "$job_dir/$prev" "$dst")
            if [[ -d "$base" ]]; then link_dest=(--link-dest="$base"); fi
          fi

          echo "备份 $src -> $(inside "$dest" "$dst")"
          # 单个成员失败不中断其余成员，但整份快照作废（见下方落盘条件）
          if ! rsync -aHAX --numeric-ids --delete "''${link_dest[@]}" ${excludeArgs} \
            "$src/" "$target/"; then
            echo "错误：rsync 失败：$src" >&2
            ok=0
          fi
        done

        # 全部成员成功后才落盘：中途失败时快照目录不会被创建出来，
        # 半成品留在 .incomplete 供排查，也不会成为下一次的 link-dest 基准
        if ((ok)); then
          rm -rf "''${dest:?}"
          mv "$stage" "$dest"
          ln -sfn "$today" "$job_dir/latest"
          echo "快照完成：$dest"
        else
          echo "错误：$job 有成员失败，本次不落盘" >&2
          failed=1
        fi

        prune "$job_dir"
      }

      ${jobCalls "backup_job"}

      if ((failed)); then
        echo "有任务未完成，见上方日志" >&2
        exit 1
      fi
    '';
  };

  verifyScript = pkgs.writeShellApplication {
    name = "nas-backup-verify";
    runtimeInputs = with pkgs; [ coreutils findutils util-linux diffutils ];
    text = ''
      set -euo pipefail

      backup_dir=${lib.escapeShellArg backupDir}
      failed=0

      if ! mountpoint -q "$backup_dir"; then
        echo "错误：$backup_dir 未挂载" >&2
        exit 1
      fi

      ${insideFn}

      verify_job() {
        local job="$1"; shift
        local job_dir="$backup_dir/$job"
        local snap snap_date member src dst target f rel
        local checked=0 mismatch=0

        snap=$(readlink -f "$job_dir/latest")
        if [[ ! -d "$snap" ]]; then
          echo "错误：$job 找不到 latest 快照" >&2
          failed=1
          return 0
        fi
        snap_date=$(basename "$snap")
        echo "校验 $job 快照 $snap（比对 mtime 早于 $snap_date 的文件）"

        # 备份盘是 ext4，没有 checksum，静默损坏 rsync 的默认比较（大小+mtime）
        # 发现不了；而硬链接会让同一份损坏扩散到所有引用它的快照。
        # 这里逐字节比对「自快照之后未再修改过」的源文件——源文件 mtime 早于
        # 快照日期就说明它本该与快照逐字节相同，不同即为异常。
        # 代价：整盘读一遍，故每月跑一次。
        for member in "$@"; do
          IFS=$'\t' read -r src dst <<< "$member"
          if [[ ! -d "$src" ]]; then
            echo "跳过不存在的源目录：$src" >&2
            continue
          fi
          target=$(inside "$snap" "$dst")

          while IFS= read -r -d "" f; do
            rel="''${f#"$src"/}"
            checked=$((checked + 1))
            if [[ ! -f "$target/$rel" ]]; then
              echo "缺失：$(inside "$job" "$dst")/$rel"
              mismatch=$((mismatch + 1))
            elif ! cmp -s -- "$f" "$target/$rel"; then
              echo "内容不一致：$(inside "$job" "$dst")/$rel"
              mismatch=$((mismatch + 1))
            fi
          done < <(find "$src" \( ${findExcludes} \) -prune -o \
                     -type f ! -newermt "$snap_date" -print0)
        done

        echo "$job 校验完成：检查 $checked 个文件，$mismatch 个异常"
        if ((mismatch > 0)); then failed=1; fi
      }

      ${jobCalls "verify_job"}

      if ((failed)); then
        exit 1
      fi
    '';
  };
in
{
  # ===== 备份：rsync 硬链接快照 =====
  # <backupDir>/<job>/<YYYY-MM-DD>/ 每份是当天的完整视图，未变化的文件靠 --link-dest
  # 与上一份共享 inode，所以 30 份快照的占用 ≈ 一份全量 + 30 天的变化量。
  # 快照里是普通文件，恢复直接 cp 即可，不依赖任何工具。
  # 任务表见文件顶部的 jobs：新增备份对象是加一条记录，不是改脚本。
  #
  # 属主：脚本以 root 运行（需读取全部数据并保留属主）。rsync -a 会把源文件的
  # nas:nas 属主一并带过来，所以快照内容对 Samba 的 backup 共享（force user=nas，
  # read only）与 NFS 的 ro 导出都是只读可见的。
  systemd.tmpfiles.rules = [
    "d ${backupDir}/nas 0755 root root -"
    "d ${backupDir}/state 0755 root root -"
    # pve/ 只是给 PVE 备份预留的场所，本服务不读不写；等接线时再定属主与权限
    "d ${backupDir}/pve 0755 root root -"
  ];

  systemd.services.backup = {
    description = "NAS 数据备份（rsync 硬链接快照）";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe backupScript;
      Nice = 10;
      IOSchedulingClass = "idle";
      TimeoutStartSec = "6h";

      # 源只读、目标可写；备份进程不需要碰系统其它部分
      ProtectSystem = "strict";
      ReadWritePaths = [ backupDir ];
      ProtectHome = true;
      PrivateTmp = true;
    };
  };

  systemd.timers.backup = {
    description = "每日 03:00 触发 NAS 备份";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "03:00";
      Persistent = true; # 关机错过则在开机后补跑
    };
  };

  # 每月 1 号校验备份盘是否出现静默损坏（见脚本内说明）
  systemd.services.backup-verify = {
    description = "NAS 备份完整性校验";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe verifyScript;
      Nice = 10;
      IOSchedulingClass = "idle";
      TimeoutStartSec = "6h";

      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };
  };

  systemd.timers.backup-verify = {
    description = "每月 1 号 04:00 校验备份完整性";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-01 04:00:00";
      Persistent = true;
    };
  };
}
