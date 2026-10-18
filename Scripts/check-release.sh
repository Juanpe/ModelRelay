#!/usr/bin/env bash
set -euo pipefail

fail() {
    echo "Release check: $*" >&2
    exit 1
}

[[ $# == 1 && -n "$1" ]] || fail "usage: bash Scripts/check-release.sh MAJOR.MINOR.PATCH[-prerelease]"
release_version="$1"
release_number='(0|[1-9][0-9]*)'
release_identifier='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
release_pattern="^$release_number\\.$release_number\\.$release_number(-$release_identifier(\\.$release_identifier)*)?$"
[[ "$release_version" =~ $release_pattern ]] || fail "use a SemVer tag without a v prefix or build metadata"

release_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$release_root"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "not a Git checkout"
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || fail "commit or set aside pending changes before releasing"
release_branch="$(git branch --show-current)"
[[ -z "$release_branch" || "$release_branch" == main ]] || fail "prepare releases on main"

if git show-ref --verify --quiet "refs/tags/$release_version"; then
    [[ "$(git rev-parse "$release_version^{commit}")" == "$(git rev-parse HEAD)" ]] || fail "tag $release_version points to another commit; never move a published tag"
fi

[[ -f Package.swift && -f LICENSE && -f CHANGELOG.md ]] || fail "Package.swift, LICENSE and CHANGELOG.md are required"
[[ "$(head -n 1 LICENSE)" == 'MIT License' ]] || fail "the package must retain its MIT license"

release_heading="## [$release_version] - "
release_count="$(awk -v heading="$release_heading" 'index($0, heading) == 1 { count++ } END { print count + 0 }' CHANGELOG.md)"
[[ "$release_count" == 1 ]] || fail "add one dated changelog section: $release_heading"'YYYY-MM-DD'
release_date="$(awk -v heading="$release_heading" 'index($0, heading) == 1 { print substr($0, length(heading) + 1) }' CHANGELOG.md)"
[[ "$release_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail "the changelog release date must use YYYY-MM-DD"

release_notes="$(awk -v heading="$release_heading" '
    index($0, heading) == 1 { found = 1; next }
    found && /^## / { exit }
    found { print }
' CHANGELOG.md)"
[[ -n "${release_notes//[[:space:]]/}" ]] || fail "the changelog release section is empty"

printf '%s\n' "$release_notes"
echo "Release metadata for $release_version is valid. Swift tests must be verified separately." >&2
