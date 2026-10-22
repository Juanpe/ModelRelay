#!/usr/bin/env bash
set -euo pipefail

# Keeps the agent skill and plugin manifests in sync with the package: guide
# paths and anchors must exist, and backticked API names must still be declared
# in Sources. Code blocks are not compiled; keep snippets short and documented.

fail_count=0
fail() {
    echo "Skill check: $*" >&2
    fail_count=$((fail_count + 1))
}

skill_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$skill_root"
skill_dir="skills/modelrelay"
skill_file="$skill_dir/SKILL.md"
[[ -f "$skill_file" ]] || { echo "Skill check: $skill_file is missing" >&2; exit 1; }
skill_files=("$skill_file")
while IFS= read -r reference; do skill_files+=("$reference"); done < <(find "$skill_dir/references" -name '*.md' 2>/dev/null | sort)

# Frontmatter: the name matches the folder; the description is what agents match on.
frontmatter="$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$skill_file")"
skill_name="$(sed -n 's/^name: *//p' <<< "$frontmatter")"
skill_description="$(sed -n 's/^description: *//p' <<< "$frontmatter")"
[[ "$skill_name" == "$(basename "$skill_dir")" ]] || fail "frontmatter name must be $(basename "$skill_dir")"
[[ -n "$skill_description" ]] || fail "frontmatter needs a one-line description"
(( ${#skill_description} <= 1024 )) || fail "description is ${#skill_description} characters; keep it within 1024"
[[ "$skill_description" != *[\<\>]* ]] || fail "description must not contain angle brackets"

# Text outside fenced code blocks; snippets are illustrative and not parsed.
prose() {
    awk '/^```/ { fenced = !fenced; next } !fenced { print }' "$1"
}

for file in "${skill_files[@]}"; do
    ! grep -q '—' "$file" || fail "$file uses an em dash"

    # Relative Markdown links inside the skill folder.
    while IFS= read -r link; do
        [[ -f "$(dirname "$file")/${link%%#*}" ]] || fail "$file links to missing ${link%%#*}"
    done < <(prose "$file" | grep -oE '\]\([^):#]+\.md(#[^)]*)?\)' | sed -E 's/^\]\((.*)\)$/\1/' || true)

    # Checkout paths, optionally with an explicit <a name> anchor.
    while IFS= read -r path; do
        target="${path%%#*}"
        if [[ ! -e "$target" ]]; then
            fail "$file references missing $target"
        elif [[ "$path" == *#* ]] && ! grep -q "<a name=\"${path#*#}\"></a>" "$target"; then
            fail "$file references missing anchor $path"
        fi
    done < <(prose "$file" | grep -oE '(Documentation/[A-Za-z]+\.md|README\.md|CHANGELOG\.md|Examples/[A-Za-z]+|Tests/[A-Za-z/+]+\.swift)(#[a-z0-9-]+)?' | sort -u || true)
done

# Names declared outside this package, plus product modules from Package.swift.
external_names=(
    AnyLanguageModel LanguageModel OllamaLanguageModel OpenAILanguageModel
    OpenResponsesLanguageModel AnthropicLanguageModel MLX .package
    URLProtocol URLSession URLSessionConfiguration
    await defer if public git swift
)
while IFS= read -r product; do external_names+=("$product"); done < <(grep -oE '\.library\(name: "[A-Za-z]+"' Package.swift | sed -E 's/.*"(.*)"/\1/')

declares_type() {
    grep -rqE "public (final |indirect )?(struct|enum|class|actor|protocol|typealias) $1\b" Sources
}
declares_member() {
    grep -rqE "(public (static |nonisolated |final )*(func|let|var) $1\b|^ *case ([a-z][A-Za-z0-9_]*, )*$1\b)" Sources
}

# Backticked API names: `Type`, `Type.member`, `.member` and `member`, ignoring arguments.
while IFS= read -r token; do
    name="${token%%(*}"
    name="${name%% *}"
    [[ " ${external_names[*]} " == *" $name "* ]] && continue
    [[ "$name" =~ \.(md|swift|json|resolved)$ ]] && continue
    if [[ "$name" =~ ^[A-Z][A-Za-z0-9]*$ ]]; then
        declares_type "$name" || fail "unknown type \`$name\`"
    elif [[ "$name" =~ ^([A-Z][A-Za-z0-9]*)?\.([a-z][A-Za-z0-9_]*)$ ]]; then
        type_name="${BASH_REMATCH[1]}"
        member="${BASH_REMATCH[2]}"
        [[ -z "$type_name" || " ${external_names[*]} " == *" $type_name "* ]] || declares_type "$type_name" || fail "unknown type in \`$name\`"
        declares_member "$member" || fail "unknown member \`$name\`"
    elif [[ "$name" =~ ^[a-z][A-Za-z0-9]*$ ]]; then
        declares_member "$name" || fail "unknown member \`$name\`"
    fi
done < <(for file in "${skill_files[@]}"; do prose "$file"; done | grep -oE '`[^`]+`' | tr -d '`' | sort -u)

# Plugin manifests: valid JSON, matching names and a skill the plugin ships.
python3 -I - <<'PYTHON' || fail "plugin manifests are invalid"
import json, sys
plugin = json.load(open(".claude-plugin/plugin.json"))
market = json.load(open(".claude-plugin/marketplace.json"))
entries = [entry for entry in market.get("plugins", []) if entry.get("name") == plugin.get("name")]
problems = []
if not plugin.get("name") or not plugin.get("description"):
    problems.append("plugin.json needs a name and description")
if len(entries) != 1 or entries[0].get("source") != "./":
    problems.append("marketplace.json must list the plugin once with source ./")
if "version" in plugin or any("version" in entry for entry in entries):
    problems.append("Git tags are the version source; do not add a version field")
for problem in problems:
    print("Skill check: " + problem, file=sys.stderr)
sys.exit(1 if problems else 0)
PYTHON

(( fail_count == 0 )) || exit 1
echo "Agent skill and plugin manifests are consistent with the package."
