#!/usr/bin/env bash
set -euo pipefail

release_source="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
release_test_root="$(mktemp -d "${TMPDIR:-/tmp}/modelrelay-release-tests.XXXXXX")"
trap 'rm -r -- "$release_test_root" < /dev/null' EXIT
release_fixture="$release_test_root/repo"
mkdir -p "$release_fixture/Scripts"
cp "$release_source/Scripts/check-release.sh" "$release_fixture/Scripts/check-release.sh"
cp "$release_source/Package.swift" "$release_fixture/Package.swift"
cp "$release_source/LICENSE" "$release_fixture/LICENSE"
git init --quiet --initial-branch=main "$release_fixture"
git -C "$release_fixture" config user.name 'Release tests'
git -C "$release_fixture" config user.email 'release-tests@example.invalid'
git -C "$release_fixture" config commit.gpgsign false
git -C "$release_fixture" config core.hooksPath /dev/null

commit_fixture() {
    git -C "$release_fixture" add -A
    git -C "$release_fixture" commit --quiet --allow-empty -m 'Release fixture'
}

write_changelog() {
    printf '# Changelog\n\n## [Unreleased]\n\n## [%s] - 2026-10-18\n\n- Release notes.\n\n## [0.0.1] - 2026-10-17\n\n- Older notes.\n' "$1" > "$release_fixture/CHANGELOG.md"
    commit_fixture
}

expect_valid() {
    bash "$release_fixture/Scripts/check-release.sh" "$1" > "$release_test_root/notes" 2> "$release_test_root/error"
    [[ "$(< "$release_test_root/notes")" == *'Release notes.'* ]]
    [[ "$(< "$release_test_root/notes")" != *'Older notes.'* ]]
}

expect_invalid() {
    if bash "$release_fixture/Scripts/check-release.sh" "$1" > "$release_test_root/notes" 2> "$release_test_root/error"; then
        echo "Unexpectedly accepted release: $1" >&2
        exit 1
    fi
    [[ "$(< "$release_test_root/error")" == *"$2"* ]] || {
        echo "Unexpected rejection: $(< "$release_test_root/error")" >&2
        exit 1
    }
}

for release_version in 0.1.0 0.1.1 1.0.0 42.123.9 0.2.0-beta.1 0.2.0-rc.1 1.0.0-alpha.0 1.0.0-01a; do
    write_changelog "$release_version"
    expect_valid "$release_version"
done

expect_invalid '' 'usage:'
for release_version in v0.1.0 1 1.2 01.1.0 1.01.0 1.0.01 1.0.0-01 1.0.0-alpha.01 1.0.0- 1.0.0+build.1 '1.0.0;echo bad'; do
    expect_invalid "$release_version" 'use a SemVer tag'
done

expect_invalid 9.9.9 'add one dated changelog section'
printf '## [0.1.0] - someday\n\n- Notes.\n' > "$release_fixture/CHANGELOG.md"
commit_fixture
expect_invalid 0.1.0 'release date must use YYYY-MM-DD'

printf '## [0.1.0] - 2026-10-18\n\n' > "$release_fixture/CHANGELOG.md"
commit_fixture
expect_invalid 0.1.0 'release section is empty'

write_changelog 0.1.0
printf '\n## [0.1.0] - 2026-10-18\n\n- Duplicate notes.\n' >> "$release_fixture/CHANGELOG.md"
commit_fixture
expect_invalid 0.1.0 'add one dated changelog section'

write_changelog 0.1.0
printf '\nPending change\n' >> "$release_fixture/CHANGELOG.md"
expect_invalid 0.1.0 'pending changes'
commit_fixture
printf 'Untracked\n' > "$release_fixture/pending"
expect_invalid 0.1.0 'pending changes'
commit_fixture

git -C "$release_fixture" switch --quiet -c feature
expect_invalid 0.1.0 'prepare releases on main'
git -C "$release_fixture" switch --quiet main

printf 'Different license\n' > "$release_fixture/LICENSE"
commit_fixture
expect_invalid 0.1.0 'retain its MIT license'
cp "$release_source/LICENSE" "$release_fixture/LICENSE"
commit_fixture

git -C "$release_fixture" -c tag.gpgsign=false tag -a 0.1.0 -m 'Release fixture'
expect_valid 0.1.0
git -C "$release_fixture" switch --quiet --detach 0.1.0
expect_valid 0.1.0
git -C "$release_fixture" switch --quiet main
commit_fixture
expect_invalid 0.1.0 'never move a published tag'

echo 'Release metadata tests passed.'
