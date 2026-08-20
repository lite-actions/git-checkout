# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Scope

A composite **GitHub Action** (pure shell) that checks out a repository with
plain `git`, covering the `actions/checkout` inputs that workflows actually use.
It exists so the sibling action repos stop dragging a bundled Node runtime — and
its deprecation warnings — into every job.

It is deliberately **not** a full reimplementation: token auth only (no
`ssh-key`), and no post-job cleanup, because composite actions do not get a post
step. Both gaps are documented in the README's "Differences" section; keep that
section honest as the script grows.

## Layout

- `action.yml` — composite action; one shell step runs `scripts/checkout.sh`
  with `INPUT_*` env and exposes outputs `ref`, `commit`, `path`.
- `scripts/checkout.sh` — all the logic, in eleven numbered sections that follow
  the order of operations.
- `tests/test.sh` — assert-based suite against a fixture repo served over
  `file://`; no network.
- `.github/workflows/ci.yml` — shellcheck, the suite on ubuntu **and macOS**,
  and an `e2e` job against real GitHub remotes. **No `actions/checkout`
  anywhere**: each job bootstraps the action with six git commands and then uses
  the action itself, so CI doubles as the proof that the action replaces
  `actions/checkout` outright.

- `.github/workflows/conventional-validation.yml` — `mrdoodles/conventional-validator@v1`
  on PRs (commits, branch name, body), skipped for Dependabot.
- `.github/workflows/changelog.yml` — on push to main,
  `mrdoodles/conventional-changelog@v1` then `mrdoodles/release-notes@v1`,
  committed straight back (this repo is unprotected, so no PR dance).
- `.pre-commit-config.yaml` — Conventional Commits on `commit-msg`, the
  `conventional-branch` hook from `mrdoodles/conventional-validator`, plus local
  shellcheck and test-suite hooks.

The bootstrap **cannot be deduplicated**: `uses: ./…` needs the action in the
workspace before it can run, Actions has no YAML anchors, and a reusable
workflow is a separate job with a separate workspace. Expressions are not
allowed in `uses:` either, so `mrdoodles/git-checkout@${{ github.sha }}` is out.
Once `v1` is tagged, workflows that do **not** need the commit under test could
switch to `uses: mrdoodles/git-checkout@v1` and drop the bootstrap entirely; CI
itself cannot, since it must test the action at the PR's commit.

Every one of these workflows checks out at the **workspace root**, because a
`uses:` step cannot set `working-directory` — a remote action like
conventional-changelog runs `git` in `GITHUB_WORKSPACE` and nowhere else. That
is only safe because of the self-preservation rule below.
- `.actrc` — podman-friendly defaults for local `act` runs.
- `README.md`, `LICENSE` (MIT).

## How `checkout.sh` works

Same order of operations as `actions/checkout`:

1. Validate inputs (booleans, `fetch-depth`, `owner/repo`, `submodules`) and
   resolve the target directory, refusing anything outside `GITHUB_WORKSPACE`.
2. Reuse the directory when it already holds a checkout of the same remote
   (clean it unless `clean: false`), else empty it and `git init`.
3. Write the token into the checkout's **local** config as
   `http.<server>/.extraheader` = `AUTHORIZATION: basic <base64>`, masked.
4. Resolve the ref: `refs/*` is used as-is; a short name is looked up with
   `ls-remote` as a branch first, then a tag; an empty ref means the workflow's
   own `GITHUB_REF` (same repo only) or the remote's default branch via
   `ls-remote --symref HEAD`. A 40-hex ref is a commit, not a ref.
5. Fetch `+<commit>:<local-ref>` when the commit is known, so a branch that
   moves mid-run cannot change what gets built; fall back to fetching the ref
   when the server refuses a bare SHA (`uploadpack.allowAnySHA1InWant`).
6. Apply/clear sparse-checkout, then force-checkout: `-B <branch>` for
   `refs/heads/*`, `--detach` otherwise.
7. LFS, submodules, credential cleanup, outputs.

Behaviours that exist for a reason — do not "simplify" them away:

- **`fetch-depth: 0` also unshallows** an existing shallow directory (`--unshallow`
  when `.git/shallow` is present), otherwise a re-run keeps the truncated history.
- **`GIT_CHECKOUT_ALLOW_WIPE`**: outside Actions the script refuses to empty a
  non-empty directory. A runner workspace is disposable; a working copy is not.
- **Self-preservation**: emptying the target directory, and `git clean` on a
  reused one, both skip the top-level entry containing `$GITHUB_ACTION_PATH`.
  A composite action loaded from the workspace lives inside the directory it is
  about to wipe, and bash reads a script as it executes it. This is what makes
  `uses: ./.action` with a workspace-root checkout work at all.
- **Sparse state lives in the worktree config.** Detect it with
  `git config --get core.sparseCheckout`, *not* `--local` — git stores it in
  `.git/config.worktree` once `extensions.worktreeConfig` is on.
- **`die` writes to stderr**, because several callers run inside `$(…)` where an
  `::error::` on stdout would be captured instead of shown.

## Commands

```bash
bash tests/test.sh
shellcheck -x --severity=warning scripts/*.sh tests/*.sh

# Manual run against a real repo:
GITHUB_WORKSPACE=/tmp/ws INPUT_REPOSITORY=mrdoodles/git-checkout \
  INPUT_FETCH_DEPTH=0 bash scripts/checkout.sh
```

Locally with `act` on podman (see the `act-local-testing` and `podman` skills):

```bash
podman machine start act
podman system connection default act
export DOCKER_HOST="unix://$(podman machine inspect act --format '{{.ConnectionInfo.PodmanSocket.Path}}')"
act -j lint
act -j test --matrix os:ubuntu-latest   # macOS legs cannot run under act
```

`.actrc` supplies `--container-daemon-socket -` (podman on macOS cannot
bind-mount the host socket path into the VM) and `--pull=false`. The `e2e` job
needs the branch pushed, since it checks itself out from the real origin.

## Coding style

- Pure `bash` with `set -euo pipefail`; must pass
  `shellcheck -x --severity=warning` (CI enforces).
- Portable to the **bash 3.2** on macOS: no `mapfile`/`readarray`, no
  `base64 -w0` (pipe through `tr -d '\n'`), and guard possibly-empty array
  expansions under `set -u`.
- `INPUT_*` env vars are not auto-populated in composite steps — every input is
  passed explicitly in `action.yml` and re-defaulted in the script.
- Every behaviour change ships with an assertion in `tests/test.sh`; use the
  `assert`/`refute` helpers rather than `[ … ]; check $?` (SC2319).

## Versioning & releasing

Releases are cut by `release.yml` (`workflow_dispatch`) — never by hand, and
never through the GitHub web UI:

```bash
gh workflow run release.yml --repo lite-actions/git-checkout
```

It computes the version from the commits since the last `vX.Y.Z` tag, tags the
release, force-moves `@vN`, and publishes the GitHub Release with the generated
notes as its body. `@vN` is the moving major tag consumers use.

**Never create a release through the web UI.** The "publish to the Marketplace"
checkbox is required only for an action's *first* publish; once a listing
exists, releases cut by the workflow appear on it automatically — verified
2026-08-20 on `git-checkout`, where `v1.1.0` reached the listing with nothing
ticked. Using the UI afterwards is what produced the `v1.12` and `1.3.5` tags,
and left `@v1` pointing at an old commit three times. The workflow types
nothing, so it cannot mistype.

## Conventions

- Public, **unprotected** repo — push docs/fixes to `main` directly; workflow-
  file changes need a `workflow`-scoped token.
- Conventional Commits for messages, with the body as a **single unwrapped
  paragraph**; co-authored commits use the bot identity:
  `Co-Authored-By: Claude <309050497+MrDClaudeBot@users.noreply.github.com>`.
