#!/usr/bin/env bash
set -euo pipefail

skill_source="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
skill_test_root="$(mktemp -d "${TMPDIR:-/tmp}/modelrelay-skill-tests.XXXXXX")"
trap 'rm -r -- "$skill_test_root" < /dev/null' EXIT
skill_fixture="$skill_test_root/repo"

write_fixture() {
    rm -rf "$skill_fixture"
    mkdir -p "$skill_fixture/Scripts" "$skill_fixture/Sources/ModelRelay" "$skill_fixture/Documentation" \
        "$skill_fixture/skills/modelrelay/references" "$skill_fixture/.claude-plugin"
    cp "$skill_source/Scripts/check-skill.sh" "$skill_fixture/Scripts/check-skill.sh"
    printf '.library(name: "ModelRelay", targets: ["ModelRelay"]),\n' > "$skill_fixture/Package.swift"
    printf 'public struct Step {\n    public static func prompt() {}\n}\npublic enum ModelLocation {\n    case local, remote\n}\n' \
        > "$skill_fixture/Sources/ModelRelay/API.swift"
    printf '# Usage\n\n<a name="step-types"></a>\n\n## Steps\n' > "$skill_fixture/Documentation/Usage.md"
    printf -- '---\nname: modelrelay\ndescription: Use ModelRelay in host apps.\n---\n\n# Skill\n\nImport `ModelRelay`, then use `Step.prompt` and `.remote`.\nRead `Documentation/Usage.md#step-types` and [the map](references/api-map.md).\n\n```swift\n`NotChecked.inCode`\n```\n' \
        > "$skill_fixture/skills/modelrelay/SKILL.md"
    printf '# Map\n\n| Need | API |\n| --- | --- |\n| Text | `Step.prompt("a", "b")` |\n' \
        > "$skill_fixture/skills/modelrelay/references/api-map.md"
    printf '{"name": "modelrelay", "description": "Skill."}\n' > "$skill_fixture/.claude-plugin/plugin.json"
    printf '{"name": "modelrelay", "owner": {"name": "Tests"}, "plugins": [{"name": "modelrelay", "source": "./"}]}\n' \
        > "$skill_fixture/.claude-plugin/marketplace.json"
}

expect_valid() {
    bash "$skill_fixture/Scripts/check-skill.sh" > /dev/null 2> "$skill_test_root/error" || {
        echo "Unexpected rejection: $(< "$skill_test_root/error")" >&2
        exit 1
    }
}

expect_invalid() {
    if bash "$skill_fixture/Scripts/check-skill.sh" > /dev/null 2> "$skill_test_root/error"; then
        echo "Unexpectedly accepted: $1" >&2
        exit 1
    fi
    [[ "$(< "$skill_test_root/error")" == *"$1"* ]] || {
        echo "Unexpected rejection: $(< "$skill_test_root/error")" >&2
        exit 1
    }
}

append_skill() {
    printf '%s\n' "$1" >> "$skill_fixture/skills/modelrelay/SKILL.md"
}

write_fixture
expect_valid

append_skill 'Then call `Step.vanished`.'
expect_invalid 'unknown member `Step.vanished`'

write_fixture
append_skill 'Configure `MissingType`.'
expect_invalid 'unknown type `MissingType`'

write_fixture
append_skill 'See `Documentation/Usage.md#gone`.'
expect_invalid 'missing anchor Documentation/Usage.md#gone'

write_fixture
append_skill 'See `Documentation/Models.md`.'
expect_invalid 'references missing Documentation/Models.md'

write_fixture
append_skill 'See [pitfalls](references/pitfalls.md).'
expect_invalid 'links to missing references/pitfalls.md'

write_fixture
append_skill 'Prose — with an em dash.'
expect_invalid 'uses an em dash'

write_fixture
sed -i.bak 's/^name: modelrelay$/name: relay/' "$skill_fixture/skills/modelrelay/SKILL.md"
expect_invalid 'frontmatter name must be modelrelay'

write_fixture
printf '{"name": "modelrelay", "description": "Skill.", "version": "1.0.0"}\n' > "$skill_fixture/.claude-plugin/plugin.json"
expect_invalid 'do not add a version field'

write_fixture
printf '{"name": "modelrelay", "plugins": [{"name": "modelrelay", "source": "./skills"}]}\n' \
    > "$skill_fixture/.claude-plugin/marketplace.json"
expect_invalid 'list the plugin once with source ./'

echo "Skill check tests passed."
