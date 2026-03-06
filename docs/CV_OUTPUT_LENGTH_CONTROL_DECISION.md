# CV Output Length Control — Decision Record

_Last updated: 2026-03-06_

## Context

CareerForge strict smoke tests repeatedly failed because generated CVs exceeded one A4 page, even when factual guardrails passed. We needed an approach that limits output size without degrading relevance or introducing factual drift.

## Decision

We adopted a **multi-layer output control strategy**:

1. **Section budgets in prompts**
   - Explicit per-section limits (summary, skills, experience, projects, education support text).
   - Goal: steer length early, before layout overflows.

2. **Two-pass generation**
   - Pass 1: tailored generation + ATS refinement.
   - Pass 2 (conditional): one-page compaction pass only when rendered content still exceeds one page.

3. **Runtime one-page validator**
   - Measure rendered HTML against A4 printable height before PDF export.
   - If strict mode is enabled and page count > 1, trigger compaction retries.

4. **Compaction retries with safety guards**
   - Up to 2 compaction attempts.
   - Keep immutable facts and locked links enforced after each pass.

5. **Factual integrity and link integrity stay strict**
   - Name/contact/education core facts preserved.
   - Locked links restored exactly via placeholders.
   - No new city/residence/address unless baseline explicitly contains them.

## Why this decision

This approach balances quality and control better than a single hard token cap:

- A hard cap alone often truncates useful content and can hurt readability.
- Prompt budgets alone are not always sufficient for strict one-page PDF rendering.
- Runtime layout validation ensures the final artifact matches user-visible constraints.
- Conditional compaction avoids over-compressing outputs that already fit in one page.

## Alternatives considered

- **Only max output tokens**: simple, but too coarse; can reduce quality abruptly.
- **Only strict prompt instructions**: cheaper, but non-deterministic for layout.
- **Always force compaction**: predictable length, but unnecessary quality loss when already one page.

## Operational guidance

- Keep `strict-one-page` enabled in smoke and CI checks.
- If strict fails repeatedly, inspect generated HTML density and adjust section budgets first.
- Prefer tightening section budgets over reducing factual constraints.

## Implementation footprint

- `src/cli.ts`
  - One-page estimation
  - Conditional compaction retry loop (max 2)
  - Strict fail only after compaction attempts
- `src/gemini.ts`
  - One-page compaction function
  - Prompt section budgets
  - Immutable fact + link guardrails preserved across passes
