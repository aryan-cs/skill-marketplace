#!/usr/bin/env bash
# check-citations.sh [paper-dir] — mechanical citation cross-check for a LaTeX/BibTeX project.
# Reports UNDEFINED citations (cited but no bib entry), UNUSED bib entries, and DUPLICATE keys.
# It only checks that keys RESOLVE — it does NOT judge whether a citation is correct or supports
# its claim. That semantic hand-check (C2) is still on you.
#
# Usage: check-citations.sh path/to/paper   (defaults to the current directory)
set -uo pipefail
ROOT="${1:-.}"
[ -d "$ROOT" ] || { echo "not a directory: $ROOT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }

python3 - "$ROOT" <<'PY'
import os, re, sys, glob

root = sys.argv[1]
tex = glob.glob(os.path.join(root, "**", "*.tex"), recursive=True)
bib = glob.glob(os.path.join(root, "**", "*.bib"), recursive=True)

if not tex:
    print("No .tex files under %s — is this a LaTeX project?" % root); sys.exit(2)

# \cite, \citep, \citet, \citeauthor, \autocite, \parencite, \textcite, \footcite, \Cite ...
# tolerate optional args: \citep[see][p.~5]{a,b}
cite_re  = re.compile(r'\\[A-Za-z]*cite[A-Za-z]*\s*(?:\[[^\]]*\]\s*)*\{([^}]*)\}')
entry_re = re.compile(r'@(\w+)\s*\{\s*([^,\s]+)\s*,')
comment_re = re.compile(r'(?<!\\)%.*')   # strip LaTeX line comments (not \%)

cited = {}      # key -> set(files)
for f in tex:
    txt = comment_re.sub('', open(f, encoding='utf-8', errors='replace').read())
    for m in cite_re.finditer(txt):
        for k in (x.strip() for x in m.group(1).split(',')):
            if k:
                cited.setdefault(k, set()).add(os.path.relpath(f, root))

defined, dups = {}, []
for f in bib:
    txt = open(f, encoding='utf-8', errors='replace').read()
    for m in entry_re.finditer(txt):
        typ, key = m.group(1).lower(), m.group(2)
        if typ in ('comment', 'preamble', 'string'):
            continue
        if key in defined:
            dups.append(key)
        defined[key] = os.path.relpath(f, root)

cited_keys, defined_keys = set(cited), set(defined)
undefined = sorted(cited_keys - defined_keys)
unused    = sorted(defined_keys - cited_keys)

print("Scanned %d .tex and %d .bib file(s) under %s" % (len(tex), len(bib), root))
print("  %d distinct keys cited, %d bib entries defined" % (len(cited_keys), len(defined_keys)))

if dups:
    print("\nDUPLICATE bib keys (defined more than once):")
    for k in sorted(set(dups)): print("  - %s" % k)
if undefined:
    print("\nUNDEFINED citations (cited but no bib entry — render as [?]):")
    for k in undefined:
        print("  - %s   (cited in %s)" % (k, ", ".join(sorted(cited[k]))))
if unused:
    print("\nUNUSED bib entries (defined but never cited):")
    for k in unused:
        print("  - %s   (%s)" % (k, defined[k]))
if not (dups or undefined):
    print("\nOK: every citation resolves to a bib entry; no duplicate keys.")

print("\nNOTE: this only checks that keys RESOLVE. Still hand-check (C2) that each cited work")
print("actually supports its claim and that authors/title/year/venue are correct.")
sys.exit(1 if (undefined or dups) else 0)
PY
