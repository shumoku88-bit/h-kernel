# GHCup-style Home experiment

This is an isolated Brick interaction experiment for a status-first h-kernel shell.
It does not replace the production calendar-first Home and it owns no Household facts.

The experiment now tests a stronger hypothesis than the first status list: a persistent left rail can carry both temporal navigation and section navigation while the right pane becomes the selected Household surface.

The left rail contains:

- a compact month calendar, where the selected day is the temporal coordinate
- GHCup-like section rows for Actual, Plans, Envelopes, Accounts, Issues, Reports, and Settings
- a small status glyph and compact summary on each section row

The right pane represents the selected section at the selected day. Values remain representative only, so the experiment can judge layout, density, navigation, and the relationship between `when` and `what` without widening h-kernel's private package boundaries or inventing UI-owned semantics.

Run from the repository root:

```sh
cabal run --project-file=experiments/ghcup-home/cabal.project h-kernel-ghcup-home
```

Controls:

- Up/Down or j/k: select a section
- Left/Right or h/l: move the selected day
- t: return the calendar to today
- Mouse click: select a calendar day or section
- q or Esc: quit

A non-interactive runtime smoke path is also available:

```sh
cabal run --project-file=experiments/ghcup-home/cabal.project h-kernel-ghcup-home -- --smoke
```

The smoke path deliberately uses an OS-bound thread, so CI catches a missing `-threaded` link instead of merely proving that the executable compiled.

Deliberate limits:

- representative values only
- no Household loading
- no writes
- no new canonical data
- no new Envelope/Issue/Plan semantics
- no public exposure of private h-kernel sublibraries
- no replacement of the production Home
- no attempt to reproduce GHCup's colors or exact layout

The thing under observation is now a shell grammar:

`calendar = when` + `section rail = what` -> `right pane = observation surface`

If this grammar feels right in daily use, the next step is not to grow this demo into a second application. The presentation should move inside the existing editor TUI and consume the already-admitted `AppContext`. The production section surfaces can then remain specialized while sharing one stable temporal/navigation shell.
