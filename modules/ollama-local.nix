# home-manager module: services.ollamaLocal
#
# The EMBEDDING half of the local RAG stack. Ollama itself is NOT hand-rolled
# here: home-manager already ships `services.ollama`, whose darwin path emits a
# `launchd.agents.ollama` running `ollama serve` with `OLLAMA_HOST` bound from
# its own `host`/`port`, `KeepAlive`, `ProcessType = "Background"`, and
# `home.packages`. This module turns that on and adds the one thing upstream
# has no opinion about — making sure an EMBED model is actually present, since
# nothing in a pgvector store can generate embeddings on its own and
# `services.pgvectorLocal` (modules/pgvector-local.nix) calls Ollama over
# loopback HTTP from an in-DB `embed()` function.
#
#   upstream option home-manager.services.ollama exists -> using it
#   (pinned home-manager modules/services/ollama.nix:108-126 — launchd.agents.ollama
#   with EnvironmentVariables/KeepAlive/ProcessType, plus home.packages; options
#   host/port at :28-44; auto-imported by modules/modules.nix:95, which readDir's
#   ./services)
#
# So bind address and port are `services.ollama.host` / `.port` — set them
# there, not here. They stay loopback (127.0.0.1) by upstream default; widening
# them is on you, Ollama has no auth. Extra server env goes through upstream's
# `services.ollama.environmentVariables` (:71-85), not a wrapper script.
#
# grepped home-manager/modules/services/ollama.nix for pull/model/embed — no
# option exists -> the pull agent below is custom, because upstream models the
# SERVER only and never fetches a model.
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
  ollama = config.services.ollama;
  logDir = "${config.home.homeDirectory}/Library/Logs";
in
{
  options.services.ollamaLocal = {
    enable = lib.mkEnableOption ''
      the local RAG embedding runtime: home-manager's `services.ollama` plus a
      one-shot agent that pulls `embedModel` (darwin)
    '';

    embedModel = lib.mkOption {
      type = lib.types.str;
      default = "nomic-embed-text";
      description = ''
        Ollama model pulled (once, by the one-shot agent) and used for
        embeddings. Must match `services.ollamaLocal.embedDim` below for
        whatever model you choose — `nomic-embed-text` is 768-dim.
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
      pullScript = pkgs.writeShellApplication {
        name = "ollama-local-pull";
        runtimeInputs = [ ollama.package ];
        text = ''
          export OLLAMA_HOST=${ollama.host}:${toString ollama.port}

          # launchd has no ordering between agents, so poll instead of assuming
          # `ollama serve` won the race. Falling out of the loop is fine: the
          # pull below then fails loudly rather than pretending it worked.
          for _ in $(seq 1 120); do
            if ollama list >/dev/null 2>&1; then break; fi
            sleep 1
          done

          # Bash substring match, NOT `ollama list | grep -q`: under
          # `writeShellApplication`'s `pipefail`, grep -q exiting early can
          # SIGPIPE `ollama list` (141), which reads as "model absent" and
          # re-pulls on every login. Idempotent as written.
          models=$(ollama list 2>/dev/null || true)
          want=${lib.escapeShellArg cfg.embedModel}
          if [[ $models != *"$want"* ]]; then
            ollama pull "$want"
          fi
        '';
      };
    in
    {
      services.ollama.enable = true;

      # Upstream sets no StandardOutPath, so the server's log would vanish into
      # launchd's sink. Merge the historical path back onto upstream's own
      # agent rather than forking it — `launchd.agents.<name>.config` is a
      # submodule that declares the key.
      # grepped home-manager/modules/services/ollama.nix for Standard*Path — no
      # option exists -> custom, because losing `ollama serve`'s log is an
      # operator-visible regression.
      # (pinned home-manager modules/launchd/default.nix:36 — `config` is
      # `submodule (import ./launchd.nix)`; StandardOutPath at launchd.nix:437)
      launchd.agents.ollama.config = {
        StandardOutPath = "${logDir}/ollama-local.log";
        StandardErrorPath = "${logDir}/ollama-local.log";
      };

      # One-shot: RunAtLoad, no KeepAlive. A failed pull exits non-zero and
      # stays visible in `launchctl print` and the log below — when this ran
      # inside the old server wrapper it had to be swallowed with `|| true`, or
      # a missing model would have taken `ollama serve` down with it.
      launchd.agents.ollama-local-pull = {
        enable = true;
        config = {
          ProgramArguments = [ (lib.getExe pullScript) ];
          RunAtLoad = true;
          StandardOutPath = "${logDir}/ollama-local-pull.log";
          StandardErrorPath = "${logDir}/ollama-local-pull.log";
        };
      };
    }
  );
}
