# Actual Add TUI rehearsal evidence 001

## Scope

This report records empirical verification evidence for the Actual Add Brick TUI component (`h-kernel-editor-tui`) on synthetic temporary source files under `h-kernel` (main branch).

The main objective of this rehearsal is to operate the Actual Add TUI flow across four core interaction scenarios and verify safety boundaries, transaction publication, stale write rejection, error display, and temporary artifact cleanup without touching private canonical ledger sources.

## Verified repository state

- **Recorded baseline SHA**: `f3536aa2389238d7ed2cb3dd8df06a896389f2a3`
- **Synchronized origin/main SHA**: `f3536aa2389238d7ed2cb3dd8df06a896389f2a3`
- **Starting working tree**: Clean (`git status --short` empty)
- **Merged PR check**: PR #28 (`refactor(editor): write outcomeの不可能状態を除く (#28)`) merged into `main`.

## Safety boundary

- **Private canonical source**: Untouched (not searched, read, or modified)
- **`ledger-data/actual.journal`**: Untouched
- **`tests/fixtures/editor/actual-add.journal`**: Original fixture untouched
- **Writer authority**: Retained by `bqn-ledger` (E8 writer cutover NOT performed)
- **Code & logic**: No TUI features added, no writer algorithms modified
- **System packages / dependencies**: None installed
- **Git operations**: No direct commit to `main`, no merges, no branch deletions

## Environment

- **OS**: macOS
- **GHC / Cabal**: GHC 9.10.3 / Cabal 3.16.1.0
- **Terminal interface**: `tmux` pseudo-TTY sessions (`hkernel-e7-rerun-cancel`, `hkernel-e7-rerun-success`, `hkernel-e7-rerun-stale`, `hkernel-e7-rerun-io`)
- **Workspace**: Synthetic temporary directory (`$RUN`) containing copies of `tests/fixtures/editor/actual-add.journal`

## Preflight verification

Ran unit and integration test suites before TUI rehearsal:

```bash
cabal build h-kernel-editor-tui
cabal test h-kernel-editor-actual-writer-test h-kernel-editor-tui-actual-add-test --test-show-details=direct
```

### Preflight Test Results

- `testActualBlockWrite`: PASS (`True`)
- `testActualBlockStaleReject`: PASS (`True`)
- `testActualBlockPostAdmissionFailureRestores`: PASS (`True`)
- `successful write result is observable`: PASS (`True`)
- `stale write result is observable`: PASS (`True`)
- `restored admission failure is recoverable`: PASS (`True`)
- `failed restoration requires verification`: PASS (`True`)
- `filesystem failure is observable`: PASS (`True`)

---

## Scenario A: confirmation cancellation

- **Mode**: Manually observed on pseudo-TTY (`tmux`)
- **Target source**: `$RUN/cancel.journal`

### Input Values

```text
Date: 2026-08-05
Description: Cancel rehearsal
From Account: assets:cash
To Account: expenses:food
Amount: 100 JPY
```

### Screen Progression & Captured UI

1. **Preview Screen**:
```text
           ┌─────────────────────────Preview────────────────────────┐
           │                                                        │
           │ Validation successful. Source unmodified.              │
           │                                                        │
           │ 2026-08-05 Cancel rehearsal                            │
           │   expenses:food  100 JPY                               │
           │   assets:cash  -100 JPY                                │
           │                                                        │
           │ [Esc/B] Back | [C] Continue to confirmation | [Q] Quit │
           │                                                        │
           └────────────────────────────────────────────────────────┘
```

2. **Confirmation Screen**:
```text
                  ┌────────────Confirm Actual Add───────────┐
                  │                                         │
                  │ Confirm this validated transaction?     │
                  │ No source write has occurred.           │
                  │                                         │
                  │ 2026-08-05 Cancel rehearsal             │
                  │   expenses:food  100 JPY                │
                  │   assets:cash  -100 JPY                 │
                  │                                         │
                  │ [Y] Confirm | [N/Esc] Cancel | [Q] Quit │
                  │                                         │
                  └─────────────────────────────────────────┘
```

3. **Cancellation Action**: Pressed `N` (or `Esc`). The UI returned immediately to the Preview screen.

### Post-Operation Verification

- **Source diff**: 0 lines diff (`diff -u $RUN/cancel.before $RUN/cancel.journal`)
- **SHA-256 (before)**: `5467755a6344e1c3b514b64f95a167e967cfbe34899967b2b8618ecf15dbedd1`
- **SHA-256 (after)**: `5467755a6344e1c3b514b64f95a167e967cfbe34899967b2b8618ecf15dbedd1`
- **Temporary artifacts**:
  - `$RUN/cancel.journal.backup.tmp`: Not found
  - `$RUN/cancel.journal.new.tmp`: Not found

---

## Scenario B: successful publication

- **Mode**: Manually observed on pseudo-TTY (`tmux`)
- **Target source**: `$RUN/success.journal`

### Input Values

```text
Date: 2026-08-05
Description: Rehearsal groceries
From Account: assets:cash
To Account: expenses:food
Amount: 100 JPY
```

### Screen Progression & Captured UI

1. **Confirmation & Publication**: Reached confirmation screen and pressed `Y`.
2. **Write Outcome Screen**:
```text
                 ┌─────────────Actual Add Result─────────────┐
                 │                                           │
                 │ Published and post-admitted successfully. │
                 │                                           │
                 │ [Esc/Q] Quit                              │
                 │                                           │
                 └───────────────────────────────────────────┘
```

### Post-Operation Verification

- **Source diff**:
```diff
--- $RUN/success.before
+++ $RUN/success.journal
@@ -13,3 +13,7 @@
 2024-01-01 Opening Balance
   assets:cash  1000 JPY
   equity:opening-balances  -1000 JPY
+
+2026-08-05 Rehearsal groceries
+  expenses:food  100 JPY
+  assets:cash  -100 JPY
```
- **Postings semantics**:
  - `expenses:food 100 JPY`
  - `assets:cash -100 JPY`
- **Source re-admission**: Admitted cleanly by parser after publication.
- **SHA-256 (before)**: `5467755a6344e1c3b514b64f95a167e967cfbe34899967b2b8618ecf15dbedd1`
- **SHA-256 (after)**: `9856fa35837b54a142f7b9d4a45f7fbcdd144c2affd76b6aea7cf3684b62f0ac`
- **Temporary artifacts**:
  - `$RUN/success.journal.backup.tmp`: Not found
  - `$RUN/success.journal.new.tmp`: Not found

---

## Scenario C: stale rejection

- **Mode**: Manually observed on pseudo-TTY (`tmux`)
- **Target source**: `$RUN/stale.journal`

### Input Values

```text
Date: 2026-08-05
Description: Stale rehearsal
From Account: assets:cash
To Account: expenses:food
Amount: 50 JPY
```

### Execution Steps & Captured UI

1. Reached Confirmation screen.
2. Externally modified source: `printf '\n' >> "$RUN/stale.journal"`.
3. Pressed `Y` on Confirmation screen in TUI.
4. **Write Outcome Screen**:
```text
      ┌────────────────────────Actual Add Result────────────────────────┐
      │                                                                 │
      │ Source changed after preview. Nothing was written.              │
      │ Restart the TUI and preview the current source before retrying. │
      │                                                                 │
      │ [Esc/Q] Quit                                                    │
      │                                                                 │
      └─────────────────────────────────────────────────────────────────┘
```

### Post-Operation Verification

- **Source diff**:
```diff
--- $RUN/stale.before
+++ $RUN/stale.journal
@@ -13,3 +13,4 @@
 2024-01-01 Opening Balance
   assets:cash  1000 JPY
   equity:opening-balances  -1000 JPY
+
```
- **Stale candidate transaction**: `Stale rehearsal` was **NOT** written to file.
- **SHA-256 (before)**: `5467755a6344e1c3b514b64f95a167e967cfbe34899967b2b8618ecf15dbedd1`
- **SHA-256 (after)**: `914ed24e52e3abed9a7867a101f44a7b3290a431d2dc1be40fd95535b572f4df`
- **Temporary artifacts**:
  - `$RUN/stale.journal.backup.tmp`: Not found
  - `$RUN/stale.journal.new.tmp`: Not found

---

## Scenario D: filesystem failure display

- **Mode**: Manually observed on pseudo-TTY (`tmux`)
- **Target source**: `$RUN/io-failure.journal`

### Input Values

```text
Date: 2026-08-05
Description: IO failure rehearsal
From Account: assets:cash
To Account: expenses:food
Amount: 25 JPY
```

### Execution Steps & Captured UI

1. Reached Confirmation screen.
2. Recorded original directory permission (`700`) and made directory write-restricted: `chmod 500 "$RUN"`.
3. Pressed `Y` on Confirmation screen in TUI.
4. **Write Outcome Screen**:
```text
        ┌───────────────────────Actual Add Result──────────────────────┐
        │                                                              │
        │ The writer could not complete because of a filesystem error. │
        │ No source-local error detail is retained in the TUI state.   │
        │ Verify the rehearsal source before continuing.               │
        │                                                              │
        │ [Esc/Q] Quit                                                 │
        │                                                              │
        └──────────────────────────────────────────────────────────────┘
```
5. Restored permissions immediately (`chmod 700 "$RUN"`).

### Post-Operation Verification

- **Sanitization check**: No raw directory path (`$RUN`), raw `IOException`, or OS error details were exposed in the UI.
- **Source diff**: 0 lines diff against `.before`
- **SHA-256 (before)**: `5467755a6344e1c3b514b64f95a167e967cfbe34899967b2b8618ecf15dbedd1`
- **SHA-256 (after)**: `5467755a6344e1c3b514b64f95a167e967cfbe34899967b2b8618ecf15dbedd1`
- **Permission restored**: Confirmed restored to `700`.
- **Temporary artifacts**:
  - `$RUN/io-failure.journal.backup.tmp`: Not found
  - `$RUN/io-failure.journal.new.tmp`: Not found

---

## Focused recovery evidence

The following recovery boundary behaviors were verified via focused test suites rather than manual race induction:

- `testActualBlockPostAdmissionFailureRestores`: Verified that post-admission failure restores original source backup.
- `restored admission failure is recoverable`: Verified that recovered state returns appropriate outcome signal.
- `failed restoration requires verification`: Verified that failed backup restoration requires explicit verification status.

### Verification Category Breakdown

| Scenarios / Boundary Cases | Verification Method | Status |
| :--- | :--- | :--- |
| Confirmation Cancellation | Manually Observed | PASSED |
| Successful Publication | Manually Observed | PASSED |
| Stale Rejection | Manually Observed | PASSED |
| Filesystem Failure Display | Manually Observed | PASSED |
| Post-Admission Failure Restore | Focused-Test Verified | PASSED |
| Restoration Failure Signal | Focused-Test Verified | PASSED |

---

## Source and temporary artifact verification

| Scenario | SHA-256 (Before) | SHA-256 (After) | Diff Lines | Backup Tmp | New Tmp |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **A: Cancel** | `5467755a...` | `5467755a...` | 0 | None | None |
| **B: Success** | `5467755a...` | `9856fa35...` | +4 | None | None |
| **C: Stale** | `5467755a...` | `914ed24e...` | +1 (newline) | None | None |
| **D: IO Failure** | `5467755a...` | `5467755a...` | 0 | None | None |

---

## Observed limitations

- Post-admission failure and backup restoration failure were verified through unit/focused test suites rather than manual fault injection to avoid unsafe filesystem corruption.
- Rehearsals were conducted strictly on synthetic test fixture copies (`tests/fixtures/editor/actual-add.journal`).

---

## Conclusion

1. **Confirmation Cancellation**: Cancelled before publication; zero source modification and zero temporary artifacts.
2. **Successful Publication**: Appended valid transaction, post-admitted successfully, cleaned up temporary artifacts.
3. **Stale Rejection**: Detected source change after preview; rejected candidate publication safely.
4. **Filesystem Failure**: Displayed finite, user-friendly failure outcome without leaking raw paths or stack traces.
5. **Recovery Contract**: Recovery logic verified by focused tests.
6. **Safety**: Private canonical sources were **NOT** touched; writer authority remains with `bqn-ledger`.
7. **Cutover Readiness**: E8 cutover readiness is not determined by this rehearsal report alone.
