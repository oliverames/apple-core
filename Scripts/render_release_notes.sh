#!/bin/bash
#
# render_release_notes.sh
#
# Extracts a single version's release notes, renders the markdown to HTML via
# GitHub's /markdown API (so the result matches what users see on the release
# page), wraps it with inline CSS, and prints the result to stdout.
#
# Ported from ping-warden's scripts/render_release_notes.sh, adapted for
# apple-core: notes live in docs/release-notes/vX.Y.Z.md (one file per
# release, matching release.yml's convention) rather than a single
# RELEASE_NOTES.md history file.
#
# Used by release.sh's `appcast` command to populate the <description> CDATA
# of each appcast item so Sparkle's update window shows real release notes
# instead of "See release notes on GitHub". Also usable standalone.
#
# Usage: ./Scripts/render_release_notes.sh <version> [--markdown]
# Example: ./Scripts/render_release_notes.sh 1.0.0
#
# --markdown prints the raw markdown instead of rendered HTML.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#

set -euo pipefail

VERSION="${1:-}"
OUTPUT_MODE="${2:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version> [--markdown]" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NOTES_FILE="$REPO_ROOT/docs/release-notes/v${VERSION}.md"

if [ ! -f "$NOTES_FILE" ]; then
    echo "Error: $NOTES_FILE not found. Write the release notes there first." >&2
    exit 2
fi

if [ "$OUTPUT_MODE" != "--markdown" ] && ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh CLI required for markdown rendering" >&2
    exit 1
fi

SECTION=$(cat "$NOTES_FILE")

# Trim leading/trailing blank lines.
SECTION=$(printf '%s\n' "$SECTION" | awk 'NF{p=1}p' | awk 'BEGIN{n=0} {a[n++]=$0} END{while(n>0 && a[n-1]==""){n--} for(i=0;i<n;i++)print a[i]}')

if [ -z "$SECTION" ]; then
    echo "Error: $NOTES_FILE is empty" >&2
    exit 2
fi

if [ "$OUTPUT_MODE" = "--markdown" ]; then
    printf '%s\n' "$SECTION"
    exit 0
fi

# Render markdown -> HTML using gh's /markdown endpoint (gfm mode matches the
# GitHub release page rendering).
HTML_BODY=$(printf '%s' "$SECTION" | gh api -X POST /markdown -F mode=gfm -F text=@-)

# CDATA safety: escape `]]>` so it cannot prematurely close the appcast
# description CDATA section.
HTML_BODY_SAFE=$(printf '%s' "$HTML_BODY" | sed 's/]]>/]]]]><![CDATA[>/g')

# Sparkle's update window is a WKWebView. System fonts, modest line height,
# and prefers-color-scheme support so the panel looks right in Light and Dark
# Mode. (Ping-warden's stylesheet minus its BMC-orange link brand color.)
cat <<HTML
<style>
body {
    font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif;
    font-size: 13px;
    line-height: 1.55;
    color: #1d1d1f;
    margin: 0;
    padding: 0;
}
h1, h2, h3 { color: #000; font-weight: 600; }
h1 { font-size: 18px; margin: 0 0 10px 0; }
h2 {
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.6px;
    color: #6e6e73;
    margin: 18px 0 6px 0;
}
h3 { font-size: 13px; margin: 14px 0 6px 0; }
p { margin: 0 0 10px 0; }
ul, ol { padding-left: 20px; margin: 0 0 10px 0; }
li { margin-bottom: 5px; }
li > strong:first-child { color: #000; }
code {
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    background: #f2f2f7;
    padding: 1px 5px;
    border-radius: 3px;
    font-size: 12px;
}
a { color: #0071e3; text-decoration: none; }
a:hover { text-decoration: underline; }
hr { border: 0; border-top: 1px solid #e5e5ea; margin: 16px 0; }
@media (prefers-color-scheme: dark) {
    body { color: #f5f5f7; }
    h1, h2, h3, li > strong:first-child { color: #fff; }
    h2 { color: #98989d; }
    code { background: #2c2c2e; }
    hr { border-top-color: #38383a; }
}
</style>
$HTML_BODY_SAFE
HTML
