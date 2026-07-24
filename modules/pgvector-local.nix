# home-manager module: services.pgvectorLocal
#
# Local PostgreSQL + pgvector, as a loopback-only launchd user agent (darwin).
#
# WHY: a real pgvector store for vector-similarity / RAG work, bootstrapped
# with a plain-SQL RAG interface — a `docs` table plus an in-DB `embed(text)`
# function that calls `services.ollamaLocal` (modules/ollama-local.nix) over
# loopback HTTP. Same shape as any other Home Manager `launchd.agents` unit —
# bound to 127.0.0.1, started at login (RunAtLoad), kept alive (KeepAlive).
# Nothing listens off-box.
#
# NO SECRETS IN THE STORE: auth is loopback-scoped, password-free.
#   * The SUPERUSER (the macOS login user, created by initdb) is reachable ONLY
#     over the local unix socket via `peer` auth (OS-user == role) — used for
#     bootstrap/admin.
#   * Over TCP (127.0.0.1) ONLY the dedicated non-superuser `role` may connect,
#     ONLY to database `db`, via `trust` (no password). `role` owns `db` and
#     has no rights anywhere else, so a consumer's blast radius is exactly
#     that one database.
# The connection URI therefore carries no secret and is safe to emit into the
# store; it is exposed read-only as `services.pgvectorLocal.databaseUri`. This
# module does NOT wire that URI into any MCP server or client itself — that's
# on you: point your own Postgres-backed tool (MCP server, script, whatever)
# at it. See README.md "Security model" + "Install" for the shape.
#
# BOOTSTRAP: the run-wrapper initdb's the data dir on first launch, writes a
# locked-down pg_hba.conf every launch (idempotent), and — once, guarded by a
# sentinel that also tracks the bootstrap SQL's content — creates the `role` +
# `db` + `CREATE EXTENSION vector`, then execs postgres in the foreground for
# launchd to supervise.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.services.pgvectorLocal;
  ollama = config.services.ollamaLocal;
in
{
  imports = [
    # Single-sources ollama.host/port/embedModel/embedDim into the bootstrap
    # SQL below — always present even if a consumer only imports this module.
    ./ollama-local.nix
  ];

  options.services.pgvectorLocal = {
    enable = lib.mkEnableOption "local Postgres + pgvector RAG store as a launchd user agent (darwin)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 5433;
      description = ''
        TCP port Postgres listens on. Defaults off 5432 to avoid clashing
        with a possible Homebrew/other Postgres install.
      '';
    };

    role = lib.mkOption {
      type = lib.types.str;
      default = "mcp";
      description = ''
        Non-superuser role created on bootstrap, scoped to `db` only (owns it,
        no rights elsewhere). This is the role a consumer's connection URI
        authenticates as over TCP.
      '';
    };

    db = lib.mkOption {
      type = lib.types.str;
      default = "ragdb";
      description = "Database created on bootstrap, owned by `role`.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.local/share/postgres-pgvector";
      description = "Postgres data directory (initdb target, PGDATA).";
    };

    databaseUri = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "postgresql://${cfg.role}@127.0.0.1:${toString cfg.port}/${cfg.db}";
      description = ''
        Loopback pgvector connection URI. The role is scoped to a single
        database (no secret, trust auth on 127.0.0.1). Wire this into your
        OWN Postgres-backed consumer (e.g. an MCP `postgres` server's
        DATABASE_URI) — this module does not do that wiring for you.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && pkgs.stdenv.isDarwin) (
    let
      # postgresql WITH pgvector (`CREATE EXTENSION vector`) AND pgsql-http
      # (`CREATE EXTENSION http`) — the latter lets the in-DB embed() function
      # POST to local Ollama.
      pgPkg = pkgs.postgresql_16.withPackages (ps: [
        ps.pgvector
        ps.pgsql-http
      ]);

      # RAG bootstrap SQL, applied to `db` (as superuser) whenever it changes.
      # Makes any plain-SQL client (e.g. an MCP `postgres` server) a complete
      # RAG endpoint:
      #   * `public.embed(text) -> vector` — SECURITY DEFINER, calls local
      #     Ollama over loopback HTTP and returns the embedding. The http
      #     extension lives in a private `ext` schema that `${role}` has NO
      #     access to, so retrieved/untrusted content can't trick an LLM into
      #     arbitrary HTTP via SQL — only this fixed-URL wrapper is exposed.
      #   * `public.docs` — the conventional store (content + jsonb metadata +
      #     a vector(embedDim) column) with an HNSW cosine index.
      # So ingest is `INSERT INTO docs (content, embedding) VALUES ($1, embed($1))`
      # and query is `... ORDER BY embedding <=> embed('question') LIMIT k` —
      # the client never handles vectors directly.
      ragSql = pkgs.writeText "rag-bootstrap.sql" ''
        CREATE EXTENSION IF NOT EXISTS vector;
        CREATE SCHEMA IF NOT EXISTS ext;
        CREATE EXTENSION IF NOT EXISTS http SCHEMA ext;

        CREATE OR REPLACE FUNCTION public.embed(input text) RETURNS public.vector
          LANGUAGE sql
          SECURITY DEFINER
          SET search_path = pg_temp
        AS $embed$
          SELECT (
            (ext.http_post(
              'http://${ollama.host}:${toString ollama.port}/api/embeddings',
              pg_catalog.json_build_object('model', '${ollama.embedModel}', 'prompt', input)::text,
              'application/json'
            )).content::jsonb -> 'embedding'
          )::text::public.vector;
        $embed$;

        CREATE TABLE IF NOT EXISTS public.docs (
          id        bigserial PRIMARY KEY,
          content   text NOT NULL,
          metadata  jsonb NOT NULL DEFAULT '{}',
          embedding public.vector(${toString ollama.embedDim})
        );
        CREATE INDEX IF NOT EXISTS docs_embedding_hnsw
          ON public.docs USING hnsw (embedding public.vector_cosine_ops);

        -- Lock the raw http surface away from ${cfg.role}; expose only the
        -- fixed-URL embed().
        REVOKE ALL ON SCHEMA ext FROM PUBLIC;
        GRANT EXECUTE ON FUNCTION public.embed(text) TO ${cfg.role};
        GRANT ALL ON public.docs TO ${cfg.role};
        GRANT USAGE, SELECT ON SEQUENCE public.docs_id_seq TO ${cfg.role};
      '';

      runScript = pkgs.writeShellApplication {
        name = "postgres-pgvector-run";
        runtimeInputs = [ pgPkg ];
        text = ''
          DATADIR=${lib.escapeShellArg cfg.dataDir}
          PORT=${toString cfg.port}
          OSUSER="$(id -un)"

          mkdir -p "$DATADIR"
          chmod 700 "$DATADIR"

          # First launch: initialise the cluster (superuser = the login user, socket peer auth).
          if [ ! -s "$DATADIR/PG_VERSION" ]; then
            initdb -D "$DATADIR" -U "$OSUSER" --auth=peer --encoding=UTF8 --no-locale
          fi

          # Loopback-only auth, rewritten every launch (idempotent): superuser via
          # the local socket (peer); over TCP only ${cfg.role}@${cfg.db} (trust, no
          # secret). Nothing else on TCP.
          {
            printf '%s\n' "local   all   all   peer"
            printf '%s\n' "host    ${cfg.db}   ${cfg.role}   127.0.0.1/32   trust"
            printf '%s\n' "host    ${cfg.db}   ${cfg.role}   ::1/128   trust"
          } > "$DATADIR/pg_hba.conf"

          # Ensure the scoped role + database + RAG schema. Re-runs when the
          # role/db is missing OR the RAG bootstrap SQL changed (stamp = its store
          # path), so schema edits re-apply on rebuild; otherwise skipped for a
          # fast launch. All idempotent.
          if [ ! -f "$DATADIR/.pgvector-local-bootstrapped" ] \
             || [ "$(cat "$DATADIR/.rag-sql" 2>/dev/null || true)" != "${ragSql}" ]; then
            pg_ctl -D "$DATADIR" -w \
              -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=$DATADIR" start
            if ! psql -h "$DATADIR" -p "$PORT" -U "$OSUSER" -d postgres -tAc \
                 "SELECT 1 FROM pg_roles WHERE rolname='${cfg.role}'" | grep -q 1; then
              createuser -h "$DATADIR" -p "$PORT" -U "$OSUSER" ${cfg.role}
            fi
            if [ "$(psql -h "$DATADIR" -p "$PORT" -U "$OSUSER" -d postgres -tAc \
                 "SELECT 1 FROM pg_database WHERE datname='${cfg.db}'")" != "1" ]; then
              createdb -h "$DATADIR" -p "$PORT" -U "$OSUSER" -O ${cfg.role} ${cfg.db}
            fi
            psql -h "$DATADIR" -p "$PORT" -U "$OSUSER" -d ${cfg.db} -v ON_ERROR_STOP=1 \
              -c "GRANT ALL ON SCHEMA public TO ${cfg.role};" \
              -f ${ragSql}
            pg_ctl -D "$DATADIR" -w stop
            touch "$DATADIR/.pgvector-local-bootstrapped"
            printf '%s\n' "${ragSql}" > "$DATADIR/.rag-sql"
          fi

          exec postgres -D "$DATADIR" -p "$PORT" \
            -c listen_addresses=127.0.0.1 -c unix_socket_directories="$DATADIR"
        '';
      };
    in
    {
      # Postgres client tools (psql/createdb/…) on PATH for manual queries.
      home.packages = [ pgPkg ];

      launchd.agents.postgres-pgvector = {
        enable = true;
        config = {
          ProgramArguments = [ (lib.getExe runScript) ];
          RunAtLoad = true;
          KeepAlive = true;
          StandardOutPath = "${config.home.homeDirectory}/Library/Logs/postgres-pgvector.log";
          StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/postgres-pgvector.log";
        };
      };
    }
  );
}
