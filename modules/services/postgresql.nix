{ config, lib, pkgs, ... }:

{
  # 独立 PostgreSQL 集群：配置和启停不再由 services.immich 拥有。
  # 数据目录仍是 /var/lib/postgresql/17（同一个集群），所以不需要 dump/restore。
  # 以后新增 Postgres 应用时，在这里加 ensureDatabases / ensureUsers 即可。
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_17;

    ensureDatabases = [ "immich" "photoview" ];
    ensureUsers = [
      {
        name = "immich";
        ensureDBOwnership = true;
        ensureClauses.login = true;
      }
      {
        name = "photoview";
        ensureDBOwnership = true;
        ensureClauses.login = true;
      }
    ];

    # 默认 TCP 规则是 md5，而 Photoview 的角色密码按 scram-sha-256 存储。
    # 这条必须排在默认规则之前。
    authentication = lib.mkBefore ''
      host photoview photoview 127.0.0.1/32 scram-sha-256
    '';

    extensions = ps: [
      ps.pgvector
      ps.vectorchord
    ];
    settings = {
      shared_preload_libraries = [ "vchord.so" ];
      search_path = "\"$user\", public, vectors";
    };
  };
}
