# TUI Operation Hub Plan 001

## Current TUI Surface

Prior to this plan, the TUI entrypoint (`h-kernel-editor-tui`) directly presented the `ActualAdd` interaction state (editing transaction fields, selecting accounts, previewing candidates, confirming, and writing). There was no top-level operation selection, preventing future recovery of daily operations such as transaction reversal, multi-posting, account declaration, plan management, budget movements, household issues, or report browsing within a unified interface.

## Target Operation Vocabulary & Structural Boundaries

The target TUI top-level operation vocabulary is structured into the following categories:

* **Reports**: Menu and read-only surfaces for household reports and financial statements.
* **Actual**:
  * Ordinary add (Single source posting + balancing posting)
  * Multi-posting add
  * Transaction list / selection
  * Reverse transaction
* **Account**:
  * Account declaration
  * List / selection
* **Plan**:
  * List / selection
  * Add / finish / edit plan
  * Budget companion sync
* **Budget**:
  * Budget movement add
* **Issue**:
  * List / selection / add / close / drop
* **Status**:
  * Source admission state, operation availability, and writer authority boundary.

## Availability vs. Writer Authority Boundary

`OperationAvailability` is represented as an explicit Haskell typed ADT (`OperationEnabled` vs `OperationDisabled DisabledReason`) rather than informal strings or unstructured UI flags.

Displaying an operation in the TUI top-level hub does **not** imply that canonical writing is authorized for that domain. Writer authority for sources other than `actual.journal` (e.g., Plan, Budget, Issue) remains governed by explicit cutover plans and must not be mutated or inferred by UI components. Authority-unresolved operations remain explicitly disabled in the hub.

## Slice Scope: Operation Hub & Existing Actual Add Connection

In this slice (`feat/tui-operation-hub-001`), we introduce `HKernel.Editor.TUI.OperationHub`:

1. **Pure Top-Level Hub**:
   - `DailyOperation` enum vocabulary in deterministic order.
   - `DisabledReason` ADT (`OperationNotConnected`, `OperationAuthorityUnresolved`, `OperationAuthorityUnchanged`).
   - Pure state transition logic (`transitionOperationHub`) for navigation (`HubMoveUp`, `HubMoveDown`, `HubSelect`).
   - Complete isolation from private source contents, filesystem paths, and side effects.

2. **Connected Operation**:
   - `OperationActualAdd` is `OperationEnabled` and opens the existing `ActualAdd` Brick form flow.
   - Esc / Back from `ActualAdd` form returns to the `OperationHub` main menu.
   - Exit from the hub terminates the TUI safely without mutating any source file.
   - Argument contract (`h-kernel-editor-tui <actual.journal>`) is preserved.

3. **Unconnected / Disabled Operations**:
   - All other operations are typed `OperationDisabled` and cannot enter active input or write flows.

## Roadmap for Subsequent Finite Slices

1. Top-level operation hub & existing Actual add connection (**Current slice**)
2. Read-only Actual transaction list / selector
3. Actual reverse TUI (connecting existing Actual reverse pure engine)
4. Actual multi-posting TUI
5. Account declaration TUI
6. Report selection & read-only rendering
7. Plan read-only selector & source compatibility verification
8. Plan finish TUI
9. Plan add or Plan source cutover decision
10. Budget movement TUI after writer cutover decision
11. Issue lifecycle TUI after writer cutover decision
12. BQN-only maintenance or travel operation evaluation

## Private / Public Boundary & Source Protection

- Public test suites use synthetic fixture sources (`tests/fixtures/editor/actual-add.journal`).
- No private canonical source paths, accounts, dates, amounts, or contents are embedded in pure UI states or test logs.
- Safe publication and post-admission semantics established in PR #36 remain intact.

## Completion Criteria

- Pure `HKernel.Editor.TUI.OperationHub` module implemented and exposed in Cabal.
- `EditorTUIOperationHubSpec` focused pure test suite passing.
- Brick TUI app updated with top-level Operation Hub navigation.
- Only `OperationActualAdd` is enabled; disabled operations cannot trigger write flows.
- `cabal build all`, `cabal test all`, and `cabal run repository-audit` pass cleanly.
- Draft PR created for review on `feat/tui-operation-hub-001`.
