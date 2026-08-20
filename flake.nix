{
  description = "Nix flake — local-first RAG stack (pgvector + Ollama) for macOS via home-manager. Loopback-only launchd Postgres+pgvector+pgsql-http and a local Ollama embed model, wired into an in-DB embed() function for plain-SQL RAG. No API key, nothing leaves the machine.";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  nixConfig = {
    extra-substituters = [ "https://ismailkattakath.cachix.org" ];
    extra-trusted-public-keys = [
      "ismailkattakath.cachix.org-1:7BbEvLpASY7aNUZfpzRMWir1zjU3nqmllBTl8p7gr2I="
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
        # `pgvectorLocal` imports `ollamaLocal` itself so it's usable standalone —
        # the postgres module single-sources the ollama host/port/model/dim options
        # from it either way.
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
                test "${services.ollamaLocal.host}" = "127.0.0.1"
                test "${toString services.ollamaLocal.port}" = "11434"
                test "${services.ollamaLocal.embedModel}" = "nomic-embed-text"
                test "${toString services.ollamaLocal.embedDim}" = "768"
                test "${services.pgvectorLocal.databaseUri}" = "postgresql://mcp@127.0.0.1:5433/ragdb"
                test "${pkgs.lib.boolToString launchd.agents.ollama-local.enable}" = "true"
                test "${pkgs.lib.boolToString launchd.agents.postgres-pgvector.enable}" = "true"
                echo ok > "$out"
              '';
            }
          );
        };
    };
}
