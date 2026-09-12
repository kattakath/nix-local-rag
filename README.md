> [!IMPORTANT]
> ## Archived 2026-09-12 — this flake now lives inside `kattakath/nix-config`
>
> The code moved to **`modules/features/local-rag/`** in
> [kattakath/nix-config](https://github.com/kattakath/nix-config), as a *capsule*: a
> directory that may not reach outside itself, enforced by the repo's `ast-grep` gate rather
> than by convention.
>
> **Why:** maintaining seven satellite flakes cost seven CI pipelines, seven merge queues and a
> lock-bump dance for every cross-cutting change — for repos with 2 GitHub stars between them.
> The rationale, the four competing architectures that were scored, the adversarial review that
> found three blocking defects, and an honest list of what the collapse gives up are all in
> [`docs/monoflake-capsule-adr.md`](https://github.com/kattakath/nix-config/blob/main/docs/monoflake-capsule-adr.md).
>
> **This repository is read-only.** Its history is preserved here and is the only place it
> exists — the absorption was a plain copy, not a `git subtree`, so `git blame` in nix-config
> stops at the collapse commit and continues here.

# nix-local-rag

[![CI](https://github.com/kattakath/nix-local-rag/actions/workflows/ci.yml/badge.svg)](https://github.com/kattakath/nix-local-rag/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Built with Nix](https://img.shields.io/badge/built%20with-Nix-5277C3.svg?logo=nixos&logoColor=white)](https://nixos.org)

A local-first RAG (retrieval-augmented generation) stack for macOS, declared as
home-manager `launchd` user agents: a loopback-only **Postgres + pgvector +
pgsql-http**, a loopback-only **Ollama** (home-manager's own `services.ollama`),
and a one-shot agent that pulls the embed model. Bootstrap SQL wires them together
with an in-DB `public.embed(text)` `SECURITY DEFINER` function that calls
Ollama over loopback HTTP, plus a `public.docs` table (content + jsonb
metadata + a vector column) and an HNSW cosine index — so ingest and retrieval
are both **plain SQL**:

```sql
INSERT INTO docs (content, embedding) VALUES ($1, embed($1));
SELECT content, metadata FROM docs ORDER BY embedding <=> embed($2) LIMIT 8;
```

No API key, no vector-DB client library, nothing leaves the machine.

## Prerequisites

- **macOS on Apple Silicon** (`aarch64-darwin`) — the modules declare
  `launchd.agents`, macOS's user-agent mechanism.
- **Nix** with flakes enabled (`experimental-features = nix-command flakes`).
- **[home-manager](https://github.com/nix-community/home-manager)**.
- Disk space for the Ollama embed model (a few hundred MB for
  `nomic-embed-text`, more for larger models) and whatever corpus you ingest.

## Install

```nix
{
  inputs.local-rag.url = "github:kattakath/nix-local-rag";

  # in your home-manager modules:
  #   local-rag.homeManagerModules.default
  # (or the two named modules separately: .ollamaLocal / .pgvectorLocal)
  # then:
  #   services.ollamaLocal.enable = true;
  #   services.pgvectorLocal.enable = true;
}
```

Both default to loopback-only, no auth needed:

```nix
{
  services.ollamaLocal = {
    enable = true;
    # embedModel = "nomic-embed-text";  # default, 768-dim
    # embedDim = 768;           # must match embedModel's output dimension
  };

  # The Ollama SERVER is home-manager's own `services.ollama`, which
  # `ollamaLocal` enables for you. Its coordinates live there, not here:
  # services.ollama = {
  #   host = "127.0.0.1";       # default
  #   port = 11434;             # default
  # };

  services.pgvectorLocal = {
    enable = true;
    # port = 5433;              # default; off 5432 to dodge a Homebrew postgres
    # role = "mcp";             # default; owns `db`, no rights elsewhere
    # db = "ragdb";             # default
    # dataDir = "${config.home.homeDirectory}/.local/share/postgres-pgvector"; # default
  };
}
```

`pgvectorLocal` single-sources Ollama's coordinates into its bootstrap SQL (the
embed function's URL and the `vector(...)` column width), so it's enough to
change them in one place: `services.ollama`'s `host`/`port` for the URL,
`ollamaLocal`'s `embedModel`/`embedDim` for the model and column width. The
`pgvectorLocal` module imports `ollamaLocal` itself, so it evaluates standalone
even if you only reference the postgres module directly — but you need
`ollamaLocal.enable = true` too for `embed()` to actually have something to
call at runtime.

## Usage

Once the agents are running (`launchctl list | grep -E 'ollama|postgres-pgvector'`),
connect with any Postgres client — `psql`, a script, or your own MCP
`postgres` server — using `config.services.pgvectorLocal.databaseUri`
(read-only, computed from `role`/`port`/`db`; no secret in it, trust auth on
127.0.0.1):

```sh
psql "$(nix eval --raw .#homeConfigurations.\"you\".config.services.pgvectorLocal.databaseUri)"
```

or just hardcode the default shape: `postgresql://mcp@127.0.0.1:5433/ragdb`.

**This flake does not wire the URI into an MCP server for you** — that
decoupling is deliberate (see below). Point your own tool at it.

```sql
-- ingest
INSERT INTO docs (content, metadata, embedding)
VALUES ($1, $2::jsonb, embed($1));

-- retrieve
SELECT content, metadata, 1 - (embedding <=> embed($1)) AS similarity
FROM docs
ORDER BY embedding <=> embed($1)
LIMIT 8;
```

## Security model

- **Loopback-only binds.** Postgres is hard-bound to `127.0.0.1` — there is no
  `host` option to widen it. Ollama binds its configured `host`, default
  `127.0.0.1`; widening that one is on you.
- **Role/db lockdown.** Postgres's superuser (the macOS login user, created by
  `initdb`) is reachable only over the local Unix socket via `peer` auth. Over
  TCP, only the dedicated `role` may connect, only to `db`, via `trust` (no
  password needed because nothing untrusted can reach loopback Postgres
  without already being a process on your Mac). `role` owns `db` and has no
  rights anywhere else — a compromised consumer's blast radius is exactly that
  one database.
- **`SECURITY DEFINER` embed().** The `http` extension (which can make
  arbitrary outbound HTTP calls) lives in a private `ext` schema that `role`
  has **no** access to. `role` only sees `public.embed(text)`, a fixed-URL
  wrapper — so SQL-injectable or LLM-generated queries running as `role`
  cannot be tricked into arbitrary HTTP via `ext.http_post` directly.
- **No secrets anywhere.** Nothing here needs a password, API key, or token —
  that's what makes emitting `databaseUri` into the Nix store safe. If you
  widen `host` past loopback, you've left this model; add your own auth.

## Used in production

Extracted from **[kattakath/nix-config](https://github.com/kattakath/nix-config)**,
where it backs a `postgres` MCP server. `nix-config` now consumes this flake
directly (`modules/shared/home.nix` imports `local-rag.homeManagerModules.default`)
rather than vendoring the module — see
[`modules/shared/postgres-pgvector.nix`](https://github.com/kattakath/nix-config/blob/739f8c202526aca7632f12363d07b24f29e58300/modules/shared/postgres-pgvector.nix)
(and [`modules/shared/ollama.nix`](https://github.com/kattakath/nix-config/blob/739f8c202526aca7632f12363d07b24f29e58300/modules/shared/ollama.nix))
pinned to the last commit before extraction for the pre-extraction,
MCP-coupled version, and
[`skills/rag/SKILL.md`](https://github.com/kattakath/nix-config/blob/main/skills/rag/SKILL.md)
for how an AI coding agent is taught to use the resulting `embed()`/`docs`
interface.

## License

MIT © Ismail Kattakath
