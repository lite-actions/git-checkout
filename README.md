# Git Checkout Lite

A **composite** GitHub Action that checks out a repository with plain `git`.

`actions/checkout` is a Node action: it drags a bundled Node runtime into every
job, warns whenever the runner's Node version is deprecated, and cannot run at
all on a runner image without Node. This action is a shell script. Every runner
already has `git`, so there is nothing else to install and nothing to deprecate.

```yaml
- uses: lite-actions/git-checkout@v1
```

## Usage

```yaml
# The commit that triggered the workflow, one commit deep (the default).
- uses: lite-actions/git-checkout@v1

# Full history — needed for changelogs, `git describe`, diffing against a base.
- uses: lite-actions/git-checkout@v1
  with:
    fetch-depth: 0

# A fixed number of commits.
- uses: lite-actions/git-checkout@v1
  with:
    fetch-depth: 50

# Another repository, at a tag, into a subdirectory.
- uses: lite-actions/git-checkout@v1
  with:
    repository: lite-actions/conventional-changelog
    ref: v1.0.0
    path: vendor/changelog
    token: ${{ secrets.MY_PAT }}

# Just the docs, without blobs for anything else.
- uses: lite-actions/git-checkout@v1
  with:
    sparse-checkout: |
      docs
      README.md
    filter: blob:none
```

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `repository` | `${{ github.repository }}` | Repository to check out, as `owner/repo`. |
| `ref` | the triggering ref | Branch, tag, full ref (`refs/heads/main`, `refs/pull/1/merge`) or a 40-character commit SHA. Defaults to the remote's default branch when `repository` is not the current one. |
| `token` | `${{ github.token }}` | Token used to fetch, stored as a basic auth header. |
| `path` | *(workspace root)* | Directory to check out into, relative to `GITHUB_WORKSPACE`. |
| `clean` | `true` | `git clean -ffdx && git reset --hard HEAD` when reusing an existing checkout. |
| `fetch-depth` | `1` | Commits to fetch. `0` fetches everything, and unshallows a directory that was previously checked out shallow. |
| `fetch-tags` | `false` | Fetch tags as well. |
| `filter` | *(none)* | Partial clone filter, e.g. `blob:none`. |
| `sparse-checkout` | *(none)* | Newline-separated patterns to restrict the working tree to. |
| `sparse-checkout-cone-mode` | `true` | Cone mode (directory prefixes) for those patterns. |
| `lfs` | `false` | `git lfs pull` after checkout. |
| `submodules` | `false` | `false`, `true`, or `recursive`. |
| `set-safe-directory` | `true` | Add the checkout to the global `safe.directory` list. |
| `persist-credentials` | `true` | Keep the auth header so later steps can push. |
| `show-progress` | `true` | Pass `--progress` to fetch and checkout. |
| `github-server-url` | `${{ github.server_url }}` | Base URL of the git server. |

## Outputs

| Output | Description |
| --- | --- |
| `ref` | The fully-qualified ref that was checked out, e.g. `refs/heads/main`. |
| `commit` | The commit SHA at the tip of the checkout. |
| `path` | Absolute path of the checkout. |

## How it works

The sequence is the same one `actions/checkout` follows, minus the Node:

1. Reuse the directory when it already holds a checkout of the same repository
   (cleaning it unless `clean: false`), otherwise empty it and `git init`.
2. Point `origin` at `<github-server-url>/<repository>` and write an
   `AUTHORIZATION: basic …` header into the checkout's **local** git config.
3. Resolve the ref against the remote — a short name is looked up as a branch
   first, then as a tag; an empty ref uses the remote's default branch.
4. Fetch **the exact commit** (`+<sha>:refs/remotes/origin/<branch>`) so a
   branch that moves mid-run cannot change what you build. Servers that refuse
   a bare SHA fall back to fetching the ref.
5. Force-checkout: a local branch for `refs/heads/*`, detached HEAD otherwise.

## Differences from `actions/checkout`

- **`ssh-key`, `ssh-known-hosts`, `ssh-strict`, `ssh-user` are not supported.**
  Authentication is token-based only.
- **Credentials cannot be cleaned up in a post step.** Composite actions do not
  get one, so `persist-credentials: false` removes the auth header at the end of
  the checkout step instead of at the end of the job. Steps that need to push
  must use the default `persist-credentials: true`.
- `submodules` fetches with the token passed via `git -c`, which is visible in
  the runner's process list for the duration of that command.
- Running the script outside Actions refuses to empty a non-empty directory
  unless `GIT_CHECKOUT_ALLOW_WIPE=1` is set — a runner workspace is disposable,
  your working copy is not.

## It checks itself out

There is no `actions/checkout` in [this repository's CI](.github/workflows/ci.yml).
Every job bootstraps the action with a few git commands, then uses the action
for the real checkout — and the test suite runs from the checkout the action
made.

Consumers never need the bootstrap: `uses: lite-actions/git-checkout@v1` is fetched
by the runner itself, exactly like any other action. It is needed only here,
because CI has to test the action **at the commit under test**, and the
workspace starts empty:

```yaml
- name: Bootstrap the action with plain git
  env:
    TOKEN: ${{ github.token }}
  run: |
    set -euo pipefail
    git init -q .action
    git -C .action remote add origin "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}"
    basic="$(printf 'x-access-token:%s' "${TOKEN}" | base64 | tr -d '\n')"
    echo "::add-mask::${basic}"
    git -C .action config --local "http.${GITHUB_SERVER_URL}/.extraheader" \
      "AUTHORIZATION: basic ${basic}"
    git -C .action fetch --depth=1 --no-tags origin "${GITHUB_SHA}"
    git -C .action checkout -q --detach FETCH_HEAD

- uses: ./.action
  with:
    fetch-depth: 0
```

That checkout lands on the workspace root, `.action` and all. It is safe because
**the action never deletes the directory it is running from**: emptying the
workspace skips `$GITHUB_ACTION_PATH`, and so does the clean on a reused
checkout. Without that, bash would have the script deleted out from under it
mid-read.

## Requirements

`bash`, `git`, and the usual `awk`/`grep`/`base64`. All present on every
GitHub-hosted runner. `git-lfs` is needed only for `lfs: true`.

## Development

```bash
bash tests/test.sh
shellcheck -x --severity=warning scripts/*.sh tests/*.sh
```

The test suite serves a fixture repository over `file://`, so it needs no
network. See [CLAUDE.md](CLAUDE.md) for the local `act` workflow.

## Licence

MIT — see [LICENSE](LICENSE).
