# TUI ledger workspace 001

## Purpose

Make the Brick TUI a persistent household-ledger workspace instead of starting in an operation form.

The home screen shows admitted household state first. Operations are actions from that state.

## First slice

The first workspace slice is intentionally small:

- show declared Accounts in a left pane;
- show admitted Actual transactions in source order in a selectable list;
- show every posting of the selected transaction in a detail pane;
- keep `j`/`k` and arrow navigation inside the transaction list;
- enter the existing ordinary Actual add flow with `a`;
- return from the uncommitted add input form to the workspace with `Esc`.

## Not in this slice

- no reverse action;
- no Plan or Budget workspace tabs;
- no command palette;
- no identity creation or adoption policy;
- no fresh-source reload lifecycle;
- no writer, parser, Journal, or accounting semantics changes;
- no private canonical source access.

The existing Actual add validation, preview, confirmation, and safe publication path remains unchanged.

## Direction

The intended interaction model is:

`see household state -> select a domain value -> act -> return to household state`

This replaces the command-hub-first model without importing the retired PR #38-#44 stack wholesale. Useful semantics from those branches may be reconsidered later from fresh `main` slices.
