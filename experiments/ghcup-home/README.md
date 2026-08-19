# GHCup-style Home experiment

This is an isolated Brick interaction experiment for a status-first h-kernel shell.
It does not replace the production calendar-first Home and it owns no Household facts.

The current experiment separates three things:

- the current Household observation used by the status rail
- the calendar temporal cursor used by calendar day detail
- the UI focus owner

The left side contains a compact calendar above a GHCup-like section rail. The right side deliberately changes role with focus instead of pretending that the calendar is a global date filter.

When Calendar owns focus, the right pane is the selected-day detail. It represents the existing Home intuition: choose a date and see that day's Actual, Plans, Issues due, and Cycle context.

When Sections owns focus, the right pane becomes the selected major Household surface. The section rail continues to describe the current observation. In this prototype no section consumes the calendar cursor at all. Their future relationship can therefore be designed later, per section, without changing the shell grammar.

Surface focus is entered explicitly from Sections with Right or Enter. Left returns to Sections. Tab moves Calendar -> Sections -> Surface -> Calendar. Mouse clicks focus/select the clicked area.

The right pane is greedy and takes the terminal space left by the compact 30-column rail. Sparse representative data can therefore remain visually quiet without shrinking the application into a small content-sized box.

Run from the repository root:

```sh
cabal run --project-file=experiments/ghcup-home/cabal.project h-kernel-ghcup-home
```

Controls depend on the focused area:

- Calendar: arrows or h/j/k/l move the day cursor, t returns to today
- Sections: Up/Down or j/k select, Right or Enter moves into the selected surface
- Surface: Left returns to Sections
- Tab: move explicitly to the next focus area
- Mouse: focus/select calendar day, section, or section surface
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
- no calendar-to-section semantics yet

The shell hypothesis is now:

`Calendar -> Day Detail`

or, after explicit focus movement:

`Section Rail -> Major Household Surface`

If this grammar feels right in daily use, the next step is not to grow this demo into a second application. The presentation should move inside the existing editor TUI and consume the already-admitted `AppContext`. Production section surfaces can remain specialized while sharing one stable shell.
