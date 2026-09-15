{ config, lib, pkgs, ... }:

let
  dataDir = "/srv/data";
  backupDir = "/srv/backup";

  # 需要备份的目录（dataDir 下的子目录名）
  sources = [ "documents" "music" "photos" "webdav" ];

  # 保留策略：30 天内的快照全留，更早的每月只留最早一份，最多回溯 12 个月
  keepDaily = 30;
  keepMonthly = 12;

  sourcesArray = lib.concatMapStringsSep " " lib.escapeShellArg sources;

  # 生成 <backupDir> 下所有形如 YYYY-MM-DD 的快照目录名，升序
  listSnapshots = ''
    find ${lib.escapeShellArg backupDir} -maxdepth 1 -type d \
      -regextype posix-extended -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}' \
      -printf '%f\n' | sort
  '';

  backupScript = pkgs.writeShellApplication {
    name = "nas-backup";
    runtimeInputs = with pkgs; [ rsync coreutils findutils util-linux ];
    text = ''
      set -euo pipefail

      data_dir=${lib.escapeShellArg dataDir}
      backup_dir=${lib.escapeShellArg backupDir}
      sources=(${sourcesArray})

      # 目标盘没挂载时必须失败退出：否则会静默写进根分区
      if ! mountpoint -q "$backup_dir"; then
        echo "错误：$backup_dir 未挂载，中止备份" >&2
        exit 1
      fi

      today=$(date +%F)
      dest="$backup_dir/$today"
      stage="$backup_dir/.incomplete"

      # 上一份快照作为 --link-dest 基准：未变化的文件在两份之间共享 inode，
      # 不额外占空间。排除今天自己，避免重跑时指向正在重建的目录。
      prev=""
      while IFS= read -r d; do
        [[ "$d" == "$today" ]] && continue
        prev="$d"
      done < <(${listSnapshots})

      rm -rf "''${stage:?}"
      mkdir -p "$stage"

      for name in "''${sources[@]}"; do
        src="$data_dir/$name"
        if [[ ! -d "$src" ]]; then
          echo "跳过不存在的源目录：$src" >&2
          continue
        fi

        link_dest=()
        if [[ -n "$prev" && -d "$backup_dir/$prev/$name" ]]; then
          link_dest=(--link-dest="$backup_dir/$prev/$name")
        fi

        echo "备份 $src -> $dest/$name"
        rsync -aHAX --numeric-ids --delete \
          "''${link_dest[@]}" \
          --exclude=@eaDir \
          --exclude=.DS_Store \
          --exclude=.Trash \
          --exclude='*.tmp' \
          "$src/" "$stage/$name/"
      done

      # 全部源成功后才落盘：中途失败时快照目录不会被创建出来，
      # 半成品留在 .incomplete 供排查，也不会成为下一次的 link-dest 基准
      rm -rf "''${dest:?}"
      mv "$stage" "$dest"
      ln -sfn "$dest" "$backup_dir/latest"
      echo "快照完成：$dest"

      # 清理过期快照。遍历升序，每月遇到的第一份即该月最早的一份
      cutoff=$(date -d "${toString keepDaily} days ago" +%F)
      month_cutoff=$(date -d "${toString keepMonthly} months ago" +%Y-%m)
      last_month=""
      while IFS= read -r snap; do
        if [[ "$snap" > "$cutoff" || "$snap" == "$cutoff" ]]; then
          continue
        fi
        month="''${snap%-*}"
        if [[ "$month" == "$last_month" || "$month" < "$month_cutoff" ]]; then
          echo "删除过期快照：$snap"
          rm -rf -- "''${backup_dir:?}/$snap"
          continue
        fi
        last_month="$month"
      done < <(${listSnapshots})
    '';
  };

  verifyScript = pkgs.writeShellApplication {
    name = "nas-backup-verify";
    runtimeInputs = with pkgs; [ coreutils findutils util-linux diffutils ];
    text = ''
      set -euo pipefail

      data_dir=${lib.escapeShellArg dataDir}
      backup_dir=${lib.escapeShellArg backupDir}
      sources=(${sourcesArray})

      if ! mountpoint -q "$backup_dir"; then
        echo "错误：$backup_dir 未挂载" >&2
        exit 1
      fi

      snap=$(readlink -f "$backup_dir/latest")
      if [[ -z "$snap" || ! -d "$snap" ]]; then
        echo "错误：找不到 latest 快照" >&2
        exit 1
      fi

      # 备份盘是 ext4，没有 checksum，静默损坏 rsync 的默认比较（大小+mtime）
      # 发现不了；而硬链接会让同一份损坏扩散到所有引用它的快照。
      # 这里逐字节比对「自快照之后未再修改过」的源文件——源文件 mtime 早于
      # 快照日期就说明它本该与快照逐字节相同，不同即为异常。
      # 代价：整盘读一遍，故每月跑一次。
      snap_date=$(basename "$snap")
      echo "校验快照 $snap（比对 mtime 早于 $snap_date 的文件）"

      checked=0
      mismatch=0
      while IFS= read -r -d "" f; do
        rel="''${f#"$data_dir"/}"
        checked=$((checked + 1))
        if [[ ! -f "$snap/$rel" ]]; then
          echo "缺失：$rel"
          mismatch=$((mismatch + 1))
        elif ! cmp -s -- "$f" "$snap/$rel"; then
          echo "内容不一致：$rel"
          mismatch=$((mismatch + 1))
        fi
      done < <(find "''${sources[@]/#/$data_dir/}" -type f ! -newermt "$snap_date" -print0)

      echo "校验完成：检查 $checked 个文件，$mismatch 个异常"
      if ((mismatch > 0)); then
        exit 1
      fi
    '';
  };
in
{
  # ===== 备份：rsync 硬链接快照 =====
  # /srv/backup/<YYYY-MM-DD>/ 每份是当天的完整视图，未变化的文件靠 --link-dest
  # 与上一份共享 inode，所以 30 份快照的占用 ≈ 一份全量 + 30 天的变化量。
  # 快照里是普通文件，恢复直接 cp 即可，不依赖任何工具。
  #
  # 属主：脚本以 root 运行（需读取全部数据并保留属主）。rsync -a 会把源文件的
  # nas:nas 属主一并带过来，所以快照内容对 Samba 的 backup 共享（force user=nas）
  # 是可读写的；若要防网络端改写备份，需把该共享改成 read only = yes。
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
