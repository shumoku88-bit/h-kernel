# TUI Operation Hub Plan 001

## Current TUI Surface

Prior to this plan, the TUI entrypoint (`h-kernel-editor-tui`) directly presented the `ActualAdd` interaction state (editing transaction fields, selecting accounts, previewing candidates, confirming, and writing). There was no top-level operation selection, preventing future recovery of daily operations such as transaction reversal, multi-posting, account declaration, plan management, budget movements, household issues, or report browsing within a unified interface.

## Target Operation Vocabulary & Structural Boundaries

The target TUI top-level operation vocabulary is structured into the following categories:

* **Reports**: Menu and read-only surfaces for household reports and financial statements.
* **Actual**:
  * Ordinary add (Single source posting + balancing posting)
  * Multi-posting add
  * Transaction list / selection (Read-only browser)
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

In PR #38 (`feat/tui-operation-hub-001`), we introduced `HKernel.Editor.TUI.OperationHub`:

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

## Slice Scope: Read-Only Actual Transaction Browser Connection

In PR #39 (`feat/tui-actual-browser-001`), we introduce `HKernel.Editor.TUI.ActualBrowse` and project source-aligned records:

1. **Source-Aligned Record Projection & Identity Provenance**:
   - `HKernel.Actual.Journal` exposes `ActualTransactionRecord` for each admitted transaction in source order.
   - Preserves source alignment and exact transaction instances without deduplication or synthetic composite keys.
   - Explicitly distinguishes three identity provenance categories:
     1. **Explicit Event Identity** (`ActualWithExplicitEventIdentity ActualTransactionId`): Source carries an explicit `@event-id@` metadata tag; externally durable.
     2. **Plan-Derived Runtime Identity** (`ActualWithPlanDerivedRuntimeIdentity PlanId ActualTransactionId`): Source carries a `@plan-id@` without `@event-id@`; receives a rebuildable runtime identity derived from the Plan ID. No generated identity is written back to the journal, and it is explicitly not treated as an externally durable event identity.
     3. **No Identity** (`ActualWithoutIdentity`): Ordinary metadata-free transaction.

2. **Connected Operation & Fresh-Read Behavior**:
   - `OperationActualBrowse` is `OperationEnabled` and opens the read-only transaction browser.
   - When entering the browser, the TUI reads the current file from disk (`contextSourcePath`) to ensure fresh admission rather than using the startup text snapshot.
   - File read failures (`ActualBrowseFileReadFailed`) and journal admission failures (`ActualBrowseAdmissionFailed`) are classified into sanitized failure states without retaining raw source text, filesystem exceptions, or private paths in the UI state.
   - Renders explicit event identities as `[evt-...]`, plan-derived identities as `[plan-derived: ...]`, and ordinary transactions as `[no identity]`. Reversal target relations (`reverses`) are rendered distinctly from identity origins.
   - Esc / q returns to the `OperationHub` main menu.
   - Enter maintains row selection without triggering write intents or reversal side effects. Browser is strictly read-only and performs no source mutation.

## Current Enabled Operations

Currently, the following two operations are `OperationEnabled` in the TUI top-level hub:
- `OperationActualAdd`
- `OperationActualBrowse`

All other operations, including `OperationActualReverse`, remain typed `OperationDisabled` and cannot be entered.

## Roadmap for Subsequent Finite Slices

1. Top-level operation hub & existing Actual add connection (**PR #38**)
2. Read-only Actual transaction list / selector (**PR #39**)
3. TUI operation source snapshot lifecycle (**Next recommended slice**)
4. Durable identity creation / adoption decision
5. Actual reverse TUI (connecting existing Actual reverse pure engine)
6. Actual multi-posting TUI
7. Account declaration TUI
8. Report selection & read-only rendering
9. Plan read-only selector & source compatibility verification
10. Plan lifecycle operations
11. Budget movement TUI after writer cutover decision
12. Issue lifecycle TUI after capability/authority decision

## Remaining Correctness Boundary: Source Snapshot Lifecycle

The Actual transaction browser performs a fresh file read when opened. However, `OperationActualAdd` uses `AppContext.contextSource` (the startup in-memory text snapshot) for previewing and publishing.

After a successful publication, `contextSource` remains at its startup snapshot value. Executing a second Actual add within the same TUI session may lead to a stale source rejection during post-admission publication.

This is not a writer safety failure: the safe writer rejects publication when the expected source hash or content has changed (fail-closed behavior). It remains isolated as a TUI operation source snapshot lifecycle issue to be addressed in a subsequent finite slice.

## Private / Public Boundary & Source Protection

- Public test suites use synthetic fixture sources (`tests/fixtures/editor/actual-add.journal` and `tests/fixtures/editor/actual-browse.journal`).
- No private canonical source paths, accounts, dates, amounts, or contents are embedded in pure UI states or test logs.
- Safe publication and post-admission semantics established in PR #36 remain intact.

## Completion Criteria

- Pure `HKernel.Editor.TUI.OperationHub` module implemented and exposed in Cabal.
- `HKernel.Editor.TUI.ActualBrowse` pure module implemented and exposed in Cabal.
- `OperationActualAdd` and `OperationActualBrowse` are enabled in the hub; disabled operations cannot trigger input or write flows.
- Source-aligned transaction records project three distinct identity provenance states (explicit event identity, plan-derived runtime identity, and no identity).
- Transaction browser performs fresh file reads upon entry and sanitizes load failure kinds.
- Browser is strictly read-only, generates no write intent, and performs no source mutation.
- Focused test suites (`EditorTUIOperationHubSpec` and `EditorTUIActualBrowseSpec`) pass cleanly.
- `cabal build all`, `cabal test all`, `cabal run repository-audit`, and `./report-build && ./report-verify --fixture` pass cleanly.
- PR #39 updated for review on `feat/tui-actual-browser-001` (stacked on PR #38 `feat/tui-operation-hub-001`).
