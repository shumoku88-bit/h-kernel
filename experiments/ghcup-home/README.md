# GHCup-style Home experiment

This is an isolated Brick interaction experiment for a status-first h-kernel shell.
It does not replace the production calendar-first Home and it owns no Household facts.

The current experiment separates three things that looked dangerously similar in the earlier prototype:

- the current Household observation day
- the calendar temporal cursor
- the UI focus owner

The status rail always describes the current observation. Moving the calendar into the past or future does not silently reinterpret every status row at that date.

The calendar is instead a temporal cursor. Surfaces that have a meaningful temporal coordinate may consume it. Actual, Plans, Envelopes, Issues, and Reports demonstrate that relationship. Accounts and Settings deliberately remain unbound from the cursor.

The shell also has explicit focus ownership:

- Calendar focus: arrows move naturally in the month matrix, with Left/Right = one day and Up/Down = one week
- Section focus: Up/Down selects a section
- Surface focus: the right pane owns its interaction space; Left returns to the section rail in this prototype
- Tab explicitly moves between Calendar, Sections, and Surface
- Mouse clicks both select and focus the clicked area

Selection survives focus movement. Changing focus does not erase the temporal cursor or selected section.

Run from the repository root:

```sh
cabal run --project-file=experiments/ghcup-home/cabal.project h-kernel-ghcup-home
```

Controls depend on the focused area:

- Calendar: arrows or h/j/k/l move the temporal cursor, t returns the cursor to today
- Sections: Up/Down or j/k select, Right or Enter moves into the selected surface
- Surface: Left returns to Sections
- Tab: move explicitly to the next focus area
- Mouse: focus/select calendar day, section, or surface
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

The thing under observation is now:

`current status rail` + `temporal cursor` + `focus-local interaction` -> `selected observation surface`

If this grammar feels right in daily use, the next step is not to grow this demo into a second application. The presentation should move inside the existing editor TUI and consume the already-admitted `AppContext`. The production section surfaces can remain specialized while sharing one stable shell.
