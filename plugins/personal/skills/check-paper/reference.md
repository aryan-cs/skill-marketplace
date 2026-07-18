# check-paper — reference

Detail for the checks in SKILL.md: conference templates, the abstract shape, worked
examples, and the visual recipes. Load a section when you hit the matching check.

## Conference & journal templates (compare and contrast)

Pick the template for the **target venue** and use it *unmodified* — altering margins,
font, or line spacing is grounds for desk-rejection at most venues. Page limits are the
**main-text** limit (references/appendix are usually excluded) and change yearly — always
confirm against the specific year's Call for Papers. Nearly all of these are **double-blind**
for submission (anonymous) and add author info only at camera-ready.

| Venue | Field | Layout | Main-text pages* | Official template |
| --- | --- | --- | --- | --- |
| **NeurIPS** | general ML | single-column | ~9 | https://neurips.cc/Conferences/2025/ (StyleFiles) · [Overleaf](https://www.overleaf.com/latex/templates/formatting-instructions-for-neurips-2026/bjdwqfdkyftc) |
| **ICML** | general ML | two-column | ~8 | [Overleaf ICML2025](https://www.overleaf.com/latex/templates/icml2025-template/dhxrkcgkvnkt) · [instructions](https://icml.cc/Conferences/2025/AuthorInstructions) |
| **ICLR** | deep learning | single-column | ~9 | [github.com/ICLR/Master-Template](https://github.com/ICLR/Master-Template) · [Overleaf ICLR2025](https://www.overleaf.com/latex/templates/template-for-iclr-2025-conference-submission/gqzkdyycxtvt) |
| **CVPR / ICCV / ECCV** | computer vision | two-column | ~8 | [github.com/cvpr-org/author-kit](https://github.com/cvpr-org/author-kit) · extended: [apoorvkh/cvpr-latex-template](https://github.com/apoorvkh/cvpr-latex-template) |
| **ACL / EMNLP / NAACL** | NLP (via ARR) | two-column | 8 (long) | [github.com/acl-org/acl-style-files](https://github.com/acl-org/acl-style-files) |
| **AAAI** | general AI | two-column | ~7–8 | [AAAI Author Kit / Overleaf](https://www.overleaf.com/latex/templates/aaai-press-latex-template/jymjdgdpdmxp) — Times font; **incompatible with hyperref** |
| **JMLR / TMLR** | ML journal | single-column | unlimited | [github.com/JmlrOrg/jmlr-style-file](https://github.com/JmlrOrg/jmlr-style-file) · [format](https://www.jmlr.org/format/format.html) |
| **IEEE** (IEEEtran) | IEEE venues | two-column | varies | https://www.ieee.org/conferences/publishing/templates.html |
| **Typst** (tool-agnostic) | modern alt. to LaTeX | varies | — | [github.com/daskol/typst-templates](https://github.com/daskol/typst-templates) |

\* Approximate; verify against the venue's current Call for Papers.

**How they differ, at a glance:**
- **Column layout:** NeurIPS and ICLR are single-column; ICML, CVPR/ICCV, ACL, AAAI, IEEE are two-column. Two-column constrains figure/table width (use `figure*`/`table*` for full-width floats).
- **Bibliography:** most are natbib-based; ACL ships `acl_natbib.bst`; AAAI uses `aaai*.bst` and **forbids `hyperref`**.
- **Modes:** most style files have `review` / `final` (or `preprint`) options — `review` adds line numbers and hides authors; `final` reveals them.
- **Reproducibility:** NeurIPS requires the paper checklist + (often) broader-impact; ICLR wants a reproducibility statement; ML venues increasingly require a limitations section.
- **Vision vs NLP vs general:** CVPR/ICCV = CVF/IEEE two-column; ACL = its own two-column with an anonymized ARR flow; NeurIPS/ICLR/ICML = the "general ML" look most arXiv ML papers imitate.

When unsure or posting to arXiv, the **NeurIPS** or **ICLR** style is the safe, familiar default for general ML.

### Preprints (arXiv) and the NeurIPS style modes

The NeurIPS style file has three modes; the **default is submission mode**, which is why a fresh
template shows line numbers, "Anonymous Author(s)", and a "Submitted to … NeurIPS … Do not
distribute." footer. For a preprint you do **not** want those:

- `\usepackage{neurips_2025}` — **submission**: line numbers, anonymized, "Submitted to…" footer.
- `\usepackage[preprint]{neurips_2025}` — **preprint (arXiv)**: no line numbers, real author names,
  footer reads "Preprint. Work in progress." Use this to keep the NeurIPS look before/while under review.
- `\usepackage[final]{neurips_2025}` — **camera-ready**: accepted papers only.

For a standalone preprint that keeps the single-column NeurIPS aesthetic but is deliberately *not*
mistakable for a NeurIPS publication, use the community **arxiv-style** template (based on the NIPS
style): https://github.com/kourgeorge/arxiv-style (`arxiv.sty` + `template.tex`; `\usepackage{arxiv}`).
A bioRxiv-flavored fork: https://github.com/ylaboratory/ar-biorxiv-style. Rule of thumb: use
`[preprint]` NeurIPS if the paper is headed to NeurIPS; use `arxiv-style` if it's standalone or headed
elsewhere — don't dress a non-NeurIPS paper as a NeurIPS one. (A1 flags a preprint left in submission
mode: line numbers or "Anonymous Author(s)" on something you're posting publicly under your name.)

## The abstract shape (arxiv.org/abs/1706.03762)

Four moves, ~4–6 sentences, ≤~200 words, no citations, results-forward:

1. **Context (1 sentence)** — the current dominant approach and its shape.
   *"The dominant sequence transduction models are based on complex recurrent or convolutional neural networks…"*
2. **Contribution (1–2 sentences)** — what you propose, stated plainly and boldly.
   *"We propose a new simple network architecture, the Transformer, based solely on attention mechanisms, dispensing with recurrence and convolutions entirely."*
3. **Results with numbers (2–3 sentences)** — headline quantitative outcomes vs prior work.
   *"…28.4 BLEU on WMT 2014 English-to-German, improving over the existing best results … by over 2 BLEU."*
4. **Generalization (1 sentence)** — the broader implication.
   *"We show that the Transformer generalizes well to other tasks…"*

Anti-patterns to flag: a background paragraph before the contribution; a list of methods/components; no number anywhere; > ~200 words.

## Narrative vs information-dump (B1)

**Dump:** "The dataset has 50k images. We used a ResNet-50. Batch size was 256. Accuracy was 92.3%. Training took 4 hours."

**Narrative:** "We evaluate on a 50k-image benchmark large enough to expose overfitting. A ResNet-50 backbone (batch 256) reaches 92.3% accuracy — a 3-point gain over the prior best — showing that the architectural change, not scale, drives the improvement; the 4-hour training cost makes it practical to reproduce."

The facts are identical; the second states what each fact *means* and connects them into an argument.

## AI-writing tells and the senior-researcher voice (B8, B9)

The paper should read as if a senior researcher at a frontier lab wrote it: confident, economical,
precise, assuming an expert reader. Hunt and remove these tells:

- **Em dashes** — none (B8). Replace `—` / `---` with a comma, colon, parentheses, or a period.
- **Inflated diction** — delve, leverage (as a verb), underscore, showcase, pivotal, seamless,
  groundbreaking, "rich tapestry", "a testament to", "plays a crucial role", "harness the power",
  "cutting-edge", "paradigm shift".
- **Mechanical structure** — rule-of-three everywhere; every paragraph as topic sentence + three
  examples + restated summary; heavy signposting ("In this section, we...").
- **Hedged filler / connective overuse** — "it is worth noting", "in essence", and "moreover /
  furthermore / notably / importantly" sprinkled as glue.
- **Spurious "nuanced" details — the strongest tell.** AI drafts leak tangential facts, over-explained
  basics, and hedged caveats that were salient to the model but that a real author would never
  include, because they don't serve the argument. Every sentence must be load-bearing; if a detail
  doesn't advance the claim, cut it.
- **Marketing tone** — "powerful", "robust", "seamless", superlatives with no evidence.

What senior-researcher prose does instead: leads with the claim, backs it with a number or a
mechanism, assumes the reader knows the basics, states limitations plainly, and stops. Run
`scripts/check-ai-tells.sh` for the mechanical tells; the voice judgment is manual.

## Turbo palette + semantic color (E1, E3)

```python
import numpy as np, matplotlib.pyplot as plt
# continuous / sequential
im = ax.imshow(Z, cmap='turbo')
# categorical series — sample stops, avoid the dark/near-white extremes
colors = plt.cm.turbo(np.linspace(0.05, 0.95, n))
for i, y in enumerate(series):
    ax.plot(x, y, color=colors[i])
```

Reconciling Turbo (E1) with semantic color (E3): Turbo is *sequential* (blue→red), so it's
right for magnitude/ordering. When a variable is **opposing/diverging** (good vs bad,
gain vs loss), meaning wins: take opposing Turbo endpoints (e.g. blue `turbo(0.1)` vs red
`turbo(0.9)`) or conventional semantic colors (green good / red bad), and add a second
channel — label, position, or hatch — so it still reads in grayscale and for color-blind
readers (red/green is the classic risk).

## Match figure fonts to the paper (E2)

```python
import matplotlib as mpl
mpl.rcParams.update({
    "font.family": "serif",              # match the paper; e.g. Times for two-column venues
    "font.serif": ["Times New Roman"],   # or the paper's body font
    "font.size": 9,                       # ≈ the paper's caption/body size
    "axes.labelsize": 9, "xtick.labelsize": 8, "ytick.labelsize": 8, "legend.fontsize": 8,
    "text.usetex": True,                 # for true LaTeX/Computer-Modern matching
})
```
Set the figure's physical width to the column width (e.g. ~3.25 in for two-column) so text
isn't scaled down on insertion.

## Table whitespace ≈ 20px (E4)

20px ≈ 15pt in print (96 dpi). Make the space **consistent** above and below every table.

- **LaTeX float:** `\setlength{\textfloatsep}{15pt}\setlength{\intextsep}{15pt}` (space around top/bottom and in-text floats), or a manual `\vspace{15pt}` around a non-float table. Use `booktabs` (`\toprule/\midrule/\bottomrule`) — never vertical rules.
- **HTML/CSS:** `table { margin: 20px 0; }`.
- **Word:** set Paragraph → Spacing Before/After = 15pt on the table's surrounding paragraphs.

## Paragraph alignment & spacing (E5)

- **LaTeX:** justified is the default; a stray block is usually a local `\raggedright`/`center`.
  Set one inter-paragraph rule document-wide: `\setlength{\parskip}{0pt}` with `\parindent`
  for indented style, **or** `\usepackage{parskip}` for block style — not a mix.
- **HTML/CSS:** `p { text-align: justify; margin: 0 0 1em; }`.

## No label/axis overlap (E6)

`fig, ax = plt.subplots(constrained_layout=True)` or `fig.tight_layout()`; rotate crowded
ticks (`ax.tick_params(axis='x', rotation=45)`); thin ticks with `MaxNLocator`; move a
colliding legend (`ax.legend(loc='upper left', bbox_to_anchor=(1.02, 1))`); `bbox_inches='tight'`
on `savefig` to avoid edge clipping.

## Anonymization checklist (A2, double-blind submission)

- No author names, affiliations, emails on the title page (use the style's `review` mode).
- No identifying acknowledgments, grant numbers, or institution names.
- Self-citations in the third person: "Smith et al. [12] showed…", not "in our prior work [12]".
- No de-anonymizing links — personal/lab sites, or a GitHub repo with your handle; use an
  anonymized mirror (e.g. anonymous.4open.science) during review.
- Check PDF metadata/author field, and supplementary files, for names.

## Reproducibility checklist (D2)

- Model architecture and all hyperparameters (LR, batch size, epochs, optimizer, schedule).
- Datasets: source, version, license, and exact train/val/test splits.
- Compute: hardware, number of runs, and wall-clock/GPU-hours.
- Random seeds, and whether results are mean ± std over seeds.
- Code and data availability statement (anonymized link during review).
- The venue's own checklist/statement (NeurIPS paper checklist, ICLR reproducibility statement).

## Citation cross-check (C2)

`scripts/check-citations.sh <paper-dir>` scans `.tex` for `\cite`-family commands and `.bib`
for entry keys, then reports **undefined** citations (cited, no entry → renders as `[?]`),
**unused** entries, and **duplicate** keys. It only checks that keys *resolve* — you must still
confirm each cited work supports its claim and that authors/title/year/venue are correct.
