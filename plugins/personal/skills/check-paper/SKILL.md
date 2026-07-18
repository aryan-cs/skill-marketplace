---
name: check-paper
description: Reviews an academic paper (especially ML/CS) and its figures against a comprehensive submission checklist — narrative prose, a concise results-first abstract, complete hand-checked citations, required sections and venue-template/formatting compliance, anonymization for double-blind review, reproducibility and experimental rigor (baselines, ablations, error bars, seeds, compute), consistent notation and terminology, no em dashes, prose that reads human (not AI-generated), resolved cross-references, and figure/table standards (Turbo colormap, semantic color, spacing, matched fonts, legible non-overlapping labels). Ships a ready-to-use arXiv/NeurIPS-style preprint template. Use when the user asks to check, review, proofread, or finalize a paper or draft, verify citations or figures, remove em dashes or AI-sounding writing, choose a conference template, start a preprint from the bundled template, or prepare a paper for submission.
---

# Check paper

Run a structured, artifact-by-artifact review of a paper draft and its visuals against the checklist below, then report every issue with its location and a concrete fix. **Do not silently rewrite the manuscript** — surface findings and let the author decide (or apply only what they approve). Finish with a ✓/✗ per check and a go/no-go verdict.

Tool- and format-agnostic: works for LaTeX, Typst, Markdown, or Word, and for any capable agent. The one helper script targets LaTeX/BibTeX; everything else is manual and visual review. Deeper recipes, checklists, the abstract template, and the venue-template comparison live in [reference.md](reference.md).

## How to run

1. **Locate the material and the target venue.** Find the manuscript source (`.tex`/`.typ`/`.md`/`.docx`), the rendered PDF if it exists, and every figure/table with its generating source. Ask (or infer) which venue/template the paper targets — several checks (page limit, anonymization, required sections) depend on it. If no venue is chosen yet, help pick one from the comparison in [reference.md](reference.md).
2. **Work the checklist** — groups A→E. Judge each item against the **actual artifact** (read the paragraph, open the rendered figure), never from memory or source code alone. Skip a check only if it doesn't apply (say so), e.g. anonymization for a camera-ready.
3. **Report** in the format at the end.

## Starting a new paper (preprint)

This skill bundles a ready-to-use **arXiv / NeurIPS-style preprint** template in `template/` (the MIT-licensed [arxiv-style](https://github.com/kourgeorge/arxiv-style), prefilled and verified to compile). To start a paper: copy `template/` into the new paper's directory and edit `template.tex`. It ships `template.tex` (single author whose name hyperlinks to your ORCID — no logo icon; clean title with **no "A Preprint" label, no date, no line numbers, no anonymity, no keywords line**), `arxiv.sty`, `references.bib`, and the license. Build with `tectonic template.tex` (or `pdflatex` + `bibtex`). The author is prefilled as **Aryan Gupta** at the University of Illinois Urbana-Champaign, name linked to ORCID `0009-0005-1413-3773`, email `aryan.cs.app@gmail.com`; replace the title and the `\lipsum` filler with real content.

## A — Structure & venue compliance

- **A1 · Right template, unmodified.** Uses the target venue's official style file, **not tweaked** (altered margins/font/spacing/line-spacing are grounds for desk-reject at most venues), within the page limit, correct column layout and font. For a preprint, the bundled `template/` (see *Starting a new paper*) is the default; for a submission, confirm it's the venue's own style and — if double-blind — in review/anonymized mode. Templates + a compare/contrast table: [reference.md](reference.md).
- **A2 · Anonymized (double-blind).** For submission, not camera-ready: no author names/affiliations, no identifying acknowledgments or funding, no de-anonymizing links (personal sites, non-anonymous repos), and self-citations in the third person ("Smith et al. [12]", never "our prior work [12]"). Nearly all premier ML venues are double-blind.
- **A3 · Required sections present.** Title; abstract; introduction with **explicit contributions**; related work; method; experimental setup; results; discussion; **limitations**; **broader-impact/ethics** where the venue requires it (e.g. NeurIPS); conclusion; references; appendix/reproducibility as needed. Flag any missing.
- **A4 · Cross-references resolve.** No `??` or undefined refs; every figure, table, equation, and section is referenced and discussed in the text; captions are self-contained. For LaTeX, `scripts/check-citations.sh` flags citation issues; also grep the build `.log` for "undefined references".

## B — Writing

- **B1 · Narrative, not an information dump.** Each section/paragraph blends **information, interpretation, and explanation**: states what, says what it means / why it matters, and connects to the argument. Flag bare fact-lists, stats with no interpretation, method/result dumps with no "so what." Fix: topic sentence + interpretive/transition sentence, or merge/reorder. (Before/after in [reference.md](reference.md).)
- **B2 · Concise, results-first abstract.** Follows the "Attention Is All You Need" shape (https://arxiv.org/abs/1706.03762): (1) one line of context, (2) the contribution in 1–2 sentences, (3) headline results **with numbers**, (4) one line of broader implication. No method minutiae, no citations, ~≤200 words. Template in [reference.md](reference.md).
- **B3 · Title + explicit contributions.** Title specific and not overclaiming; the intro states the contributions plainly (often a bulleted list) and they match what the paper delivers.
- **B4 · Related work positions the paper.** Contrasts *this* work against prior art (what's new/different/better), not a bare list of summaries.
- **B5 · Claims match evidence.** Every claim in the abstract/intro is backed by a result; superlatives ("first", "state-of-the-art", "significantly") are supported and not overstated.
- **B6 · Consistent notation, terminology, acronyms.** Symbols defined at first use and used consistently; one term per concept; acronyms expanded at first use; consistent tense/voice.
- **B7 · Grammar, spelling, typos.** Proofread; one spelling convention (US/UK); no leftover TODOs or placeholders.
- **B8 · No em dashes.** The manuscript contains no em dashes (`—` / LaTeX `---`). Replace each with a comma, colon, parentheses, or a fresh sentence as the grammar wants. Run `scripts/check-ai-tells.sh <paper>` to locate every one.
- **B9 · Reads as human-written, not AI.** The prose should read as if a senior researcher at a frontier lab wrote it: confident, economical, precise, written for an expert reader. Flag AI-writing tells — inflated diction ("delve", "leverage", "underscore", "pivotal", "seamless", "rich tapestry", "a testament to", "plays a crucial role"), mechanical signposting and rule-of-three, hedged filler, and — the tell to hunt hardest — **spurious "nuanced" details a real author wouldn't include**: tangential facts, over-explained basics, or context that leaked in during drafting and doesn't earn its place. Cut everything that isn't load-bearing. `scripts/check-ai-tells.sh` surfaces the mechanical tells; the voice judgment is yours.

## C — Citations & references

- **C1 · Completeness.** Every claim needing support has a citation — external facts, prior methods/datasets, borrowed numbers, "it is known that…", and every comparison to prior work.
- **C2 · Correctness (hand-check each).** For every citation confirm the key resolves to a real entry, the metadata (authors, title, year, venue) is right, and the cited work **actually supports the specific claim**. Run `scripts/check-citations.sh <paper-dir>` for undefined/unused/duplicate keys, then hand-check the semantic match — the script proves a key *resolves*, not that a citation is *correct*.
- **C3 · Reference-list quality.** Consistent bib format, complete fields, correct venue/year, prefer the published version over an arXiv preprint when one exists, no duplicates.

## D — Rigor & reproducibility

- **D1 · Experimental rigor.** Appropriate baselines and ablations; results report variance (error bars / std over seeds) and, where a claim hinges on it, statistical significance; comparisons are fair (same data/compute/tuning); metrics stated clearly.
- **D2 · Reproducibility.** Hyperparameters, architecture, compute/hardware, dataset details and splits, and random seeds are given; code/data availability stated (anonymized during review); include the venue's reproducibility statement/checklist where required. (Checklist in [reference.md](reference.md).)
- **D3 · Math & notation rigor.** Equations numbered and referenced; all symbols and assumptions defined; theorems have complete, correct proofs (or are clearly deferred to an appendix).
- **D4 · Limitations, ethics, licensing.** Honest limitations; broader-impact/ethics statement where required; dataset licenses and human-subjects/consent addressed where relevant.

## E — Visuals (apply to every figure and table; prefer the rendered image)

- **E1 · Turbo palette.** Matplotlib **Turbo**: continuous data `cmap='turbo'`; categorical `turbo(np.linspace(0.05, 0.95, n))` (avoid the near-black/white extremes). Flag jet, the default cycle, viridis, or ad-hoc colors. §E3 governs when meaning overrides this.
- **E2 · Style matches the paper.** Figure fonts/sizes/line style match the manuscript body — same family, sizes comparable to caption/body, consistent weights. Flag mismatched fonts, tiny/oversized text, default styling that clashes. (Recipe in [reference.md](reference.md).)
- **E3 · Semantic color.** Color carries meaning. **Opposing ideas get opposing colors** (good/bad → green/red; increase/decrease). Related magnitudes get a Turbo sweep. When semantics conflict with the Turbo default, **semantics win** — use opposing Turbo endpoints or conventional semantic colors, and reinforce with a second channel (label/position/pattern) so meaning survives grayscale and color-vision deficiency.
- **E4 · Table whitespace.** ~**20px** vertical whitespace above and below every table (≈15pt in print), applied **consistently**. Flag cramped or uneven spacing. (Format recipes in [reference.md](reference.md).)
- **E5 · Paragraph alignment & spacing.** One alignment (usually justified) and **equal** inter-paragraph spacing throughout. Flag mixed alignment, stray ragged/centered paragraphs, uneven gaps.
- **E6 · No label/axis overlap.** Axis labels, ticks, legends, titles, and annotations must not overlap each other or the data, and nothing is clipped at the edge. Fix: `constrained_layout`/`tight_layout()`, rotate/thin ticks, move the legend, widen margins.
- **E7 · Legibility, value, self-contained captions.** Open each rendered figure and read it at print size: legible, and does it **earn its place** by advancing the narrative? Caption self-contained. Flag decorative, redundant, or unreadable figures; fix, merge, or cut.

## Report

1. **Findings**, grouped by check (A1…E7), most impactful first. Each: `file:location — the problem in one line — a specific fix`.
2. **Checklist** — ✓/✗ for each check (✗ if it has any finding; `n/a` with a reason if it doesn't apply).
3. **Verdict** — submission-ready, or the blocking items to resolve first.

Reading figures and the rendered PDF means actually opening them — never judge a visual from its source code alone.
