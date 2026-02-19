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

# ---- Get PDF URL via Playwright ----
RESULT_JSON=$(node - <<'NODE'
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  const searchUrl = 'https://dl.acm.org/action/doSearch?AllField=rendering&sort=Most+Cited';
  await page.goto(searchUrl, { waitUntil: 'load', timeout: 120000 });
  await page.waitForLoadState('networkidle', { timeout: 120000 });
  await page.waitForSelector('a[data-test-id="search-result-title"]', { timeout: 120000 });
  const firstLink = await page.$('ul.search__results li a[data-test-id="search-result-title"]');
  if (!firstLink) { console.error('No results'); process.exit(1); }
  const detailPath = await firstLink.getAttribute('href');
  const detailUrl = new URL(detailPath, 'https://dl.acm.org').href;
  await page.goto(detailUrl, { waitUntil: 'load', timeout: 120000 });
  // Try PDF button
  const pdfBtn = await page.$('a[title="PDF"]');
  let pdfHref = null;
  if (pdfBtn) {
    const href = await pdfBtn.getAttribute('href');
    pdfHref = href;
  } else {
    // fallback to any .pdf link
    const links = await page.$$eval('a', as => as.map(a=>a.href).filter(h=>h.endsWith('.pdf')));
    pdfHref = links[0] || null;
  }
  if (!pdfHref) { console.error('PDF not found'); process.exit(1); }
  const fullPdf = new URL(pdfHref, 'https://dl.acm.org').href;
  // Extract title and abstract for summary
  let title = null;
  try { title = await page.$eval('h1[data-test-id="title"]', el => el.innerText.trim()); } catch (e) {}
  let abstract = null;
  try { abstract = await page.$eval('div[data-test-id="abstract"]', el => el.innerText.trim()); } catch (e) {}
  const result = {title: title, abstract: abstract, pdf: fullPdf};
  console.log(JSON.stringify(result));
  await browser.close();
})();
NODE
)

# Extract fields from JSON result
PDF_URL=$(echo "$RESULT_JSON" | python - <<'PY'
import sys, json, codecs
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
  SUMMARY=$(summarize "$PDF_URL" --model gpt-oss-120b --length short)
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
