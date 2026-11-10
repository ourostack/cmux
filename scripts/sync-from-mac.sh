#!/usr/bin/env bash
# Interim sync, run by launchd on Ari's Mac until the hosted workflow has its
# FORK_SYNC_TOKEN. Uses the personal gh login. Actions stay disabled on the
# fork, so these pushes never start upstream workflows.
set -euo pipefail
# A failed step must say where it failed: git's -q hides rejections, so the log would otherwise end at "sync start".
trap 'rc=$?; echo "== $(date -u +%FT%TZ) sync FAILED at line $LINENO (exit $rc)" >&2' ERR
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GH_TOKEN="$(gh auth token -h github.com -u arimendelow)"
echo "== $(date -u +%FT%TZ) sync start"
gh repo sync ourostack/cmux -b main --source manaflow-ai/cmux
# Mirror v* tags that the fork lacks.
cd "$REPO_DIR"
git -c credential.helper= -c "credential.helper=!f() { echo username=x-access-token; echo password=$GH_TOKEN; }; f" \
  fetch -q --force upstream '+refs/tags/v*:refs/tags/v*'
# Upstream sometimes moves a release tag (v0.65.2, 2026-11). This clone follows upstream (--force above); the fork's
# copy is left as it is and named here, so nothing rewrites a tag others may have fetched.
moved=$(join <(git ls-remote --tags upstream 'v*' | grep -v '\^{}$' | awk '{print $2, $1}' | sort) \
             <(git ls-remote --tags origin 'v*' | grep -v '\^{}$' | awk '{print $2, $1}' | sort) | awk '$2 != $3 {print $1}')
if [ -n "$moved" ]; then echo "tags moved upstream, left as they are on the fork: $(echo $moved)"; fi
missing=$(comm -23 <(git ls-remote --tags upstream 'v*' | awk '{print $2}' | grep -v '\^{}$' | sort) \
                   <(git ls-remote --tags origin 'v*' | awk '{print $2}' | grep -v '\^{}$' | sort))
if [ -n "$missing" ]; then
  git -c credential.helper= -c "credential.helper=!f() { echo username=x-access-token; echo password=$GH_TOKEN; }; f" \
    push -q origin $missing
fi
echo "tags pushed: $(echo "$missing" | grep -c . || true)"
# ouro-patches: while the stack is empty, keep it equal to main.
main_sha=$(gh api repos/ourostack/cmux/branches/main --jq .commit.sha)
ahead=$(gh api "repos/ourostack/cmux/compare/main...ouro-patches" --jq .ahead_by)
if [ "$ahead" = "0" ]; then
  gh api -X PATCH repos/ourostack/cmux/git/refs/heads/ouro-patches -f sha="$main_sha" -F force=true --jq .object.sha >/dev/null
  echo "ouro-patches = main ($main_sha)"
else
  echo "ouro-patches has $ahead commits; rebase needs the hosted workflow" >&2
fi
echo "== sync done"
