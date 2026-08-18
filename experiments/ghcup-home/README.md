# GHCup-style Home experiment

This is an isolated Brick interaction experiment for a status-first h-kernel Home.
It does not replace the production calendar-first Home and it owns no Household facts.

The first slice is deliberately data-neutral. It uses representative values only, so we can judge GHCup-like information density, selection, mouse behavior, and the selected-detail relationship without widening h-kernel's private package boundaries or inventing UI-owned semantics.

Rows represent the existing UI destinations (Actual, Plans, Envelopes, Accounts, Issues, Reports, Settings), a small status glyph, and one compact summary. Selecting a row reveals a little more context below it.

Run from the repository root:

```sh
cabal run --project-file=experiments/ghcup-home/cabal.project h-kernel-ghcup-home
```

Controls:

- Up/Down or j/k: select a row
- Mouse click: select a row
- q or Esc: quit

Deliberate limits for the first experiment:

- representative values only
- no Household loading
- no writes
- no new canonical data
- no new Envelope/Issue/Plan semantics
- no public exposure of private h-kernel sublibraries
- no replacement of the production Home
- no attempt to reproduce GHCup's colors or exact layout

The thing under observation is the interaction grammar: target + state + compact evidence, then selection for more detail.

If this grammar feels right in daily use, the next step is not to grow this demo into a second application. The presentation should instead move inside the existing editor TUI, where it can consume the already-admitted `AppContext` beside the calendar-first Home.
