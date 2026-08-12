#!/usr/bin/env bash
#
# Exercises checkout.sh against a local bare repo served over file://.
# Run: bash tests/test.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKOUT="${ROOT}/scripts/checkout.sh"

pass=0
fail=0

# Run the assertion inside the helper — `[ … ]; check … $?` trips SC2319.
assert() { # description  command...
  local desc="$1"; shift
  if "$@"; then echo "  ok   - ${desc}"; pass=$((pass + 1))
  else echo "  FAIL - ${desc}"; fail=$((fail + 1)); fi
}

refute() { # description  command...
  local desc="$1"; shift
  if "$@"; then echo "  FAIL - ${desc}"; fail=$((fail + 1))
  else echo "  ok   - ${desc}"; pass=$((pass + 1)); fi
}

# When this suite runs inside Actions these leak into every case: GITHUB_REF and
# GITHUB_SHA would be treated as the ref to check out, and GITHUB_ACTIONS would
# turn on the wipe-without-asking path. Each test opts in to what it needs.
unset GITHUB_REPOSITORY GITHUB_REF GITHUB_SHA GITHUB_SERVER_URL GITHUB_ACTIONS GITHUB_WORKSPACE

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# ---------------------------------------------------------------------------
# A bare "server" repo: file://${tmp}/server/acme/widget.git, so the script's
# ${server-url}/${owner/repo} URL construction is exercised for real.
# ---------------------------------------------------------------------------
SERVER="file://${tmp}/server"
REPO="acme/widget.git"
BARE="${tmp}/server/${REPO}"
work="${tmp}/authoring"

mkdir -p "${BARE}"
git init -q --bare "${BARE}"
# Real repositories have a HEAD that resolves; the fixture must too, or the
# default-branch lookup has nothing to find.
git -C "${BARE}" symbolic-ref HEAD refs/heads/main
# github.com allows fetching a bare sha; make the fixture behave the same, and
# allow partial clones so the filter test has something to talk to.
git -C "${BARE}" config uploadpack.allowAnySHA1InWant true
git -C "${BARE}" config uploadpack.allowFilter true

git init -q -b main "${work}"
git -C "${work}" config user.email test@example.com
git -C "${work}" config user.name test
mkdir -p "${work}/docs" "${work}/src"
echo "first" > "${work}/README.md"
echo "doc" > "${work}/docs/guide.md"
echo "code" > "${work}/src/main.c"
git -C "${work}" add -A
git -C "${work}" commit -q -m "chore: init"
first_sha="$(git -C "${work}" rev-parse HEAD)"
git -C "${work}" tag -a v1.0.0 -m "v1.0.0"
echo "second" >> "${work}/README.md"
git -C "${work}" commit -qam "feat: more"
main_sha="$(git -C "${work}" rev-parse HEAD)"
git -C "${work}" branch topic
git -C "${work}" remote add origin "${BARE}"
git -C "${work}" push -q origin main topic --tags

run() { # target-dir  [INPUT_X=... ...]
  local dir="$1"; shift
  env -i \
    PATH="${PATH}" HOME="${HOME}" \
    GITHUB_WORKSPACE="${dir}" \
    GITHUB_OUTPUT="${dir}.out" \
    INPUT_GITHUB_SERVER_URL="${SERVER}" \
    INPUT_REPOSITORY="${REPO}" \
    INPUT_SHOW_PROGRESS=false \
    "$@" \
    bash "${CHECKOUT}"
}

out_value() { # out-file  key
  awk -F= -v k="$2" '$1 == k { print substr($0, length(k) + 2); exit }' "$1"
}

# ---------------------------------------------------------------------------
echo "== default ref (remote HEAD), default depth"
d="${tmp}/ws1"; mkdir -p "$d"
run "$d" >/dev/null 2>&1
assert "checked out the default branch tip" \
  [ "$(git -C "$d" rev-parse HEAD)" = "${main_sha}" ]
assert "landed on a local branch, not a detached HEAD" \
  [ "$(git -C "$d" rev-parse --abbrev-ref HEAD)" = "main" ]
assert "working tree is populated" [ -f "$d/README.md" ]
assert "fetch-depth defaults to 1 (shallow)" \
  [ "$(git -C "$d" rev-list --count HEAD)" = "1" ]
assert "ref output is fully qualified" \
  [ "$(out_value "$d.out" ref)" = "refs/heads/main" ]
assert "commit output is the resolved sha" \
  [ "$(out_value "$d.out" commit)" = "${main_sha}" ]
# The script reports a fully resolved path, and on macOS $TMPDIR lives behind
# the /var → /private/var symlink.
assert "path output is the checkout dir" \
  [ "$(out_value "$d.out" path)" = "$(cd "$d" && pwd -P)" ]
assert "no credentials were persisted (no token given)" \
  [ -z "$(git -C "$d" config --local --get-regexp extraheader 2>/dev/null)" ]

# ---------------------------------------------------------------------------
echo "== fetch-depth"
d="${tmp}/ws-depth0"; mkdir -p "$d"
run "$d" INPUT_FETCH_DEPTH=0 >/dev/null 2>&1
assert "fetch-depth 0 fetches the full history" \
  [ "$(git -C "$d" rev-list --count HEAD)" = "2" ]
refute "fetch-depth 0 leaves no shallow marker" test -f "$d/.git/shallow"

d="${tmp}/ws-depth2"; mkdir -p "$d"
run "$d" INPUT_FETCH_DEPTH=2 >/dev/null 2>&1
assert "fetch-depth 2 fetches two commits" \
  [ "$(git -C "$d" rev-list --count HEAD)" = "2" ]

echo "== deepening an existing shallow checkout"
d="${tmp}/ws-deepen"; mkdir -p "$d"
run "$d" INPUT_FETCH_DEPTH=1 >/dev/null 2>&1
assert "starts shallow" [ "$(git -C "$d" rev-list --count HEAD)" = "1" ]
run "$d" INPUT_FETCH_DEPTH=0 >/dev/null 2>&1
assert "re-running with fetch-depth 0 unshallows it" \
  [ "$(git -C "$d" rev-list --count HEAD)" = "2" ]

refute "a non-numeric fetch-depth is rejected" \
  run "${tmp}/ws-baddepth" INPUT_FETCH_DEPTH=deep

# ---------------------------------------------------------------------------
echo "== explicit refs"
d="${tmp}/ws-branch"; mkdir -p "$d"
run "$d" INPUT_REF=topic >/dev/null 2>&1
assert "short branch name resolves to a local branch" \
  [ "$(git -C "$d" rev-parse --abbrev-ref HEAD)" = "topic" ]

d="${tmp}/ws-fullref"; mkdir -p "$d"
run "$d" INPUT_REF=refs/heads/topic >/dev/null 2>&1
assert "refs/heads/<name> resolves to the same branch" \
  [ "$(git -C "$d" rev-parse --abbrev-ref HEAD)" = "topic" ]

d="${tmp}/ws-tag"; mkdir -p "$d"
run "$d" INPUT_REF=v1.0.0 >/dev/null 2>&1
assert "tag checks out its commit" [ "$(git -C "$d" rev-parse HEAD)" = "${first_sha}" ]
assert "tag checkout is detached" \
  [ "$(git -C "$d" rev-parse --abbrev-ref HEAD)" = "HEAD" ]
assert "tag ref output is fully qualified" \
  [ "$(out_value "$d.out" ref)" = "refs/tags/v1.0.0" ]

d="${tmp}/ws-sha"; mkdir -p "$d"
run "$d" INPUT_REF="${first_sha}" >/dev/null 2>&1
assert "a 40-hex ref is treated as a commit" \
  [ "$(git -C "$d" rev-parse HEAD)" = "${first_sha}" ]
assert "commit checkout is detached" \
  [ "$(git -C "$d" rev-parse --abbrev-ref HEAD)" = "HEAD" ]

refute "an unknown ref fails" run "${tmp}/ws-noref" INPUT_REF=does-not-exist

# ---------------------------------------------------------------------------
echo "== workflow context (GITHUB_REF / GITHUB_SHA)"
d="${tmp}/ws-ctx"; mkdir -p "$d"
run "$d" GITHUB_REPOSITORY="${REPO}" GITHUB_REF=refs/heads/main GITHUB_SHA="${first_sha}" \
  >/dev/null 2>&1
assert "pins to the event sha rather than the branch tip" \
  [ "$(git -C "$d" rev-parse HEAD)" = "${first_sha}" ]
assert "still ends up on the branch" \
  [ "$(git -C "$d" rev-parse --abbrev-ref HEAD)" = "main" ]

echo "== the sha fetch falls back when the server refuses it"
git -C "${BARE}" config uploadpack.allowAnySHA1InWant false
d="${tmp}/ws-nosha"; mkdir -p "$d"
run "$d" GITHUB_REPOSITORY="${REPO}" GITHUB_REF=refs/heads/main GITHUB_SHA="${first_sha}" \
  INPUT_FETCH_DEPTH=0 >/dev/null 2>&1
assert "falls back to fetching the ref" [ -f "$d/README.md" ]
assert "and lands on the branch" \
  [ "$(git -C "$d" rev-parse --abbrev-ref HEAD)" = "main" ]
git -C "${BARE}" config uploadpack.allowAnySHA1InWant true

echo "== context is ignored for a different repository"
d="${tmp}/ws-otherrepo"; mkdir -p "$d"
run "$d" GITHUB_REPOSITORY=someone/else GITHUB_REF=refs/heads/nope GITHUB_SHA=deadbeef \
  >/dev/null 2>&1
assert "another repo's context does not leak in" \
  [ "$(git -C "$d" rev-parse HEAD)" = "${main_sha}" ]

# ---------------------------------------------------------------------------
echo "== path"
d="${tmp}/ws-path"; mkdir -p "$d"
run "$d" INPUT_PATH=nested/dir >/dev/null 2>&1
assert "checks out into the nested path" [ -f "$d/nested/dir/README.md" ]
refute "does not check out into the workspace root" test -f "$d/README.md"

refute "a path escaping the workspace is rejected" \
  run "${tmp}/ws-escape" INPUT_PATH=../../etc

# ---------------------------------------------------------------------------
echo "== clean and reuse"
d="${tmp}/ws-clean"; mkdir -p "$d"
run "$d" >/dev/null 2>&1
echo "junk" > "$d/untracked.txt"
echo "edited" > "$d/README.md"
run "$d" >/dev/null 2>&1
refute "clean removes untracked files on reuse" test -f "$d/untracked.txt"
assert "clean restores modified tracked files" \
  [ -z "$(git -C "$d" status --porcelain)" ]

d="${tmp}/ws-noclean"; mkdir -p "$d"
run "$d" >/dev/null 2>&1
echo "junk" > "$d/untracked.txt"
run "$d" INPUT_CLEAN=false >/dev/null 2>&1
assert "clean=false keeps untracked files" test -f "$d/untracked.txt"

echo "== an unrelated directory is refused outside Actions, wiped inside it"
d="${tmp}/ws-wipe"; mkdir -p "$d"
echo "precious" > "$d/notes.txt"
refute "refuses to empty a non-empty directory locally" run "$d"
assert "…and leaves it alone" test -f "$d/notes.txt"
run "$d" GITHUB_ACTIONS=true >/dev/null 2>&1
refute "empties it when running in Actions" test -f "$d/notes.txt"
assert "then checks out normally" test -f "$d/README.md"

echo "== the action never deletes itself"
# A composite action loaded from the workspace (`uses: ./.action`) sits inside
# the directory being emptied, and bash reads its script as it runs.
d="${tmp}/ws-self"; mkdir -p "$d/.action/scripts"
echo "marker" > "$d/.action/scripts/checkout.sh"
echo "stale" > "$d/leftover.txt"
run "$d" GITHUB_ACTIONS=true GITHUB_ACTION_PATH="$d/.action" >/dev/null 2>&1
assert "the running action's directory survives the wipe" \
  test -f "$d/.action/scripts/checkout.sh"
refute "everything else is still emptied" test -f "$d/leftover.txt"
assert "and the checkout happened around it" test -f "$d/README.md"

echo "junk" > "$d/untracked.txt"
run "$d" GITHUB_ACTIONS=true GITHUB_ACTION_PATH="$d/.action" >/dev/null 2>&1
assert "clean on reuse spares it too" test -f "$d/.action/scripts/checkout.sh"
refute "while still removing other untracked files" test -f "$d/untracked.txt"

# ---------------------------------------------------------------------------
echo "== sparse checkout"
d="${tmp}/ws-sparse"; mkdir -p "$d"
run "$d" INPUT_SPARSE_CHECKOUT="docs" >/dev/null 2>&1
assert "sparse pattern is materialised" test -f "$d/docs/guide.md"
refute "excluded directory is absent" test -f "$d/src/main.c"
run "$d" >/dev/null 2>&1
assert "re-running without the input restores a full checkout" test -f "$d/src/main.c"

d="${tmp}/ws-sparse-nocone"; mkdir -p "$d"
run "$d" INPUT_SPARSE_CHECKOUT="/docs/" INPUT_SPARSE_CHECKOUT_CONE_MODE=false >/dev/null 2>&1
assert "no-cone patterns work too" test -f "$d/docs/guide.md"
refute "and still exclude the rest" test -f "$d/src/main.c"

# ---------------------------------------------------------------------------
echo "== tags and filters"
d="${tmp}/ws-notags"; mkdir -p "$d"
run "$d" >/dev/null 2>&1
assert "tags are not fetched by default" [ -z "$(git -C "$d" tag -l)" ]

d="${tmp}/ws-tags"; mkdir -p "$d"
run "$d" INPUT_FETCH_TAGS=true INPUT_FETCH_DEPTH=0 >/dev/null 2>&1
assert "fetch-tags brings the tags along" [ -n "$(git -C "$d" tag -l)" ]

d="${tmp}/ws-filter"; mkdir -p "$d"
run "$d" INPUT_FILTER=blob:none INPUT_FETCH_DEPTH=0 >/dev/null 2>&1
assert "a partial-clone filter still yields a usable tree" test -f "$d/README.md"
assert "and records the filter" \
  [ "$(git -C "$d" config --local --get remote.origin.partialclonefilter)" = "blob:none" ]

# ---------------------------------------------------------------------------
echo "== credentials"
d="${tmp}/ws-creds"; mkdir -p "$d"
run "$d" INPUT_TOKEN=s3cret >/dev/null 2>&1
assert "the token is stored as a basic auth header" \
  [ "$(git -C "$d" config --local --get "http.${SERVER}/.extraheader")" \
    = "AUTHORIZATION: basic $(printf 'x-access-token:s3cret' | base64 | tr -d '\n')" ]

d="${tmp}/ws-nocreds"; mkdir -p "$d"
run "$d" INPUT_TOKEN=s3cret INPUT_PERSIST_CREDENTIALS=false >/dev/null 2>&1
assert "persist-credentials=false removes it again" \
  [ -z "$(git -C "$d" config --local --get-regexp extraheader 2>/dev/null)" ]

# ---------------------------------------------------------------------------
echo "== submodules"
SUB_BARE="${tmp}/server/acme/lib.git"
mkdir -p "${SUB_BARE}"
git init -q --bare "${SUB_BARE}"
git -C "${SUB_BARE}" symbolic-ref HEAD refs/heads/main
subwork="${tmp}/lib"
git init -q -b main "${subwork}"
git -C "${subwork}" config user.email test@example.com
git -C "${subwork}" config user.name test
echo "lib" > "${subwork}/lib.txt"
git -C "${subwork}" add -A
git -C "${subwork}" commit -q -m "chore: init lib"
git -C "${subwork}" remote add origin "${SUB_BARE}"
git -C "${subwork}" push -q origin main

# Since git 2.38 the file:// transport is refused for submodules unless it is
# explicitly allowed; GIT_CONFIG_* scopes that to these child processes only.
allow_file=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always)
env "${allow_file[@]}" git -C "${work}" -c protocol.file.allow=always \
  submodule add -q "file://${tmp}/server/acme/lib.git" vendor/lib >/dev/null 2>&1
git -C "${work}" commit -q -m "feat: vendor lib"
git -C "${work}" push -q origin main
main_sha="$(git -C "${work}" rev-parse HEAD)"

d="${tmp}/ws-nosub"; mkdir -p "$d"
run "$d" >/dev/null 2>&1
refute "submodules are not populated by default" test -f "$d/vendor/lib/lib.txt"

d="${tmp}/ws-sub"; mkdir -p "$d"
run "$d" "${allow_file[@]}" INPUT_SUBMODULES=true >/dev/null 2>&1
assert "submodules=true populates the submodule" test -f "$d/vendor/lib/lib.txt"

d="${tmp}/ws-sub-rec"; mkdir -p "$d"
run "$d" "${allow_file[@]}" INPUT_SUBMODULES=recursive INPUT_TOKEN=s3cret >/dev/null 2>&1
assert "submodules=recursive populates it too" test -f "$d/vendor/lib/lib.txt"
assert "the auth header reaches the submodule config" \
  [ -n "$(git -C "$d/vendor/lib" config --local --get-regexp extraheader)" ]

d="${tmp}/ws-sub-nocreds"; mkdir -p "$d"
run "$d" "${allow_file[@]}" INPUT_SUBMODULES=true INPUT_TOKEN=s3cret \
  INPUT_PERSIST_CREDENTIALS=false >/dev/null 2>&1
assert "persist-credentials=false clears the submodule config too" \
  [ -z "$(git -C "$d/vendor/lib" config --local --get-regexp extraheader 2>/dev/null)" ]

echo "== input validation"
refute "a bad boolean is rejected" run "${tmp}/ws-badbool" INPUT_CLEAN=yesplease
refute "a repository without an owner is rejected" \
  run "${tmp}/ws-badrepo" INPUT_REPOSITORY=widget
refute "a bad submodules value is rejected" \
  run "${tmp}/ws-badsub" INPUT_SUBMODULES=sometimes

# ---------------------------------------------------------------------------
echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ] || exit 1
