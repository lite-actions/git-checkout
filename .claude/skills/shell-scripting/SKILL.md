---
name: shell-scripting
description: >-
  Writing and reviewing pure-bash scripts, shellcheck-clean CLIs, and GitHub
  composite-action / reusable-workflow shell for the mrdoodles action repos
  (conventional-validator, release-notes, rust-release, agile-md, versioning-tests).
  Load when editing any *.sh, an action.yml/workflow `run:` step, a matrix
  generator, or a tests/test.sh. Covers the specific gotchas: keyword quoting,
  set -e function returns, SIGPIPE, INPUT_* env, dynamic matrices, cross-OS
  packaging, and the local git/gh push tricks.
---

# Shell scripting in the mrdoodles action repos

House style: **pure `bash`**, `set -euo pipefail`, and clean under
`shellcheck -x --severity=warning` (CI enforces exactly that severity — it fails
on real warnings but tolerates info/style like unresolvable dynamic `source`
paths). No external runtime deps beyond `bash`, `git`, `awk`, `sed`, `grep`, `jq`.
Every behaviour change ships with a matching assertion in `tests/test.sh`.

## Bash gotchas that have actually bitten these repos

- **Quote the `done` keyword when it's a literal string.** In arrays
  (`COLUMNS=(todo doing "done")`), case values, or command args
  (`amd "done" 1`), an unquoted `done` triggers `SC1010`. Same care for other
  keywords used as data.
- **`set -e` + function return values.** A function whose *last* statement is
  `[ cond ] && cmd` returns non-zero when `cond` is false; calling that function
  as a plain command then aborts the caller under `set -e`. End functions with
  `if [ cond ]; then cmd; fi` (or an explicit `return 0`). This once made a whole
  loop iteration silently vanish.
- **`sed … | head` can SIGPIPE under `pipefail`** (head closes the pipe early →
  non-zero pipeline → `set -e` exit). Use `awk '… {print; exit}'` for
  first-match extraction instead.
- **Portability:** avoid `mapfile`/`readarray` (missing on the bash 3.2 that
  ships on macOS). Read into arrays with `while IFS= read -r line; do arr+=…; done`.
- **Interactivity:** gate prompts on `[ -t 0 ]`. When not a TTY, error with a
  clear message (and offer an env override like `AMD_YES=1`) — never block on
  `read`, so the script is safe in CI and when driven by tooling.
- Prefer `printf` over `echo` for anything with backslashes/leading dashes.
- `[ "$var" -gt 0 ]` needs `$var` to be a number; guard with a regex
  (`[[ "$n" =~ ^[0-9]+$ ]]`) when it comes from filenames/user input.

## GitHub Actions shell patterns

- **Composite actions:** reference bundled scripts as
  `bash "${GITHUB_ACTION_PATH}/scripts/foo.sh"`. `INPUT_*` env vars are **not**
  auto-populated in composite `run:` steps — pass them explicitly via `env:`
  (`INPUT_FOO: ${{ inputs.foo }}`), then read `${INPUT_FOO:-default}`.
- **Outputs:** `printf 'key=%s\n' "$val" >> "${GITHUB_OUTPUT}"`. For local runs,
  default it: `: "${GITHUB_OUTPUT:=/dev/stdout}"`.
- **CI-aware messages:** emit `::error::`/`::notice::` workflow commands only when
  `GITHUB_ACTIONS=true`, else print plain text — so the same script reads well as
  a local pre-commit hook (`common.sh`'s `gh_error`/`gh_notice`).
- **Commit ranges** from event context: `INPUT_BASE_REF` if given; else
  `pull_request` → `base.sha..head.sha` (via `jq` on `$GITHUB_EVENT_PATH`); else
  `push` → `before..after` (skip when `before` is all-zeros / a new branch);
  else fall back to `HEAD`.
- **Changed-file detection** (e.g. docs-only skip): use a three-dot diff
  `git diff --name-only "$base...$head"` for PRs. Guard an unreachable `before`
  SHA (force-pushes) with `git cat-file -e "${BEFORE}^{commit}"` before diffing,
  and fall back to `git show --name-only` of the tip.
- **Dynamic matrix** (à la a `component-versions` action): a shell step builds a
  JSON string and writes `matrix=<json>` to `$GITHUB_OUTPUT`; a downstream job
  consumes it with `strategy: matrix: ${{ fromJSON(needs.x.outputs.matrix) }}`.
- **A required check must always report.** If a workflow is path-filtered (e.g.
  build skips docs), instead run it always and skip the *work* internally so the
  check still reports success — otherwise a docs-only PR can never satisfy it.
- **Cross-OS packaging:** branch on `$RUNNER_OS` — `zip` on Linux/macOS, `7z` on
  Windows; add `.exe` to binary names on Windows.

## git plumbing used here

- Board/repo root: `git rev-parse --show-toplevel`.
- "Is this file tracked?": `git ls-files --error-unmatch "$f" >/dev/null 2>&1`;
  use `git mv` when tracked (history follows the rename), else plain `mv`.
- Latest **release** tag ignoring moving majors: match full semver only —
  `git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n1`.

## Testing style

`tests/test.sh` is the spec. Use a small `assert "desc" cmd…` helper (run the
command, check exit 0) rather than `[ … ]; check $?` (which trips `SC2319`).
Spin up throwaway `git init` repos in `mktemp -d` with a `trap … EXIT` cleanup.
**Lock regressions with a test** (e.g. "no SHAs in release notes", "prose
starting with 'breaking change' still passes").

## Local git / gh workflow (pushing from a machine)

- **Stale keychain token:** after `gh auth refresh -s workflow`, a local push may
  still send the cached credential. Force the fresh gh credential and drop the
  keychain helper:
  `git -c credential.helper= -c credential.helper='!gh auth git-credential' push …`
- **Pushing workflow files** (`.github/workflows/*`) needs a token with the
  `workflow` scope.
- Co-authored commits use the bot identity, not the Anthropic no-reply:
  `Co-Authored-By: Claude <309050497+MrDClaudeBot@users.noreply.github.com>`.
