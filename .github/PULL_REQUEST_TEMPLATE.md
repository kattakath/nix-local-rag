## What & why

## Checklist
- [ ] `nix flake check -L` passes (module eval)
- [ ] `.nix` formatted (`nixfmt-rfc-style`)
- [ ] No secret values/names added; loopback-only-by-default + role/db lockdown intact
- [ ] `pgvectorLocal` still single-sources `ollamaLocal`'s host/port/embedModel/embedDim
- [ ] New options have a `description`
