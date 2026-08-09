# Inline Account discovery implementation note — 2026-08-09

Status: implementation slice  
Baseline: `main` `ac8d7e74f16adb084ed2c6050f1e1894be36219e`

## Scope

Restore Account discovery at the existing Daily and Multi Actual Account fields without restoring a separate picker screen.

The human interaction is:

```text
focus Account field
  -> existing admitted Accounts are visible inline
  -> Up/Down chooses an Account
  -> Enter accepts and advances
  -> Tab remains ordinary form navigation
  -> exact canonical text remains a fallback
```

Returning to an Account field and choosing again changes only that Account coordinate. Other draft fields remain intact. Preview remains reversible: returning from Preview preserves the draft form for correction.

## Candidate meaning

Existing Account candidate laws remain authoritative:

- Daily destination: Expense Accounts;
- Daily payment source: Asset or Liability Accounts;
- Multi: every canonical Account;
- recent usage ranks candidates before presentation grouping;
- Account grouping uses typed `AccountType`, never textual-prefix inference;
- exact typed `Account` values supply the selected canonical identity.

The inline list groups candidates in stable typed order. Recent-first order is preserved within each type.

## Interaction subtraction

This slice deliberately does not add:

- a modal picker state;
- a generic tree widget;
- recursive `:` hierarchy navigation;
- search UI;
- Transfer- or Income-specific Daily flows;
- writer or source-format changes.

The Account field value itself acts as the current selector position, so no second selector state is required.

## Multi key ownership

When `MultiAccountField` has focus:

```text
Up/Down -> Account candidate selection
Enter   -> accept Account and move to amount
```

On other Multi fields:

```text
Up/Down -> previous/next posting row
Enter   -> Preview
```

This keeps the meaning visible and focus-local rather than hiding it behind a mode.

## Safety boundaries

Unchanged:

- Account identity semantics;
- Account declaration admission;
- exact arithmetic;
- transaction balance validation;
- Actual preview and candidate preparation;
- safe writer / stale-source rejection;
- whole-Household publication admission;
- Reverse;
- Plan lifecycle.

## Focused evidence

`EditorTUIActualAddSpec` now characterizes:

- typed Account grouping;
- order preservation within typed groups;
- stateless candidate stepping and wrap-around;
- Daily Account reselection preserving all other draft values;
- existing Multi selected-row isolation;
- existing Preview return preserving the draft.
