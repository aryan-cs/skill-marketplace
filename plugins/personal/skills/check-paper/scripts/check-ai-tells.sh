#!/usr/bin/env bash
# check-ai-tells.sh [path] — surface the MECHANICAL tells of AI-sounding / non-human prose.
# Reports every em dash (a hard no per B8) and flags high-signal AI-tell words/phrases for review.
# It cannot judge voice (B9) — cutting spurious "nuanced" filler and inflated tone is still on you.
#
# Usage: check-ai-tells.sh path/to/paper.tex   OR   a directory (scans .tex/.md/.typ).
# Exit 1 if any em dash is found, else 0.
set -uo pipefail
ROOT="${1:-.}"
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }

python3 - "$ROOT" <<'PY'
import os, re, sys, glob

root = sys.argv[1]
if os.path.isfile(root):
    files = [root]
else:
    files = []
    for ext in ("tex", "md", "typ", "txt"):
        files += glob.glob(os.path.join(root, "**", f"*.{ext}"), recursive=True)
if not files:
    print("No .tex/.md/.typ files found under %s" % root); sys.exit(2)

# High-signal AI-tell words/phrases (case-insensitive). Distinctive ones a careful
# researcher rarely writes; connectives like "moreover" are counted, not line-listed.
TELLS = [
    r"\bdelv(e|es|ing)\b", r"\bleverag(e|es|ing|ed)\b", r"\bunderscore[sd]?\b",
    r"\bshowcas(e|es|ing|ed)\b", r"\bpivotal\b", r"\bseamless(ly)?\b",
    r"\bgroundbreaking\b", r"\brevolutionary\b", r"\btapestry\b",
    r"\ba testament to\b", r"\bplays? a (crucial|key|vital|pivotal|central|significant) role\b",
    r"\b(it'?s|it is) worth noting\b", r"\bin essence\b", r"\bat the heart of\b",
    r"\bin the realm of\b", r"\bthe realm of\b", r"\blandscape of\b", r"\bat the forefront\b",
    r"\bharness(ing)? the power\b", r"\bparadigm shift\b", r"\bgame[- ]?chang(er|ing)\b",
    r"\bcutting[- ]edge\b", r"\bever[- ]evolving\b", r"\bit'?s not just\b",
    r"\bnot only\b.*\bbut also\b",
]
CONNECTIVES = [r"\bmoreover\b", r"\bfurthermore\b", r"\bnotably\b", r"\bimportantly\b", r"\badditionally\b"]

def strip_comment(line, f):
    return re.sub(r'(?<!\\)%.*', '', line) if f.endswith(".tex") else line

emdash_hits, tell_hits = [], []
conn_counts = {}
for f in files:
    rel = os.path.relpath(f, root) if os.path.isdir(root) else f
    is_tex = f.endswith(".tex")
    for i, raw in enumerate(open(f, encoding="utf-8", errors="replace"), 1):
        line = strip_comment(raw, f)
        # em dashes: U+2014 anywhere; LaTeX --- in .tex (skip all-dash rule lines)
        if "—" in line or (is_tex and "---" in line and set(line.strip()) - set("-")):
            emdash_hits.append((rel, i, raw.rstrip()[:100]))
        low = line.lower()
        for pat in TELLS:
            if re.search(pat, low):
                tell_hits.append((rel, i, pat, raw.strip()[:90]))
        for pat in CONNECTIVES:
            conn_counts[pat] = conn_counts.get(pat, 0) + len(re.findall(pat, low))

print("Scanned %d file(s) under %s" % (len(files), root))

if emdash_hits:
    print("\nEM DASHES (B8 — remove all; use a comma/colon/parentheses/new sentence):")
    for rel, i, txt in emdash_hits:
        print("  %s:%d  %s" % (rel, i, txt))
else:
    print("\nOK: no em dashes.")

if tell_hits:
    print("\nAI-TELL words/phrases to review (B9 — rewrite unless genuinely warranted):")
    for rel, i, pat, txt in tell_hits:
        print("  %s:%d  [%s]  %s" % (rel, i, pat.strip('\\b'), txt))

conn = {k: v for k, v in conn_counts.items() if v}
if conn:
    print("\nConnective overuse (counts — trim if leaned on):")
    for pat, n in sorted(conn.items(), key=lambda kv: -kv[1]):
        print("  %-14s %d" % (pat.strip('\\b'), n))

print("\nNOTE: the voice check (B9) is a human judgment — cut spurious 'nuanced' details,")
print("inflated tone, and mechanical structure the script cannot see.")
sys.exit(1 if emdash_hits else 0)
PY
