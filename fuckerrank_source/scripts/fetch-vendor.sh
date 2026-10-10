#!/bin/bash
# Fetch pinned vendor JS/CSS for the notes overlay. Output is COMMITTED —
# this script only runs when bumping versions. Verifies shasums when
# vendor/SHASUMS exists; writes it on first fetch (trust-on-first-use).
set -euo pipefail
cd "$(dirname "$0")/.."

VENDOR="Sources/fuckerrank/Resources/Web/vendor"
MARKDOWN_IT_VERSION="14.1.0"
HLJS_VERSION="11.10.0"

mkdir -p "$VENDOR"

fetch() {
    local url="$1" out="$2"
    echo "fetching $url"
    curl -fsSL "$url" -o "$VENDOR/$out"
}

fetch "https://cdn.jsdelivr.net/npm/markdown-it@${MARKDOWN_IT_VERSION}/dist/markdown-it.min.js" markdown-it.min.js
fetch "https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@${HLJS_VERSION}/highlight.min.js" highlight.min.js
fetch "https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@${HLJS_VERSION}/styles/github-dark.min.css" highlight-theme.css

cd "$VENDOR"
if [[ -f SHASUMS ]]; then
    shasum -a 256 -c SHASUMS
else
    shasum -a 256 markdown-it.min.js highlight.min.js highlight-theme.css > SHASUMS
    echo "wrote SHASUMS (first fetch — verify manually if paranoid)"
fi
