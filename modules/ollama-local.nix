# home-manager module: services.ollamaLocal
#
# Local Ollama, as a loopback-only launchd user agent (darwin) — the embedding
# runtime for the local RAG stack. Nothing in a pgvector store can GENERATE
# embeddings on its own, so Ollama runs an embed model locally (private, free,
# no API key) and `services.pgvectorLocal` (modules/pgvector-local.nix) calls
# it over loopback HTTP from an in-DB `embed()` function — the whole RAG loop
# stays plain SQL, no separate embedding server for a client to talk to.
#
# The run-wrapper execs `ollama serve` in the foreground for launchd to
# supervise, and pulls the embed model once in the background after the server
# is up (skipped on later launches once present). Bound to `host`/`port`
# (127.0.0.1 by default) — nothing listens off-box unless you explicitly widen
# `host`, which is on you.
#
# macOS-ONLY: gated on stdenv.isDarwin, so enabling it on a Linux host is a
# clean no-op (safe for mixed nix-darwin + NixOS fleets, and for `nix flake
# check` on Linux runners).
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.services.ollamaLocal;
in
{
  options.services.ollamaLocal = {
    enable = lib.mkEnableOption "local Ollama embedding runtime as a launchd user agent (darwin)";

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address Ollama binds to. Keep loopback (127.0.0.1) unless you have a
        specific reason to expose it further — Ollama itself has no auth.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 11434;
      description = "TCP port Ollama listens on.";
    };

    embedModel = lib.mkOption {
      type = lib.types.str;
      default = "nomic-embed-text";
      description = ''
        Ollama model pulled (once, in the background) and used for embeddings.
        Must match `services.pgvectorLocal.embedDim`'s dimension for whatever
        model you choose — `nomic-embed-text` is 768-dim.
      '';
    };

    embedDim = lib.mkOption {
      type = lib.types.int;
      default = 768;
      description = ''
        Output dimension of `embedModel`. Consumed by
        `services.pgvectorLocal` to size the `vector(...)` column — must match
        the model above, or `embed()` calls will fail with a dimension
        mismatch.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && pkgs.stdenv.isDarwin) (
    let
      runScript = pkgs.writeShellApplication {
        name = "ollama-local-run";
        runtimeInputs = [ pkgs.ollama ];
        text = ''
          export OLLAMA_HOST=${cfg.host}:${toString cfg.port}
          export OLLAMA_MODELS="$HOME/.ollama/models"

          # Pull the embed model once, in the background, after the server accepts
          # calls. Idempotent: skipped on later launches once the model is present.
          (
            for _ in $(seq 1 120); do
              if ollama list >/dev/null 2>&1; then break; fi
              sleep 1
            done
            if ! ollama list 2>/dev/null | grep -q ${lib.escapeShellArg cfg.embedModel}; then
              ollama pull ${lib.escapeShellArg cfg.embedModel} || true
            fi
          ) &

          exec ollama serve
        '';
      };
    in
    {
      home.packages = [ pkgs.ollama ];

      launchd.agents.ollama-local = {
        enable = true;
        config = {
          ProgramArguments = [ (lib.getExe runScript) ];
          RunAtLoad = true;
          KeepAlive = true;
          StandardOutPath = "${config.home.homeDirectory}/Library/Logs/ollama-local.log";
          StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/ollama-local.log";
        };
      };
    }
  );
}
