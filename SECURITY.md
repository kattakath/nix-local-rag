# Security Policy

## The model (important)

Both services bind loopback only by default (`127.0.0.1`) and carry **no
secrets** — Postgres uses `peer` auth on the local socket for the superuser
and `trust` auth over TCP for the scoped `role` (safe only because loopback
already means "already a process on this Mac"), and Ollama has no auth at
all. The Postgres `role` is locked to a single database and denied direct
access to the `http` extension (only the fixed-URL `embed()` wrapper is
exposed), so a compromised consumer of `databaseUri` cannot pivot to arbitrary
outbound HTTP or to other databases.

- If you widen `services.ollamaLocal.host` / a Postgres `pg_hba.conf` rule
  past loopback, you have left this threat model — add your own
  authentication before doing so.
- `databaseUri` carries no secret and is safe in the Nix store / your
  home-manager config; it is **not** safe to expose the port itself off-box.

## Reporting a vulnerability

Please open a **private** security advisory via GitHub
("Security" → "Report a vulnerability"), or contact the maintainer directly.
Do not file public issues for undisclosed vulnerabilities.
