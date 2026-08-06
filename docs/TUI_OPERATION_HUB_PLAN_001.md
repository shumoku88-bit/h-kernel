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
3. TUI operation source snapshot lifecycle (**PR #40**)
4. Durable identity creation / adoption decision (**Current slice**)
5. Ordinary Actual add durable identity creation (**Next recommended slice**)
6. No-identity adoption engine and UI
7. Actual reverse TUI
8. Actual multi-posting TUI
9. Account declaration TUI
10. Report selection & read-only rendering
11. Plan operations
12. Budget and Issue operations after authority decisions

## Slice Scope: TUI Operation Source Snapshot Lifecycle

In the TUI source snapshot recovery slice (`fix/tui-actual-source-snapshot-001`), we introduced `HKernel.Editor.TUI.ActualSourceSnapshot` to govern the admission, immutability, and fresh-read lifecycle of source snapshots across TUI operations:

1. **Target Operation Lifecycle**:
   ```text
   Operation Hub
     -> fresh source read
     -> strict admission
     -> immutable operation snapshot
     -> preview/confirmation/publication
     -> safe stale detection
     -> Hub
     -> next operation performs another fresh read
   ```

2. **Atomic Snapshot & Registry Coupling**:
   - `ActualSourceSnapshot` guarantees that source text, admitted `ActualJournal`, and account declarations/registry originate from a single atomic admission pass (`admitActualSourceSnapshot`).
   - `AppContext` retains `contextActualSnapshot :: ActualSourceSnapshot` and automatically derives `contextSource`, `contextJournal`, and `contextAccounts`.
   - Prevents inconsistent states where source text and account declarations reflect different points in time or out-of-sync snapshots.

3. **Operation-Entry Refresh Boundary**:
   - Entering any Actual operation (`OperationActualAdd` or `OperationActualBrowse`) from the hub triggers a fresh file read and admission (`loadActualSourceSnapshot`).
   - Operation snapshots are immutable for the duration of an operation (e.g. across form input, account selection, preview, confirmation, and publication).
   - Successful candidate text is **never** manually concatenated or guessed in-memory to update `AppContext` after publication.
   - Returning to the Hub and selecting the next operation is the canonical refresh boundary where a fresh snapshot is loaded from disk.

4. **Shared Admission Boundary & Fail-Closed Stale Protection**:
   - Both `OperationActualAdd` and `OperationActualBrowse` utilize the same `ActualSourceSnapshot` load and admission boundary.
   - If an external source modification occurs during an operation, the safe writer detects expected vs current source mismatch and rejects publication as `StaleFile` without mutating the file.
   - Load failures (`ActualSourceFileReadFailed` and `ActualSourceAdmissionFailed`) are sanitized into `ShowActualSourceLoadFailure` without exposing raw source text, IOException details, or filesystem paths.
   - Safe writer semantics, backup/rollback, and writer authority remain unchanged.

5. **Sole Ownership of Load & Admission Responsibility**:
   - `HKernel.Editor.TUI.ActualSourceSnapshot` is the sole owner of source file reading, journal admission, sanitized load failure classification, and immutable snapshot construction.
   - `HKernel.Editor.TUI.ActualBrowse` consumes admitted snapshots/journals to project row states (`buildActualBrowseRows`, `initialActualBrowseStateFromSnapshot`) and no longer maintains a parallel `ActualBrowseLoadFailure` or `classifyActualBrowseLoad` helper.
   - Startup load failures in the executable (`Main.hs`) are sanitized (`actualSourceStartupFailureText`) and never disclose the supplied filesystem path, IOException details, or source text in stderr or diagnostic output.

## Private / Public Boundary & Source Protection

- Public test suites use synthetic fixture sources (`tests/fixtures/editor/actual-add.journal` and `tests/fixtures/editor/actual-browse.journal`).
- No private canonical source paths, accounts, dates, amounts, or contents are embedded in pure UI states or test logs.
- Safe publication and post-admission semantics established in PR #36 remain intact.

## Completion Criteria

- Pure `HKernel.Editor.TUI.OperationHub` module implemented and exposed in Cabal.
- `HKernel.Editor.TUI.ActualBrowse` pure module implemented and exposed in Cabal.
- `HKernel.Editor.TUI.ActualSourceSnapshot` pure module implemented and exposed in Cabal.
- `OperationActualAdd` and `OperationActualBrowse` perform fresh source reads on operation entry and use immutable atomic snapshots.
- Source text and account registry are atomically coupled within `ActualSourceSnapshot`.
- Consecutive Actual add operations within the same TUI session start from current admitted source without startup text re-use.
- Safe writer stale rejection remains active and fail-closed against external changes.
- Load failures are sanitized and allow safe return to Hub for retry.
- Focused test suites (`EditorTUIOperationHubSpec`, `EditorTUIActualBrowseSpec`, `EditorTUIActualSourceSnapshotSpec`) pass cleanly.
- `cabal build all`, `cabal test all`, `cabal run repository-audit`, and `./report-build && ./report-verify --fixture` pass cleanly.
- PR updated for review on `fix/tui-actual-source-snapshot-001` (stacked on PR #39 `feat/tui-actual-browser-001`).
