---
name: act-local-testing
description: >-
  Running this repo's GitHub workflows locally with `act` on podman before
  pushing. Load when asked to test a workflow, reproduce a CI failure locally,
  debug a composite action end-to-end, or when `act` fails to connect to a
  daemon. Covers the exact podman invocation, matrix and event selection,
  secrets, the ACT env guard, and which jobs cannot run locally.
---

# Running the workflows locally with `act`

`act` replays a workflow inside a container that approximates a GitHub runner.
It catches the mistakes worth catching early — wrong input wiring, a missing
`shell:`, an output that never lands — without burning a push.

## The invocation on this machine

Containers come from **podman**, not Docker (see the `podman` skill). Two things
are required every time:

```bash
podman machine start act
export DOCKER_HOST="unix://$(podman machine inspect act --format '{{.ConnectionInfo.PodmanSocket.Path}}')"

act -j test --matrix os:ubuntu-latest --container-daemon-socket - --pull=false
```

- `DOCKER_HOST` is how act's client reaches podman. Without it act tries
  `/var/run/docker.sock` and fails with `daemon … no such file or directory`.
- `--container-daemon-socket -` disables mounting the daemon socket into the job
  container. Without it podman fails at container creation with
  `making volume mountpoint … operation not supported`, because the host socket
  path does not exist inside the VM. This repo's `.actrc` sets the flag, so an
  `act` run from the repo root only needs `DOCKER_HOST`.
- `--pull=false` reuses the cached `catthehacker/ubuntu:act-latest` image
  instead of re-checking the registry on every run.

## Selecting what to run

```bash
act -l                                  # jobs, with the events that trigger them
act -j lint                             # one job
act -n -j e2e                           # dry run: list the steps, execute nothing
act pull_request -j test                # a different event
act -e event.json                       # a hand-written event payload
act --matrix os:ubuntu-latest           # pick one matrix leg
act -v                                  # verbose, when a step behaves oddly
```

`macos-latest` matrix legs **cannot run** — act has no macOS image. Always
filter the matrix, or expect `unable to determine image`.

## Secrets and tokens

`${{ secrets.* }}` and `${{ github.token }}` are empty unless you supply them:

```bash
act -j e2e -s GITHUB_TOKEN="$(gh auth token)"
act --secret-file .secrets            # KEY=value lines; keep it out of git
```

Anything cloning a public repo works without a token — this action simply skips
the auth header when the token is empty.

## What act gets wrong, and how to cope

- **`ACT=true` is set** in every act run. Guard steps that cannot work locally
  with `if: ${{ !env.ACT }}` rather than deleting them.
- **`GITHUB_ACTIONS=true` is also set**, so code that branches on "am I in CI?"
  takes the CI path. In `scripts/checkout.sh` that means the wipe-the-workspace
  branch is live — which is correct, but see the warning below.
- **The runner image is not the GitHub image.** `catthehacker/ubuntu:act-latest`
  is close; the `-micro` variants lack most tooling. A step that installs its own
  dependencies (like the shellcheck job) behaves the same either way.
- **Git context is synthesised** from the local checkout. `GITHUB_SHA` is your
  local HEAD and there may be no remote at all — so **no job in this repo runs
  end-to-end under act**, since every one of them bootstraps itself by fetching
  `$GITHUB_SHA` from the real origin. Use `act -n -j <job>` to check that a
  workflow parses and its steps resolve, run `bash tests/test.sh` directly for
  the suite, and simulate whole workflows against a `file://` fixture the way
  `tests/test.sh` builds one.
- Caching (`actions/cache`) and artifacts are no-ops unless you pass
  `--artifact-server-path`.

## Never run act with `--bind` on a checkout job

`--bind` mounts the working directory into the container instead of copying it,
so `GITHUB_WORKSPACE` *is* your real repository. A job that checks out into the
workspace root will then empty your working tree — uncommitted work included.
Run without `--bind` (the default) so act works on a copy.
