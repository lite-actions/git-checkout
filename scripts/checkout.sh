#!/usr/bin/env bash
#
# Check out a git repository using nothing but `git` — a Node-free stand-in for
# the parts of actions/checkout that workflows actually use.
#
# The shape of the work mirrors actions/checkout: init an empty repo, point
# `origin` at the server, store a basic-auth header in the *local* config, fetch
# exactly the wanted commit, then force-checkout it.
#
# Inputs (env):
#   INPUT_REPOSITORY                 owner/repo (default: $GITHUB_REPOSITORY).
#   INPUT_REF                        Branch, tag, refs/… or 40-hex commit SHA.
#   INPUT_TOKEN                      Token for the auth header.
#   INPUT_PATH                       Checkout dir, relative to the workspace.
#   INPUT_CLEAN                      Clean a reused checkout (default: true).
#   INPUT_FETCH_DEPTH                Commits to fetch; 0 = everything (default: 1).
#   INPUT_FETCH_TAGS                 Fetch tags too (default: false).
#   INPUT_FILTER                     Partial-clone filter, e.g. blob:none.
#   INPUT_SPARSE_CHECKOUT            Newline-separated sparse patterns.
#   INPUT_SPARSE_CHECKOUT_CONE_MODE  Cone mode for those patterns (default: true).
#   INPUT_LFS                        Pull LFS objects (default: false).
#   INPUT_SUBMODULES                 false | true | recursive (default: false).
#   INPUT_SET_SAFE_DIRECTORY         Add to global safe.directory (default: true).
#   INPUT_PERSIST_CREDENTIALS        Keep the auth header (default: true).
#   INPUT_SHOW_PROGRESS              Pass --progress (default: true).
#   INPUT_GITHUB_SERVER_URL          Git server (default: $GITHUB_SERVER_URL).
#
# Outputs (to $GITHUB_OUTPUT): ref, commit, path
#
set -euo pipefail

: "${GITHUB_OUTPUT:=/dev/stdout}"
emit() { printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT}"; }

in_actions() { [ "${GITHUB_ACTIONS:-}" = "true" ]; }
mask() { if in_actions; then printf '::add-mask::%s\n' "$1"; fi; }
# Always on stderr: several callers run inside `$(…)`, where stdout is captured
# and an annotation would be swallowed instead of shown.
die() {
  if in_actions; then printf '::error::%s\n' "$1" >&2; else printf 'Error: %s\n' "$1" >&2; fi
  exit 1
}

# Normalise a boolean input, rejecting anything else so typos fail loudly.
bool() { # name value
  case "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" in
    true) printf 'true' ;;
    false|"") printf 'false' ;;
    *) die "Input '$1' must be true or false (got '$2')." ;;
  esac
}

# ---------------------------------------------------------------------------
# 1. Inputs.
# ---------------------------------------------------------------------------
REPOSITORY="${INPUT_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
REF="${INPUT_REF:-}"
TOKEN="${INPUT_TOKEN:-}"
CHECKOUT_PATH="${INPUT_PATH:-}"
CLEAN="$(bool clean "${INPUT_CLEAN:-true}")"
DEPTH="${INPUT_FETCH_DEPTH:-1}"
FETCH_TAGS="$(bool fetch-tags "${INPUT_FETCH_TAGS:-false}")"
FILTER="${INPUT_FILTER:-}"
SPARSE="${INPUT_SPARSE_CHECKOUT:-}"
SPARSE_CONE="$(bool sparse-checkout-cone-mode "${INPUT_SPARSE_CHECKOUT_CONE_MODE:-true}")"
LFS="$(bool lfs "${INPUT_LFS:-false}")"
SUBMODULES="$(printf '%s' "${INPUT_SUBMODULES:-false}" | tr '[:upper:]' '[:lower:]')"
SAFE_DIRECTORY="$(bool set-safe-directory "${INPUT_SET_SAFE_DIRECTORY:-true}")"
PERSIST="$(bool persist-credentials "${INPUT_PERSIST_CREDENTIALS:-true}")"
PROGRESS="$(bool show-progress "${INPUT_SHOW_PROGRESS:-true}")"
SERVER_URL="${INPUT_GITHUB_SERVER_URL:-${GITHUB_SERVER_URL:-https://github.com}}"
SERVER_URL="${SERVER_URL%/}"

[ -n "${REPOSITORY}" ] || die "Input 'repository' is required (no GITHUB_REPOSITORY to fall back on)."
case "${REPOSITORY}" in
  */*/*|/*|*" "*|"") die "Input 'repository' must be 'owner/repo' (got '${REPOSITORY}')." ;;
  */*) ;;
  *) die "Input 'repository' must be 'owner/repo' (got '${REPOSITORY}')." ;;
esac

case "${DEPTH}" in
  ''|*[!0-9]*) die "Input 'fetch-depth' must be a non-negative integer (got '${DEPTH}')." ;;
esac

case "${SUBMODULES}" in
  true|false|recursive) ;;
  "") SUBMODULES=false ;;
  *) die "Input 'submodules' must be false, true or recursive (got '${SUBMODULES}')." ;;
esac

REMOTE_URL="${SERVER_URL}/${REPOSITORY}"
AUTH_KEY="http.${SERVER_URL}/.extraheader"

# ---------------------------------------------------------------------------
# 2. Where to check out. Anything outside the workspace is refused: a `path` of
#    `../..` would otherwise let a workflow write over the runner's own files.
# ---------------------------------------------------------------------------
WORKSPACE="${GITHUB_WORKSPACE:-${PWD}}"
[ -d "${WORKSPACE}" ] || mkdir -p "${WORKSPACE}"
WORKSPACE="$(cd "${WORKSPACE}" && pwd -P)"

case "${CHECKOUT_PATH}" in
  "") DIR="${WORKSPACE}" ;;
  /*) DIR="${CHECKOUT_PATH}" ;;
  *)  DIR="${WORKSPACE}/${CHECKOUT_PATH}" ;;
esac
mkdir -p "${DIR}"
DIR="$(cd "${DIR}" && pwd -P)"
case "${DIR}" in
  "${WORKSPACE}"|"${WORKSPACE}"/*) ;;
  *) die "Input 'path' must resolve inside GITHUB_WORKSPACE (${WORKSPACE}); got '${DIR}'." ;;
esac

# Container jobs and reused runners hit "dubious ownership" without this.
if [ "${SAFE_DIRECTORY}" = true ]; then
  if ! git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "${DIR}"; then
    git config --global --add safe.directory "${DIR}"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Which commit. The workflow's own ref/sha only describe the repo the
#    workflow runs in — for anything else they are meaningless.
# ---------------------------------------------------------------------------
COMMIT=""
if [ "${REPOSITORY}" = "${GITHUB_REPOSITORY:-}" ]; then
  if [ -z "${REF}" ]; then
    REF="${GITHUB_REF:-}"
    COMMIT="${GITHUB_SHA:-}"
  elif [ "${REF}" = "${GITHUB_REF:-}" ]; then
    # Same ref, so the event's sha is the exact commit that triggered us —
    # notably the merge commit for `refs/pull/N/merge`.
    COMMIT="${GITHUB_SHA:-}"
  fi
fi

if [[ "${REF}" =~ ^[0-9a-fA-F]{40}$ ]]; then
  COMMIT="${REF}"
  REF=""
fi

# ---------------------------------------------------------------------------
# 4. Prepare the directory: reuse a checkout of the same repository, otherwise
#    start from an empty one.
# ---------------------------------------------------------------------------
reuse=false
if [ -d "${DIR}/.git" ]; then
  existing="$(git -C "${DIR}" config --local --get remote.origin.url 2>/dev/null || true)"
  if [ "${existing%.git}" = "${REMOTE_URL%.git}" ]; then
    reuse=true
  fi
fi

# A composite action loaded from the workspace (`uses: ./.action`) lives inside
# the directory it is about to empty — and bash reads a script as it runs, so
# deleting it mid-flight breaks the very checkout in progress. Never remove the
# running action's own files.
SELF=""
if [ -n "${GITHUB_ACTION_PATH:-}" ] && [ -d "${GITHUB_ACTION_PATH}" ]; then
  SELF="$(cd "${GITHUB_ACTION_PATH}" && pwd -P)"
fi

# The top-level entry of DIR that contains the running action, if any.
self_entry=""
if [ -n "${SELF}" ]; then
  case "${SELF}" in
    "${DIR}"/*)
      rest="${SELF#"${DIR}"/}"
      self_entry="${DIR}/${rest%%/*}"
      ;;
  esac
fi

if [ "${reuse}" = true ]; then
  echo "Reusing existing checkout in ${DIR}"
  if [ "${CLEAN}" = true ]; then
    clean_args=(clean -ffdx)
    if [ -n "${self_entry}" ]; then clean_args+=(-e "/${self_entry#"${DIR}"/}"); fi
    git -C "${DIR}" "${clean_args[@]}"
    git -C "${DIR}" reset --hard HEAD >/dev/null 2>&1 || true
  fi
else
  if [ -n "$(ls -A "${DIR}" 2>/dev/null)" ]; then
    # A runner workspace is disposable, so emptying it is expected. A developer's
    # working copy is not — refuse rather than delete uncommitted work.
    if ! in_actions && [ "${GIT_CHECKOUT_ALLOW_WIPE:-}" != "1" ]; then
      die "${DIR} is not empty and is not a checkout of ${REMOTE_URL}. Outside of Actions, set GIT_CHECKOUT_ALLOW_WIPE=1 to empty it."
    fi
    echo "Emptying ${DIR}"
    if [ -n "${self_entry}" ]; then
      echo "Keeping ${self_entry}: the running action lives there."
    fi
    while IFS= read -r entry; do
      if [ -n "${self_entry}" ] && [ "${entry}" = "${self_entry}" ]; then continue; fi
      rm -rf "${entry}"
    done < <(find "${DIR}" -mindepth 1 -maxdepth 1)
  fi
  git -c init.defaultBranch=main -C "${DIR}" init -q
fi

git -C "${DIR}" config --local gc.auto 0
if git -C "${DIR}" remote get-url origin >/dev/null 2>&1; then
  git -C "${DIR}" remote set-url origin "${REMOTE_URL}"
else
  git -C "${DIR}" remote add origin "${REMOTE_URL}"
fi

# ---------------------------------------------------------------------------
# 5. Auth. Same mechanism as actions/checkout: a basic-auth header in the local
#    config, which later `git push` steps inherit when credentials persist.
# ---------------------------------------------------------------------------
git -C "${DIR}" config --local --unset-all "${AUTH_KEY}" 2>/dev/null || true
if [ -n "${TOKEN}" ]; then
  BASIC="$(printf 'x-access-token:%s' "${TOKEN}" | base64 | tr -d '\n')"
  mask "${BASIC}"
  git -C "${DIR}" config --local "${AUTH_KEY}" "AUTHORIZATION: basic ${BASIC}"
fi

# ---------------------------------------------------------------------------
# 6. Resolve the ref against the remote.
# ---------------------------------------------------------------------------
# First matching branch, else first matching (non-peeled) tag.
remote_full_ref() { # short-name
  local out full
  out="$(git -C "${DIR}" ls-remote --quiet origin "refs/heads/$1" "refs/tags/$1" 2>/dev/null || true)"
  full="$(printf '%s\n' "${out}" | awk '$2 ~ /^refs\/heads\// { print $2; exit }')"
  if [ -z "${full}" ]; then
    full="$(printf '%s\n' "${out}" | awk '$2 ~ /^refs\/tags\// && $2 !~ /\^\{\}$/ { print $2; exit }')"
  fi
  if [ -z "${full}" ]; then return 1; fi
  printf '%s' "${full}"
}

default_branch_ref() {
  git -C "${DIR}" ls-remote --symref origin HEAD 2>/dev/null \
    | awk '$1 == "ref:" { print $2; exit }'
}

FULL_REF=""
case "${REF}" in
  refs/*) FULL_REF="${REF}" ;;
  "")
    if [ -z "${COMMIT}" ]; then
      FULL_REF="$(default_branch_ref)"
      [ -n "${FULL_REF}" ] || die "Could not determine the default branch of ${REMOTE_URL}."
    fi
    ;;
  *)
    FULL_REF="$(remote_full_ref "${REF}")" \
      || die "Ref '${REF}' was not found in ${REMOTE_URL} (as a branch or a tag)."
    ;;
esac

# Where the fetched ref lands locally, and whether we end up on a local branch.
BRANCH=""
LOCAL_REF=""
case "${FULL_REF}" in
  refs/heads/*) BRANCH="${FULL_REF#refs/heads/}"; LOCAL_REF="refs/remotes/origin/${BRANCH}" ;;
  refs/pull/*)  LOCAL_REF="refs/remotes/pull/${FULL_REF#refs/pull/}" ;;
  refs/*)       LOCAL_REF="${FULL_REF}" ;;
esac

# ---------------------------------------------------------------------------
# 7. Fetch.
# ---------------------------------------------------------------------------
fetch_args=(--no-recurse-submodules --prune)
if [ "${PROGRESS}" = true ]; then fetch_args+=(--progress); fi
if [ "${DEPTH}" -gt 0 ]; then
  fetch_args+=("--depth=${DEPTH}")
elif [ -f "${DIR}/.git/shallow" ]; then
  # fetch-depth: 0 over a previously shallow checkout must fill in the history.
  fetch_args+=(--unshallow)
fi
if [ "${FETCH_TAGS}" = true ]; then fetch_args+=(--tags); else fetch_args+=(--no-tags); fi
if [ -n "${FILTER}" ]; then fetch_args+=("--filter=${FILTER}"); fi

# Fetching the commit itself pins the checkout to the exact sha even if the
# branch moved mid-run. Servers may refuse it (uploadpack.allowAnySHA1InWant),
# so fall back to fetching the ref.
if [ -n "${COMMIT}" ] && [ -n "${LOCAL_REF}" ]; then
  refspec="+${COMMIT}:${LOCAL_REF}"
elif [ -n "${COMMIT}" ]; then
  refspec="${COMMIT}"
else
  refspec="+${FULL_REF}:${LOCAL_REF}"
fi

echo "Fetching ${REMOTE_URL} ${refspec}"
if ! git -C "${DIR}" fetch "${fetch_args[@]}" origin "${refspec}"; then
  if [ -n "${FULL_REF}" ] && [ "${refspec}" != "+${FULL_REF}:${LOCAL_REF}" ]; then
    echo "Fetching a bare commit was rejected; falling back to ${FULL_REF}"
    git -C "${DIR}" fetch "${fetch_args[@]}" origin "+${FULL_REF}:${LOCAL_REF}"
  else
    die "Failed to fetch ${refspec} from ${REMOTE_URL}."
  fi
fi

# ---------------------------------------------------------------------------
# 8. Sparse checkout, applied before the working tree is written.
# ---------------------------------------------------------------------------
if [ -n "${SPARSE}" ]; then
  sparse_args=(set)
  if [ "${SPARSE_CONE}" = true ]; then sparse_args+=(--cone); else sparse_args+=(--no-cone); fi
  while IFS= read -r pattern; do
    case "${pattern}" in ""|"#"*) continue ;; esac
    sparse_args+=("${pattern}")
  done <<< "${SPARSE}"
  git -C "${DIR}" sparse-checkout "${sparse_args[@]}"
elif [ "$(git -C "${DIR}" config --get core.sparseCheckout 2>/dev/null || true)" = "true" ]; then
  # Not `--local`: git records this in the per-worktree config once
  # extensions.worktreeConfig is on, which --local does not read.
  git -C "${DIR}" sparse-checkout disable
fi

# ---------------------------------------------------------------------------
# 9. Checkout.
# ---------------------------------------------------------------------------
checkout_args=(checkout --force)
if [ "${PROGRESS}" = true ]; then checkout_args+=(--progress); fi

if [ -n "${BRANCH}" ]; then
  checkout_args+=(-B "${BRANCH}" "${LOCAL_REF}")
elif [ -n "${LOCAL_REF}" ]; then
  checkout_args+=(--detach "${LOCAL_REF}")
else
  checkout_args+=(--detach "${COMMIT}")
fi
git -C "${DIR}" "${checkout_args[@]}"

if [ -n "${BRANCH}" ]; then
  git -C "${DIR}" branch --set-upstream-to "${LOCAL_REF}" "${BRANCH}" >/dev/null 2>&1 || true
fi

RESOLVED="$(git -C "${DIR}" rev-parse HEAD)"

# ---------------------------------------------------------------------------
# 10. LFS and submodules.
# ---------------------------------------------------------------------------
if [ "${LFS}" = true ]; then
  command -v git-lfs >/dev/null 2>&1 || die "Input 'lfs' is true but git-lfs is not installed."
  git -C "${DIR}" lfs install --local
  git -C "${DIR}" lfs pull
fi

if [ "${SUBMODULES}" != false ]; then
  sub_args=(submodule update --init --force)
  sync_args=(submodule sync)
  each_args=(submodule foreach)
  if [ "${SUBMODULES}" = recursive ]; then
    sub_args+=(--recursive)
    sync_args+=(--recursive)
    each_args+=(--recursive)
  fi
  if [ "${DEPTH}" -gt 0 ]; then sub_args+=("--depth=${DEPTH}"); fi

  git -C "${DIR}" "${sync_args[@]}"
  if [ -n "${TOKEN}" ]; then
    # Submodule fetches are child processes and do not inherit the superproject's
    # local config, so the header has to be handed to them explicitly.
    git -C "${DIR}" -c "${AUTH_KEY}=AUTHORIZATION: basic ${BASIC}" "${sub_args[@]}"
    if [ "${PERSIST}" = true ]; then
      git -C "${DIR}" "${each_args[@]}" \
        git config --local "${AUTH_KEY}" "AUTHORIZATION: basic ${BASIC}" >/dev/null
    fi
  else
    git -C "${DIR}" "${sub_args[@]}"
  fi
fi

# ---------------------------------------------------------------------------
# 11. Credentials and outputs.
# ---------------------------------------------------------------------------
if [ "${PERSIST}" != true ]; then
  git -C "${DIR}" config --local --unset-all "${AUTH_KEY}" 2>/dev/null || true
  if [ "${SUBMODULES}" != false ]; then
    git -C "${DIR}" submodule foreach --recursive \
      git config --local --unset-all "${AUTH_KEY}" >/dev/null 2>&1 || true
  fi
fi

echo "Checked out ${FULL_REF:-${COMMIT}} at ${RESOLVED} in ${DIR}"
emit ref "${FULL_REF:-${COMMIT}}"
emit commit "${RESOLVED}"
emit path "${DIR}"
