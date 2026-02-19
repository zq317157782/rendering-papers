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

# ---- Get PDF URL via Playwright (iterate until new paper) ----
RESULT_JSON=$(node - <<'NODE'
const { chromium } = require('playwright');
const fs = require('fs');
(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  const searchUrl = 'https://dl.acm.org/action/doSearch?AllField=rendering&sort=Most+Cited';
  await page.goto(searchUrl, { waitUntil: 'load', timeout: 120000 });
  await page.waitForLoadState('networkidle', { timeout: 120000 });
  await page.waitForSelector('a[data-test-id="search-result-title"]', { timeout: 120000 });
  const resultLinks = await page.$$eval('ul.search__results li a[data-test-id="search-result-title"]', els => els.map(e => e.getAttribute('href')));
  const downloaded = new Set(fs.readFileSync('downloaded_papers.txt', 'utf8').split('\n').filter(Boolean));
  let found = null;
  for (const relPath of resultLinks) {
    const detailUrl = new URL(relPath, 'https://dl.acm.org').href;
    await page.goto(detailUrl, { waitUntil: 'load', timeout: 120000 });
    // Locate PDF link
    const pdfBtn = await page.$('a[title="PDF"]');
    let pdfHref = null;
    if (pdfBtn) { pdfHref = await pdfBtn.getAttribute('href'); }
    if (!pdfHref) {
      const pdfLinks = await page.$$eval('a', as => as.map(a => a.href).filter(h => h.endsWith('.pdf')));
      pdfHref = pdfLinks[0] || null;
    }
    if (!pdfHref) { continue; }
    const fullPdf = new URL(pdfHref, 'https://dl.acm.org').href;
    if (downloaded.has(fullPdf)) { continue; }
    let title = null;
    try { title = await page.$eval('h1[data-test-id="title"]', el => el.innerText.trim()); } catch (e) {}
    let abstract = null;
    try { abstract = await page.$eval('div[data-test-id="abstract"]', el => el.innerText.trim()); } catch (e) {}
    found = {title: title, abstract: abstract, pdf: fullPdf};
    break;
  }
  if (!found) {
    console.error('No new paper found');
    process.exit(0);
  }
  console.log(JSON.stringify(found));
  await browser.close();
})();
NODE
)

# Extract fields from JSON result
PDF_URL=$(echo "$RESULT_JSON" | python - <<'PY'
import sys, json
obj = json.load(sys.stdin)
print(obj.get('pdf',''))
PY
)
TITLE=$(echo "$RESULT_JSON" | python - <<'PY'
import sys, json
obj = json.load(sys.stdin)
print(obj.get('title',''))
PY
)
ABSTRACT=$(echo "$RESULT_JSON" | python - <<'PY'
import sys, json
obj = json.load(sys.stdin)
print(obj.get('abstract',''))
PY
)

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
