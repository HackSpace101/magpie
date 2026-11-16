#!/usr/bin/env bash
# .fork/sync.sh <upstream-commit> — makes the commit that brings main to
# upstream's commit, and prints its sha; prints nothing when main has it.
#
# The commit's tree is upstream's, without upstream's .github and without
# its copy of any path .fork/owned lists, plus this repo's copy of those
# paths, and .fork/upstream naming the upstream commit. Its one parent is
# HEAD. It never changes .github, so the workflow's built-in token may push
# it, and it can't conflict, since the fork changes only paths it owns.
# Nothing is checked out or moved: the caller checks the commit and pushes
# it.
set -euo pipefail

up=$(git rev-parse --verify "${1:?usage: .fork/sync.sh <upstream-commit>}^{commit}")
cd "$(git rev-parse --show-toplevel)"
owned=$(git show HEAD:.fork/owned)
last=$(git show HEAD:.fork/upstream 2>/dev/null | tr -d '[:space:]' || true)

index=$(mktemp)
trap 'rm -f "$index"' EXIT
export GIT_INDEX_FILE=$index
git read-tree "$up"
# drop is every path of the index under $1 taken out of it
drop() { git ls-files -z -- "$1" | git update-index -z --force-remove --stdin; }
# upstream's workflows run upstream's jobs; none of its .github is taken
drop .github
while IFS= read -r p; do
	p=${p%%#*}
	p=${p#"${p%%[![:space:]]*}"}
	p=${p%"${p##*[![:space:]]}"}
	[ -n "$p" ] || continue
	drop "$p"
	git ls-tree -r --full-tree HEAD -- "$p" | git update-index --index-info
done <<<"$owned"
blob=$(printf '%s\n' "$up" | git hash-object -w --stdin)
git update-index --add --cacheinfo "100644,$blob,.fork/upstream"
tree=$(git write-tree)
unset GIT_INDEX_FILE

if [ "$tree" = "$(git rev-parse 'HEAD^{tree}')" ]; then
	exit 0
fi
{
	printf 'sync: yetone/magpie@%s\n\n' "${up:0:12}"
	printf 'Upstream: https://github.com/yetone/magpie/commit/%s\n' "$up"
	if [ -n "$last" ] && [ "$last" != "$up" ]; then
		printf 'Changes: https://github.com/yetone/magpie/compare/%s...%s\n' "$last" "$up"
	fi
} | git commit-tree "$tree" -p HEAD
