# PDF Ingestion — Design STUB / PARKED (post-docx-MVP)

- **Date:** 2026-06-04
- **Status:** PARKED. The first paid MVP is **docx-only**; PDF is deliberately kicked down the road.
- **Depends on:** the shipped `Documents.Importer` behaviour (Step 1). PDF slots in as another
  adapter behind that boundary with **zero schema change**.

## Why parked
The MVP / first paid version imports **docx only** (docx is solved via Pandoc). PDF→structured-AST
is a separate, genuinely hard problem and is not needed to ship or demo. Parking it keeps the MVP
lean.

## The decisive constraint (don't lose this)
PerfectPaper is a **proofreading** product: the canonical doc is the SSoT we show the author and
anchor feedback to. **Extracted text must reproduce the manuscript faithfully** — if extraction
silently alters/drops words, we'd proofread a corrupted version and flag text the author never
wrote. **Fidelity outranks structure.** This is what disqualifies an LLM as the primary text
*source* (see C).

## Scope when revived
- **Born-digital PDFs only** (real text layer — LaTeX/Word/Docs exports). No OCR. Authors upload
  their own manuscript, so a text layer is the norm; scanned/image PDFs are a later edge case.

## Approaches evaluated (2026-06-04)
- **A. poppler `pdftotext`** — extracts the real text layer. ✅ faithful, free, fast, just a binary
  (like pandoc), trivial adapter. ❌ weak structure (flat paragraphs; headings/sections not
  reliably recovered).
- **B. GROBID** *(favored long-run)* — ML model purpose-built for scholarly PDFs → structured TEI
  (title/authors/abstract/sections/refs). ✅ faithful text **and** academic structure, maps cleanly
  to our canonical AST. ❌ it's a **Java service** (Docker/HTTP) — a real operational dependency.
- **C. LLM / Claude (PDF→AST)** — reuse the Anthropic adapter. ✅ no new infra, flexible. ❌
  **fidelity risk is near-disqualifying** for the primary text source (paraphrase/omission corrupts
  the SSoT) + token cost/latency. *Possible* future role: labeling structure on poppler's faithful
  text — never as the text source.

## Recommendation on revival
GROBID (B) for the long-run domain fit, **if** the GROBID service is acceptable infra; otherwise
poppler (A) as a faithful-but-flat interim behind the same adapter, upgradeable to B with no schema
change. Reject C as primary extractor.

## Open questions for revival
- Is running a GROBID service acceptable operationally (deploy, scaling, cost)? If not, A-interim.
- Conversion-failure UX for PDFs that slip through (encrypted, image-only) → `:failed` + clear
  workspace message.
- Whether to use an LLM purely for structure-labeling on poppler text (faithful text preserved).
