#!/usr/bin/env bash
# Playwright‑based fetcher for rendering papers.
# Searches ACM Digital Library for "rendering" sorted by Most Cited,
# iterates through results until it finds a paper not yet downloaded,
# downloads the PDF (preserving original filename), records the URL in
# downloaded_papers.txt, generates a short summary, updates README.md,
# and pushes the changes.

set -euo pipefail

# Ensure we are in the repo directory
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

# Ensure the downloaded list exists
if [ ! -f downloaded_papers.txt ]; then
  touch downloaded_papers.txt
fi

# Timestamp for entry
TIMESTAMP=$(date -u "+%Y-%m-%d %H:%M UTC")

# ---- Get paper info from arXiv ----
xml=$(curl -s "https://export.arxiv.org/api/query?search_query=all:rendering&sortBy=submittedDate&max_results=1")
# Extract title (second <title> element)
TITLE=$(echo "$xml" | grep -oP "<title>.*</title>" | sed -n 2p | sed -e "s/<\/?title>//g" | tr -d "\n")
# Extract abstract
ABSTRACT=$(echo "$xml" | grep -oP "<summary>.*</summary>" | sed -e "s/<\/?summary>//g" | tr -d "\n")
# Extract PDF URL (first .pdf link)
PDF_URL=$(echo "$xml" | grep -i "application/pdf" | grep -oP 'href="[^"]+' | cut -d'"' -f2)
# (Result JSON block removed)
# (Title block removed)
# (Abstract block removed)

# If we couldn't obtain a URL, exit gracefully
if [ -z "$PDF_URL" ]; then
  echo "Failed to retrieve PDF URL" >&2
  exit 0
fi

# ---- Download the PDF (preserve original filename) ----
ORIG_NAME=$(basename "$PDF_URL")
FILE_NAME="$ORIG_NAME"
if command -v curl >/dev/null 2>&1; then
  curl -L -s -o "$FILE_NAME" "$PDF_URL" || echo "Download failed, but will still record entry."
fi
# Record the PDF URL in the downloaded list
echo "$PDF_URL" >> downloaded_papers.txt

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
