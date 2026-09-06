{
  description = "Nix flake — local-first RAG stack (pgvector + Ollama) for macOS via home-manager. Loopback-only launchd Postgres+pgvector+pgsql-http and a local Ollama embed model, wired into an in-DB embed() function for plain-SQL RAG. No API key, nothing leaves the machine.";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  nixConfig = {
    extra-substituters = [ "https://kattakath.cachix.org" ];
    extra-trusted-public-keys = [
      "kattakath.cachix.org-1:y/w6wnb4ZArdlbfWJ82c81uCXeYgG/sGDUYCszavmEw="
    ];
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      home-manager,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];

      flake = {
        # The reusable home-manager modules (system-agnostic; no-op off macOS).
        # `ollamaLocal` turns on home-manager's own `services.ollama` and adds the
        # embed-model pull; `pgvectorLocal` imports it so it's usable standalone —
        # the postgres module single-sources the model/dim from `ollamaLocal` and
        # the host/port straight from `services.ollama` either way.
        homeManagerModules.ollamaLocal = ./modules/ollama-local.nix;
        homeManagerModules.pgvectorLocal = ./modules/pgvector-local.nix;
        homeManagerModules.default = {
          imports = [
            self.homeManagerModules.ollamaLocal
            self.homeManagerModules.pgvectorLocal
          ];
        };
      };

      perSystem =
        { pkgs, system, ... }:
        {
          formatter = pkgs.nixfmt-rfc-style;

          # Eval check: a throwaway home-manager configuration with both services
          # enabled, asserting the options single-source correctly and the launchd
          # agents materialise — without forcing a build of the (large) postgres /
          # ollama package closures themselves (mirrors nix-keychain-secrets' check).
          # aarch64-darwin only — the services themselves are launchd/macOS-only.
          checks = pkgs.lib.optionalAttrs (system == "aarch64-darwin") (
            let
              hm = home-manager.lib.homeManagerConfiguration {
                inherit pkgs;
                modules = [
                  self.homeManagerModules.default
                  {
                    home.username = "tester";
                    home.homeDirectory = "/Users/tester";
                    home.stateVersion = "24.05";
                    services.ollamaLocal.enable = true;
                    services.pgvectorLocal.enable = true;
                  }
                ];
              };
              inherit (hm.config) services launchd;
            in
            {
              module-evaluates = pkgs.runCommand "local-rag-eval" { } ''
                test "${pkgs.lib.boolToString services.ollama.enable}" = "true"
                test "${services.ollama.host}" = "127.0.0.1"
                test "${toString services.ollama.port}" = "11434"
                test "${services.ollamaLocal.embedModel}" = "nomic-embed-text"
                test "${toString services.ollamaLocal.embedDim}" = "768"
                test "${services.pgvectorLocal.databaseUri}" = "postgresql://mcp@127.0.0.1:5433/ragdb"
                test "${pkgs.lib.boolToString launchd.agents.ollama.enable}" = "true"
                # Proves the log override merges onto UPSTREAM's agent rather than
                # forking it — upstream declares no StandardOutPath of its own.
                test "${launchd.agents.ollama.config.StandardOutPath}" = "/Users/tester/Library/Logs/ollama-local.log"
                test "${pkgs.lib.boolToString launchd.agents.ollama-local-pull.enable}" = "true"
                test "${pkgs.lib.boolToString launchd.agents.postgres-pgvector.enable}" = "true"
                echo ok > "$out"
              '';
            }
          );
        };
    };
}
