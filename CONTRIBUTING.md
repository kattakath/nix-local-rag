# Contributing

A small, focused, macOS-only flake — contributions that keep it that way are
the most welcome.

## Dev loop

```sh
nix flake check -L                       # module eval check (home-manager config)
nix run nixpkgs#nixfmt-rfc-style -- .    # format all .nix (CI enforces this)
nix flake show
```

## Guidelines

- Keep both services **loopback-only by default**; any option that widens a
  bind address should say so loudly in its `description`.
- No secret values or key names anywhere — there shouldn't need to be any;
  the whole point of this stack is that loopback + role/db lockdown needs
  none. If a change would introduce a real secret, it belongs in a different
  flake (e.g. `sops-nix`/`agenix`/a Keychain-backed one).
- `services.pgvectorLocal` must keep single-sourcing
  `services.ollamaLocal`'s `host`/`port`/`embedModel`/`embedDim` — don't
  hardcode a second copy of Ollama's coordinates.
- Don't couple this flake to any specific consumer (MCP server, script,
  etc.) — it exposes `databaseUri` and stops there. Wiring belongs to the
  consumer's own config.
- Every new option needs a `description`.
- Update `README.md` for user-facing changes; CI (format + module eval) must
  pass.
