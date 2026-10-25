#!/usr/bin/env bash
# Bind the application and framework artifacts a live qualification exercises to
# the exact immutable candidate revision it gathers evidence for.
#
# An installed release names the revision it was built from
# (`share/sol/<version>/REVISION`, written by build-release-bundle.sh). A live run
# must build the application under test from that revision:
#
#   * the application is materialized **from the candidate revision**, never from
#     the working tree, so no working-tree state can substitute another
#     revision's code;
#   * every pin that fetches the Sol framework must name that commit, never a
#     moving ref such as `main`.
#
# The *harness* may run from the candidate revision or any descendant of it. A
# harness fix merged after a tag has to be usable on that tag's window, or every
# fix would force a new candidate and the harness would never converge (sol-fab/sol#1451).
# The working tree must still be clean, so the harness that produced the evidence
# is a revision rather than a state; that revision is recorded with the binding.
#
# Two provider verdicts on one tag are the same apparatus only if they name the
# same harness revision. A run whose harness revision differs from the other
# provider's for the same candidate has not met "one tag, two providers", and the
# records have to say so.
#
# Otherwise a stale checkout -- or a `main` that advanced after the candidate was
# cut -- can substitute another revision's framework or application code while the
# run reports evidence bound to this candidate. Every check fails closed; nothing
# is built when a check refuses (sol-fab/sol#1280).

sol_candidate_die() {
  printf 'candidate-binding: %s\n' "$1" >&2
}

sol_candidate_is_revision() {
  case "${1:-}" in
    "" | *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 40 ]
}

# sol_candidate_bind_context <workspace> <revision> <out>
#
# Materialize a Docker build context at <out> holding the tracked files of
# <workspace> at <revision>, with every `github.com/sol-fab/sol.git#<ref>` pin
# rewritten to `#<revision>`. Prints one line per framework pin it bound, for the
# run's evidence. Refuses, changing nothing, when the workspace is not that
# revision's unmodified tree or when the framework cannot be shown to come from it.
sol_candidate_bind_context() {
  local source="${1:-}" revision="${2:-}" out="${3:-}"
  if [ -z "$source" ] || [ -z "$out" ]; then
    sol_candidate_die "usage: sol_candidate_bind_context <workspace> <revision> <out>"
    return 1
  fi
  if [ ! -d "$source" ]; then
    sol_candidate_die "no workspace at '$source' to bind to the candidate"
    return 1
  fi
  if ! sol_candidate_is_revision "$revision"; then
    sol_candidate_die "the release names revision '$revision', which is not a 40-hex commit"
    return 1
  fi
  local head
  if ! head="$(git -C "$source" rev-parse HEAD 2>/dev/null)"; then
    sol_candidate_die "'$source' is not a git work tree, so it cannot be shown to be the candidate revision $revision"
    return 1
  fi
  if ! git -C "$source" merge-base --is-ancestor "$revision" "$head"; then
    sol_candidate_die "the workspace is at $head, which is neither the candidate revision $revision nor a descendant of it; the harness may move forward from the candidate, never away from it"
    return 1
  fi
  if [ -n "$(git -C "$source" status --porcelain --untracked-files=no)" ]; then
    sol_candidate_die "'$source' has modified tracked files, so the harness revision cannot be named: commit them, or cut a candidate that contains them"
    return 1
  fi

  # From the candidate revision, not from the working tree: that is what keeps a harness that has
  # moved forward from changing the application under test.
  rm -rf "$out"
  mkdir -p "$out"
  if ! git -C "$source" archive "$revision" | tar -x -C "$out"; then
    sol_candidate_die "could not materialize revision $revision from $source"
    return 1
  fi
  # The caller may run under a restrictive umask (the qualification harness does),
  # and tar applies it to extracted entries. The build context is source, not a
  # secret: restore read and traverse bits so non-root build stages can read it.
  chmod -R a+rX "$out"

  local file
  while IFS= read -r -d '' file; do
    sed -i -E "s|(github\.com/sol-fab/sol\.git)#[^\"[:space:]]+|\1#$revision|g" "$file"
  done < <(find "$out" -type f -name '*.opam' -print0)

  local refs stale="" count=0 ref
  refs="$(grep -rIho 'github\.com/sol-fab/sol\.git#[^"[:space:]]*' "$out" 2>/dev/null || true)"
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    count=$((count + 1))
    if [ "$ref" != "github.com/sol-fab/sol.git#$revision" ]; then
      stale="$ref"
    fi
  done <<<"$refs"
  if [ -n "$stale" ]; then
    sol_candidate_die "the build context still fetches the Sol framework from $stale, not from the candidate revision $revision"
    return 1
  fi
  if [ "$count" -eq 0 ]; then
    sol_candidate_die "the build context pins no Sol framework revision, so the framework it builds against cannot be shown to be the candidate's"
    return 1
  fi
  printf '%s\n' "$refs"
}

# sol_candidate_record_binding <dir> <revision> <workspace> <context> [pins] [harness]
#
# Write the binding the run actually enforced beside its other evidence.
#
# [harness] is the revision the harness itself ran from; it must be [revision] or a descendant
# of it, and two providers' records for one candidate must name the same one (#1451).
sol_candidate_record_binding() {
  local dir="${1:-}" revision="${2:-}" workspace="${3:-}" context="${4:-}"
  local pins="${5:-}" harness="${6:-}"
  mkdir -p "$dir"
  {
    printf 'candidate_revision: %s\n' "$revision"
    printf 'harness_revision: %s\n' "${harness:-$revision}"
    printf 'workspace: %s\n' "$workspace"
    printf 'build_context: %s\n' "$context"
    printf 'framework_pins:\n'
    if [ -n "$pins" ]; then printf '%s\n' "$pins" | sed 's/^/  /'; fi
  } >"$dir/candidate-binding.txt"
}
