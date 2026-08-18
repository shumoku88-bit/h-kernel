# GHCup-style Home experiment

This is an isolated Brick experiment for a status-first h-kernel Home.
It does not replace the production calendar-first Home and it owns no Household facts.

The experiment asks one UI question: can the Home read more like GHCup's compact status list while continuing to project only already-admitted h-kernel observations?

Rows expose existing domains (Actual, Plans, Envelopes, Accounts, Issues, Reports, Settings), a small availability/status glyph, and one compact summary. Selecting a row reveals a little more context below it.

Run from the repository root:

```sh
cabal run --project-file=experiments/ghcup-home/cabal.project h-kernel-ghcup-home -- <household-root-or-actual.journal>
```

Controls:

- Up/Down or j/k: select a row
- Mouse click: select a row
- q or Esc: quit

Deliberate limits for the first experiment:

- no writes
- no new canonical data
- no new Envelope/Issue/Plan semantics
- no replacement of the production Home
- no attempt to reproduce GHCup's colors or exact layout

The thing under observation is the interaction grammar: target + state + compact evidence, then selection for more detail.
