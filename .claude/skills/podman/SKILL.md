---
name: podman
description: >-
  Running containers with podman on this machine (macOS, podman 5.x, applehv
  machines) instead of Docker Desktop. Load when a task needs a container, a
  Docker-API socket, `docker` commands that fail to connect, DOCKER_HOST, image
  builds, or when driving `act`. Covers machines and connections, the socket
  paths, the Docker-compatibility shims, rootless volume/permission traps, and
  cleanup.
---

# Podman on this machine

There is **no Docker daemon here**. `/usr/local/bin/docker` is a leftover
symlink into `Docker.app`, so plain `docker …` fails with
`Cannot connect to the Docker daemon`. Use `podman`, or export `DOCKER_HOST` and
point a Docker-API client at podman's socket.

## Machines

Podman on macOS runs containers inside a Linux VM ("machine"). Two exist:

| Machine | Purpose |
| --- | --- |
| `podman-machine-default` | General use. |
| `act` | Dedicated to running GitHub Actions locally with `act`. |

```bash
podman machine list                  # NAME, LAST UP, and which is default (*)
podman machine start act             # boot it (tens of seconds)
podman machine stop act              # give the RAM back when done
podman machine ssh act               # shell inside the VM
podman machine inspect act --format '{{.ConnectionInfo.PodmanSocket.Path}}'
```

Starting a machine does **not** repoint the CLI. The `podman` command follows
the *default connection*, so with `podman-machine-default` marked default every
command tries that VM and fails with
`dial tcp 127.0.0.1:<port>: connect: connection refused` even though `act` is
running. Switch explicitly:

```bash
podman system connection list        # four entries: <machine> and <machine>-root
podman system connection default act
```

The `-root` connections are the same VM's rootful socket — use them only when a
workload genuinely needs root inside the VM.

## Talking to podman with Docker-API clients

Each machine exposes a Docker-compatible socket on the **host** side:

```bash
export DOCKER_HOST="unix://$(podman machine inspect act --format '{{.ConnectionInfo.PodmanSocket.Path}}')"
```

That is the only thing most Docker-API tools need (`act`, testcontainers,
docker-compose). `podman machine start` prints the same line on boot.

Two traps:

- **The host socket path does not exist inside the VM.** Anything that tries to
  bind-mount `$DOCKER_HOST` into a container fails with
  `making volume mountpoint for volume …/act-api.sock: operation not supported`.
  The in-VM path is `/run/user/501/podman/podman.sock`; for `act`, pass
  `--container-daemon-socket -` to skip mounting it altogether.
- A tool-specific flag that names a socket (like act's
  `--container-daemon-socket`) usually controls only what is *mounted into* the
  container, not what the client connects to. `DOCKER_HOST` is what connects.

## Everyday commands

`podman` mirrors the docker CLI, so most muscle memory transfers:

```bash
podman images --format '{{.Repository}}:{{.Tag}}'
podman ps -a
podman run --rm -it docker.io/library/alpine:3 sh
podman build -t local/thing:dev .
podman rm -f <container>; podman rmi <image>
podman system prune -a           # reclaim VM disk
podman system df                 # what is using it
```

Images are stored **per machine**, so an image pulled for `act` is invisible to
`podman-machine-default`. Fully-qualified names (`docker.io/library/…`) avoid
podman's registry-search prompt in non-interactive shells.

## Rootless traps worth knowing

- **File ownership in bind mounts.** Rootless podman maps the container's root
  to your UID, so files a container creates in a bind mount may come back owned
  by a subuid. `--userns=keep-id` makes the container user match yours.
- **Ports below 1024** cannot be published rootless; use a high port.
- **`:Z` / `:z` mount flags** are SELinux-only (Linux hosts). Harmless but
  pointless on macOS.
- On macOS the VM only sees paths podman shares into it (`$HOME`, `/tmp`,
  `/var/folders`); bind-mounting anything outside those silently yields an empty
  directory. Check with `podman machine inspect act --format '{{.Mounts}}'`.

## Cleanup

Machines hold their disk image until removed:

```bash
podman machine stop act
podman machine rm act            # destroys its images and volumes too
```
