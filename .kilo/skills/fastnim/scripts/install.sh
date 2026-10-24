#!/usr/bin/env bash
#
# Installs the FastNim agent skill into a target project.
#
# Usage: install.sh [target-dir]      (target-dir defaults to the current directory)
#
# Rules:
#   * When <target>/.agents already exists, nothing is created, changed, or removed.
#   * Otherwise <target>/.agents/skills/fastnim/ receives the skill files and
#     <target>/AGENTS.md is created (or extended with a pointer to the skill).

set -euo pipefail

scriptDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
skillSrc="$(cd -- "$scriptDir/.." && pwd)"
targetDir="${1:-$PWD}"

if [ ! -f "$skillSrc/SKILL.md" ]; then
  printf 'fastnim: error: no SKILL.md found in %s\n' "$skillSrc" >&2
  exit 1
fi

agentsDir="$targetDir/.agents"
skillDest="$agentsDir/skills/fastnim"
agentsMd="$targetDir/AGENTS.md"

if [ -e "$agentsDir" ]; then
  printf 'fastnim: %s already exists - nothing to do.\n' "$agentsDir"
  exit 0
fi

read -r -d '' agentsTemplate <<'EOF' || true
# AGENTS.md

Guidance for AI coding agents working in this repository.

## FastNim

This project works with [FastNim](https://github.com/buffmomoeveryday/fastnim), an
asynchronous HTTP framework for Nim built on [Chronos](https://github.com/status-im/nim-chronos).

### Skill

The FastNim reference skill is installed at `.agents/skills/fastnim/SKILL.md`.
Read it before writing, reviewing, or debugging FastNim code: it covers route macros,
path/query/body parameter extraction and validation, middleware and dependency injection,
OpenAPI metadata, static files, plugins, streaming (WebSocket, SSE, gRPC), and testing.
Deeper references live under `.agents/skills/fastnim/references/`; load only the one the
current task needs.

### Rules

- **Chronos only.** `import chronos`; never `std/asyncdispatch` or `std/asynclines` - it breaks the event loop.
- **No blocking I/O** in handlers or framework internals. Use `await sleepAsync(...)`, never `os.sleep`.
- **Async signatures** return `Future[T]`; annotate with `{.async.}`.
- **Errors** raise `ApiErrorException` subclasses (`newBadRequestError`, `newNotFoundError`,
  `newUnprocessableEntityError`) or use the `badRequest`/`notFound` helpers. Uncaught exceptions
  become a sanitized JSON `500`.
- **Style**: 2-space indent, camelCase procs, PascalCase types, lowercase module files. Export
  public symbols with `*` and document them with `##` doc comments.

### Commands

- `nimble build` - compile check.
- `nimble test` - run the test suite.
- `nim c -r --path:src <main>.nim` - run the app locally.
EOF

read -r -d '' agentsSection <<'EOF' || true
## FastNim

This project works with [FastNim](https://github.com/buffmomoeveryday/fastnim), an
asynchronous HTTP framework for Nim built on Chronos.

The FastNim reference skill is installed at `.agents/skills/fastnim/SKILL.md`; read it before
writing, reviewing, or debugging FastNim code (routes, params, middleware, dependency
injection, OpenAPI, plugins, streaming, testing). Key rules: import `chronos` only, never
block inside handlers, and raise `ApiErrorException` subclasses for errors.
EOF

mkdir -p "$skillDest"
cp -R "$skillSrc/." "$skillDest/"

if [ -f "$agentsMd" ]; then
  if grep -q 'skills/fastnim/SKILL.md' "$agentsMd"; then
    printf 'fastnim: %s already points at the FastNim skill - left unchanged.\n' "$agentsMd"
  else
    printf '\n%s\n' "$agentsSection" >> "$agentsMd"
    printf 'fastnim: added the FastNim section to %s.\n' "$agentsMd"
  fi
else
  printf '%s\n' "$agentsTemplate" > "$agentsMd"
  printf 'fastnim: created %s.\n' "$agentsMd"
fi

printf 'fastnim: installed the FastNim skill into %s.\n' "$skillDest"
