---
name: github-workflows
description: >-
  Authoring GitHub composite actions and workflows in the mrdoodles action repos
  (git-checkout, conventional-validator, conventional-changelog, release-notes,
  rust-release, versioning-tests). Load when editing an action.yml, a
  .github/workflows/*.yml, a reusable workflow, or when wiring inputs, outputs,
  permissions, matrices or release tags. Covers composite-action rules, the
  INPUT_* contract, checkout depth, expression-injection safety, required checks
  and the moving-major-tag release convention. Pair with `act-local-testing` to
  run any of it locally.
---

# GitHub workflows and composite actions

## Composite actions: the rules that actually bite

- **`INPUT_*` is not populated for you.** In a JavaScript action the runner sets
  `INPUT_FOO` from `inputs.foo`; in a composite `run:` step it does **not**. Pass
  every input explicitly through `env:` and read it with a shell default:

  ```yaml
  - shell: bash
    env:
      INPUT_FETCH_DEPTH: ${{ inputs.fetch-depth }}
    run: bash "${GITHUB_ACTION_PATH}/scripts/checkout.sh"
  ```

  The script then reads `"${INPUT_FETCH_DEPTH:-1}"` — repeat the default there,
  because a caller passing an empty string bypasses the `action.yml` default.
- **`shell:` is mandatory** on every composite `run:` step. `shell: bash` runs
  `bash --noprofile --norc -eo pipefail {0}` — note `-u` is *not* included, so
  set your own `set -euo pipefail` inside scripts.
- **Reference bundled files via `${GITHUB_ACTION_PATH}`**, never a relative path
  — the working directory is the consumer's workspace, not the action.
- **There is no `post:` step.** Only JavaScript and Docker actions get cleanup.
  Anything a composite action needs to undo has to be undone before the step
  ends (this is why `persist-credentials: false` in `git-checkout` removes the
  auth header at the end of the checkout rather than at the end of the job).
- **Outputs must be forwarded twice**: the script writes `key=value` to
  `$GITHUB_OUTPUT`, the step has an `id`, and `action.yml` maps
  `value: ${{ steps.<id>.outputs.key }}`. Missing the last part is the usual
  cause of a silently empty output.
- Multi-line output values need a heredoc delimiter:
  `{ printf 'body<<EOF\n'; cat file; printf 'EOF\n'; } >> "$GITHUB_OUTPUT"`.
- Input **defaults may use expressions** (`${{ github.repository }}`,
  `${{ github.token }}`) but not `secrets.*`.
- `branding.icon` must be a name from the Feather icon set that Actions allows
  (`download`, `list`, `check-circle`, `git-branch`, …) or publishing fails.

## Marketplace

`name:` must be **globally unique across the whole Marketplace** and
`description:` must be **≤125 characters**. Pick a name, then have a fallback
ready — several obvious ones are already taken (this is why the sibling repos
carry the `… Lite` suffix).

## Workflow-level conventions in these repos

- Always declare `permissions:` explicitly; start from `contents: read` and add
  the minimum (`contents: write` to push tags/changelogs, `pull-requests: write`
  to comment).
- `pull_request` runs against the merge commit with a read-only token from a
  fork. Use `pull_request_target` only when a write token is genuinely required,
  and never check out the PR head with it.
- **Never interpolate untrusted text into a `run:` block.** `${{ github.event.*
  }}` (PR titles, branch names, commit messages) is substituted before bash
  parses the line, so a crafted title becomes a command. Pass it via `env:` and
  reference `"$TITLE"`.
- **A required check must always report.** Path-filtered workflows never report
  on a PR that touches no matching path, so a required check can hang forever.
  Run the workflow unconditionally and skip the *work* internally instead.
- `fetch-depth: 0` for anything that reads history — changelog generation,
  `git describe`, `git diff base...head`. The default single-commit checkout is
  the usual cause of "no commits found" in a changelog job.
- Prefer a matrix over duplicated jobs, with `fail-fast: false` when you want to
  see every platform's result. Include `macos-latest` for shell scripts: it is
  the only easy way to catch bash 3.2 regressions.
- Add `concurrency: { group: ${{ github.workflow }}-${{ github.ref }},
  cancel-in-progress: true }` to PR workflows to avoid stacking runs.

## Testing an action inside its own repo

Check the action's own source into a subdirectory, then use it by path — the
`uses:` value must point at the directory containing `action.yml`:

```yaml
- uses: actions/checkout@v4
  with: { path: action }
- uses: ./action
  with: { path: sample, fetch-depth: 3 }
```

Assert on the outcome (`test -f sample/action.yml`, output values, exit codes)
rather than on log text. Shallow-clone assertions should be inequalities:
`--depth=N` walks N commits *per parent*, so a merge yields more than N.

## Releasing

Semver tag plus a **moving major tag** that consumers pin to:

```bash
git tag -a v1.2.0 -m "v1.2.0"
git tag -f -a v1 -m "v1"
git push origin v1.2.0
git push -f origin v1
gh release create v1.2.0 --generate-notes
```

Pushing anything under `.github/workflows/` needs a token with the `workflow`
scope; after `gh auth refresh -s workflow` a stale keychain credential may still
be sent, so force the fresh one:

```bash
git -c credential.helper= -c credential.helper='!gh auth git-credential' push …
```
