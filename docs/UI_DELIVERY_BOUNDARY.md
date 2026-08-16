# UI delivery boundary

Status: current contract  
Scope: Household editor projections and delivery adapters

## Purpose

TUI and future GUI deliveries may differ in widgets, navigation, focus, window lifecycle, and input mechanics without duplicating Household meaning.

The shared boundary is not a generic UI framework. It is the already-needed set of typed, rebuildable projections and editor operations derived from admitted Household state.

```text
canonical Household sources
  -> HKernel.Household.Application admission
  -> typed HouseholdState / HouseholdWriteSnapshot
  -> HKernel.Editor.* projections and editor operations
  -> TUI adapter
  -> future GUI adapter
```

## Shared owners

`HKernel.Editor.HouseholdWorkspace` owns pure Household workspace projections that multiple deliveries can consume, including:

- Account choices from the admitted registry
- newest-first Actual workspace transactions
- open Plan choices at an observation day
- Issue visibility/count projections
- ReportBook resolution for the observation day
- Home day projections for Actual, Plans, Issues, and cycle end

These are rebuildable views. They are not canonical facts and are not persisted as an independent authority.

Editor write preparation, preview, identity, stale-source rejection, publication, and post-admission remain owned by the existing `HKernel.Editor.*` modules.

## Delivery-local state

A delivery adapter owns its actual interaction mechanics. For the Brick TUI this includes:

- `Brick.Forms.Form`
- focus and cursor state
- `Brick.Widgets.List`
- viewport state
- key and mouse mapping
- unfinished text field contents
- visual layout and attributes

A future GUI should own its equivalent widget/window state rather than sharing Brick-shaped state or forcing both adapters through a generic widget abstraction.

## Extraction rule

Move logic out of a delivery adapter when both conditions hold:

1. it describes Household/editor meaning rather than widget mechanics; and
2. another delivery would otherwise need to reproduce the same decision or projection.

Do not extract merely because a source file is large. Do not invent `UIService`, generic repository interfaces, widget-neutral event algebras, or framework wrappers for hypothetical future adapters.

## Current refactoring direction

Before adding a GUI, prefer these finite cleanups:

1. keep Household/read-model construction outside `HKernel.Editor.TUI.Model`;
2. keep Home Actual/Plan/Issue/cycle selection outside Brick rendering;
3. move Actual workspace filtering and reversal availability to existing editor workspace owners when they are shared semantics;
4. move textual intent parsing out of TUI forms only when a second delivery needs the same input contract;
5. keep navigation abstractions concrete until two real deliveries demonstrate the same places and transitions.

This contract complements `PLATFORM_NEUTRAL_APPLICATION_POLICY.md`. It narrows that policy to the current editor surface without promising any particular GUI toolkit.
