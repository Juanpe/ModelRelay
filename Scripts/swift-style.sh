#!/usr/bin/env bash
set -euo pipefail

style_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$style_root"

if [[ "$(uname -s)" != Darwin ]]; then
    echo "Swift style checks currently require macOS." >&2
    exit 1
fi

install_tool() {
    local tool="$1" version="$2" url="$3" checksum="$4"
    local cache="$style_root/.tools/$tool/$version"
    local binary="$cache/$tool"
    if [[ ! -x "$binary" ]] || [[ "$("$binary" --version)" != "$version" ]]; then
        mkdir -p "$cache"
        curl --fail --location --silent --show-error --retry 3 "$url" -o "$cache/download.zip"
        local actual
        actual="$(shasum -a 256 "$cache/download.zip" | awk '{print $1}')"
        if [[ "$actual" != "$checksum" ]]; then
            echo "Checksum mismatch for $tool $version." >&2
            exit 1
        fi
        unzip -oq "$cache/download.zip" "$tool" -d "$cache"
        chmod +x "$binary"
    fi
    tool_binary="$binary"
}

format_swift() {
    install_tool swiftformat 0.55.5 \
        https://github.com/nicklockwood/SwiftFormat/releases/download/0.55.5/swiftformat.zip \
        efdd7bde8a3989070d50b41f05745b2af6f771506f6a8317351b5c177a7e9732
    "$tool_binary" . --config "$style_root/.swiftformat" --cache ignore "$@"
}

lint_swift() {
    install_tool swiftlint 0.65.1 \
        https://github.com/realm/SwiftLint/releases/download/0.65.1/portable_swiftlint.zip \
        c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0
    "$tool_binary" lint --config "$style_root/.swiftlint.yml" --strict --no-cache "$@"
}

case "${1:-check}" in
    format) format_swift ;;
    check-format) format_swift --lint ;;
    lint) lint_swift --baseline "$style_root/.swiftlint-baseline.json" ;;
    lint-all) lint_swift ;;
    check)
        format_swift --lint
        lint_swift --baseline "$style_root/.swiftlint-baseline.json"
        ;;
    *)
        echo "Usage: bash Scripts/swift-style.sh {format|check-format|lint|lint-all|check}" >&2
        exit 1
        ;;
esac
