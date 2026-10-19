#!/usr/bin/env bash

scratch_repo_leak_vars() {
  local name
  for name in $(git rev-parse --local-env-vars 2>/dev/null); do
    if [ -n "${!name+set}" ]; then
      printf '%s=%s\n' "$name" "${!name}"
    fi
  done
}

scratch_repo_sanitize() {
  local name
  for name in $(git rev-parse --local-env-vars 2>/dev/null); do
    unset "$name"
  done
}

scratch_repo_git_dir() { git -C "$1" rev-parse --absolute-git-dir 2>/dev/null; }

scratch_repo_inside() {
  local scratch_real git_dir_real
  scratch_real="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  git_dir_real="$(cd "$2" 2>/dev/null && pwd -P)" || git_dir_real="$2"
  case "$git_dir_real" in
    "$scratch_real" | "$scratch_real"/*) return 0 ;;
    *) return 1 ;;
  esac
}

scratch_repo_assert() {
  local scratch="$1" git_dir
  if ! git_dir="$(scratch_repo_git_dir "$scratch")"; then
    printf 'scratch-repo: %s does not resolve to a git repository\n' "$scratch" >&2
    return 1
  fi
  if ! scratch_repo_inside "$scratch" "$git_dir"; then
    printf 'scratch-repo: git in %s resolves to %s, outside the scratch directory\n' \
      "$scratch" "$git_dir" >&2
    return 1
  fi
}

scratch_repo_init() {
  local scratch="$1"
  shift
  local leaked
  leaked="$(scratch_repo_leak_vars | tr '\n' ' ')"
  leaked="${leaked% }"
  if [ -n "$leaked" ]; then
    printf 'scratch-repo: refusing to create %s while a Git-invoked process has repository-local variables set (%s); run this outside a hook or unset them\n' \
      "$scratch" "$leaked" >&2
    return 1
  fi
  mkdir -p "$scratch"
  git -C "$scratch" init -q "$@"
  # A commit can leave a detached `git maintenance run --auto` writing into
  # .git/objects/pack after the command returns. These repositories are removed
  # immediately after their scenario, so that write races `rm -rf` and fails the
  # test cleanup with "Directory not empty". A scratch repository needs no
  # background maintenance; disable it at the only place they are created.
  git -C "$scratch" config maintenance.auto false
  git -C "$scratch" config gc.auto 0
  scratch_repo_assert "$scratch"
}
