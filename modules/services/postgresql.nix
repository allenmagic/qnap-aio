{ pkgs, ... }:

{
  # 独立 PostgreSQL 集群（目前无服务使用；Immich 已删除）。
  # 以后新增 Postgres 应用时，在这里加 ensureDatabases / ensureUsers / extensions。
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_17;
  };
}
