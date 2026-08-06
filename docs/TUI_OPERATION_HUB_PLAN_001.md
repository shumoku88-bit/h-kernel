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
4. Durable identity creation / adoption decision (**PR #41**)
5. Ordinary Actual add durable identity creation (**PR #42**)
6. Plan finish durable event identity adoption (**Current slice**)
7. Actual reverse canonical new-event identity admission (**Next slice**)
8. Source-aligned no-identity adoption engine
9. Read-only browser identity adoption entrypoint
10. Actual reverse TUI
11. Actual multi-posting TUI
12. Account declaration TUI
13. Report selection & read-only rendering
14. Plan operations
15. Budget and Issue operations after authority decisions

## Slice Scope: Ordinary Actual Add Durable Identity Creation

In this slice (`feat/ordinary-actual-add-durable-identity-001`), we introduce `HKernel.Editor.ActualIdentity` and attach durable `evt-<UUID-v4>` event identities to ordinary Actual additions across both TUI and CLI entrypoints:

1. **Dedicated Identity Module & Production UUID v4 Generator**:
   - `HKernel.Editor.ActualIdentity` is the sole owner of candidate generation, canonical admission (`admitActualEventIdentityText`), collision checking, and finite retry logic.
   - Reuses `HKernel.Plan.Completion.ActualTransactionId` and `mkActualTransactionId` without defining redundant identity domain types.
   - Enforces exact `evt-` prefix, canonical lowercase hyphenated UUID text, version 4 nibble, and RFC variant nibble (`8`, `9`, `a`, `b`).
   - Production candidate generator uses `Data.UUID.V4.nextRandom` and `Data.UUID.toText` with `evt-` prefix (e.g. `evt-550e8400-e29b-41d4-a716-446655440000`).
   - Checks candidates against all effective identities in the admitted `ActualJournal` (both explicit event identities and plan-derived runtime identities) up to `actualIdentityAttemptLimit = 8`.

2. **TUI Identity Lifecycle & Stability**:
   - Identity is generated ONCE upon selecting `OperationActualAdd` from the Hub following snapshot load.
   - If snapshot load or identity generation fails, the TUI presents a sanitized failure screen (`ShowActualIdentityGenerationFailure`) without creating write intents.
   - Generated identity is stored in `ActualAddState` (`actualAddIdentity`) and is strictly preserved across all mode transitions within the operation session (Input, Account selection, invalid preview, valid preview, Back, re-preview, Confirmation, publication).
   - Hub re-entry starts a fresh operation session with a newly generated identity.

3. **CLI Explicit Event-ID Contract**:
   - CLI `append` requires an explicit `<evt-uuid-v4>` argument (`h-kernel-editor-cli append [--commit] <journal.txt> <evt-uuid-v4> <YYYY-MM-DD> <desc> ...`).
   - Validates `<evt-uuid-v4>` via `admitActualEventIdentityText` and rejects non-canonical identities as well as the legacy identity-free append grammar.

4. **Sanitized Failure Diagnostics & Backward Compatibility**:
   - Generator failure taxonomy (`ActualIdentityGenerationFailure`) contains no candidate strings, source text, filesystem paths, or raw `IOException` details.
   - Historical no-identity transactions in Journal sources remain valid accounting facts.

## Private / Public Boundary & Source Protection

- Public test suites use synthetic fixture sources (`tests/fixtures/editor/actual-add.journal` and `tests/fixtures/editor/actual-browse.journal`).
- No private canonical source paths, accounts, dates, amounts, or contents are embedded in pure UI states or test logs.
- Safe publication and post-admission semantics established in PR #36 remain intact.

## Completion Criteria

- Pure `HKernel.Editor.TUI.OperationHub` module implemented and exposed in Cabal.
- `HKernel.Editor.TUI.ActualBrowse` pure module implemented and exposed in Cabal.
- `HKernel.Editor.TUI.ActualSourceSnapshot` pure module implemented and exposed in Cabal.
- `HKernel.Editor.ActualIdentity` pure module implemented and exposed in Cabal with `admitActualEventIdentityText`.
- `OperationActualAdd` and `OperationActualBrowse` perform fresh source reads on operation entry and use immutable atomic snapshots.
- Source text and account registry are atomically coupled within `ActualSourceSnapshot`.
- TUI `OperationActualAdd` attaches a durable `evt-<UUID-v4>` event-id metadata to every added transaction block.
- CLI `append` requires explicit `<evt-uuid-v4>` and rejects non-canonical IDs and old identity-free grammar.
- Consecutive Actual add operations within the same TUI session start from current admitted source with distinct durable identities.
- Safe writer stale rejection remains active and fail-closed against external changes.
- Load and identity generation failures are sanitized and allow safe return to Hub for retry.
- Focused test suites (`EditorActualIdentitySpec`, `EditorTUIActualAddSpec`, `EditorCLIContractSpec`, `EditorTUIActualSourceSnapshotSpec`) pass cleanly.
- `cabal build all`, `cabal test all`, `cabal run repository-audit`, and `./report-build && ./report-verify --fixture` pass cleanly.
- PR updated for review on `feat/ordinary-actual-add-durable-identity-001` (stacked on PR #41 `docs/actual-identity-creation-adoption-001`).

