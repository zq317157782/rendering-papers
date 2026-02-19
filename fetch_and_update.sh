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
PDF_URL=$(node - <<'NODE'
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  const searchUrl = 'https://dl.acm.org/action/doSearch?AllField=rendering&sort=Most+Recent';
  await page.goto(searchUrl, { waitUntil: 'load', timeout: 60000 });
  await page.waitForSelector('ul.search__results', { timeout: 60000 });
  const firstLink = await page.$('ul.search__results li a[data-test-id="search-result-title"]');
  if (!firstLink) { console.error('No results'); process.exit(1); }
  const detailPath = await firstLink.getAttribute('href');
  const detailUrl = new URL(detailPath, 'https://dl.acm.org').href;
  await page.goto(detailUrl, { waitUntil: 'load', timeout: 60000 });
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
  console.log(fullPdf);
  await browser.close();
})();
NODE
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

# ---- Download the PDF ----
FILE_NAME="${TIMESTAMP// /_}.pdf"
if command -v curl >/dev/null 2>&1; then
  curl -L -s -o "$FILE_NAME" "$PDF_URL" || echo "Download failed, but will still record entry."
fi

# ---- Create README entry ----
ENTRY="* $TIMESTAMP – $PDF_URL – Summary: (to be generated)"
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
