#!/usr/bin/env bash
# Playwright‑based fetcher for a recent rendering paper.
# Searches ACM DL for "rendering" (most recent), gets the first paper's PDF, downloads it,
# and updates the repo with a timestamped entry and placeholder summary.
# Avoids duplicate downloads by checking if the PDF URL already appears in README.md.

set -euo pipefail

# Ensure we are in the repo directory
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

# Timestamp for entry
TIMESTAMP=$(date -u "+%Y-%m-%d %H:%M UTC")

# ---- Get paper info from arXiv ----
xml=$(curl -s "https://export.arxiv.org/api/query?search_query=all:rendering&sortBy=submittedDate&max_results=1")
# Extract title (second <title> element)
TITLE=$(echo "$xml" | grep -oP "<title>.*</title>" | sed -n 2p | sed -e "s/<\/\?title>//g" | tr -d "\n")
# Extract abstract
ABSTRACT=$(echo "$xml" | grep -oP "<summary>.*</summary>" | sed -e "s/<\/\?summary>//g" | tr -d "\n")
# Extract PDF URL (first .pdf link)
PDF_URL=$(echo "$xml" | grep -i "application/pdf" | grep -oP 'href="[^"]+' | cut -d'"' -f2)

# If we couldn't obtain a URL, exit gracefully
if [ -z "${PDF_URL}" ]; then
  echo "Failed to retrieve PDF URL" >&2
  exit 0
fi

# ---- Duplicate check ----
if grep -Fq "$PDF_URL" README.md; then
  echo "Paper already recorded in README, skipping download." >&2
  exit 0
fi

# ---- Download the PDF (preserve original filename) ----
# Extract the filename from the URL (everything after the last slash)
ORIG_NAME=$(basename "$PDF_URL")
FILE_NAME="$ORIG_NAME"
if command -v curl >/dev/null 2>&1; then
  curl -L -s -o "$FILE_NAME" "$PDF_URL" || echo "Download failed, but will still record entry."
fi

# ---- Generate summary using `summarize` CLI (direct URL) ----
if command -v summarize >/dev/null 2>&1; then
  SUMMARY=$(summarize "$PDF_URL" --model gpt-oss-120b --length short 2>/dev/null || true)
else
  SUMMARY="(summary generation tool not available)"
fi

# ---- Create README entry ----
ENTRY="* $TIMESTAMP – $PDF_URL – Summary: $SUMMARY"
if [ -f README.md ]; then
  echo -e "$ENTRY\n$(cat README.md)" > README.md
else
  echo -e "$ENTRY" > README.md
fi

# ---- Commit & push ----
git add .
git commit -m "Add paper $TIMESTAMP"
# Push using existing remote (ssh)
git push origin master || true

echo "Done: $TIMESTAMP"
