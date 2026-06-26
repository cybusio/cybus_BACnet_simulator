#!/usr/bin/env bash
# Doc-drift guard — fails if the docs and the repo have drifted apart.
#   1. every tracked fleet compose is named in README.md
#   2. every path the docs call "committed" is actually git-tracked
#   3. every qa/ script TESTING.md references exists on disk
# Run by pre-commit; also runnable directly: bash qa/tools/check-docs.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
fail=0

# 1. tracked fleet composes must appear in the README fleet table (by stem)
for c in $(git ls-files 'compose/*.compose.yaml'); do
  stem="$(basename "$c" .compose.yaml)"
  grep -q "$stem" README.md || { echo "DRIFT: compose/$stem.compose.yaml is tracked but missing from README.md"; fail=1; }
done

# 2. the one committed scenario SCF the docs promise must be tracked
if grep -qs 'zz_objectlist' README.md TESTING.md; then
  git ls-files --error-unmatch qa/scf/zz_objectlist.yml >/dev/null 2>&1 \
    || { echo "DRIFT: docs call qa/scf/zz_objectlist.yml committed, but it is not git-tracked"; fail=1; }
fi

# 3. every qa/<dir>/<script> path TESTING.md references must exist
for p in $(grep -oE 'qa/[a-z]+/[a-z0-9_./-]+\.(sh|py)' TESTING.md | sort -u); do
  [ -e "$p" ] || { echo "DRIFT: TESTING.md references $p which does not exist"; fail=1; }
done

# 4. no stale pre-reorg path prefixes leaked into the docs or the harness
stale="$(grep -rnE '\b(scripts|simulator-tests)/' docs qa README.md TESTING.md CONTRIBUTING.md \
          --include='*.md' --include='*.sh' --include='*.js' --include='*.py' 2>/dev/null \
          | grep -vE 'protocol-mapper/|check-docs.sh')"
if [ -n "$stale" ]; then
  echo "DRIFT: stale 'scripts/' or 'simulator-tests/' path prefix (these dirs were moved under qa/):"
  echo "$stale" | head -5
  fail=1
fi

if [ "$fail" -eq 0 ]; then echo "check-docs: OK"; else echo "check-docs: FAILED — fix the docs or the paths above"; fi
exit "$fail"
