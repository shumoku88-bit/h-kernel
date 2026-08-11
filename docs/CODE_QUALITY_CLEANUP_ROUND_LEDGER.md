# Code Quality Cleanup Round Ledger

Status: ACTIVE WORK LEDGER
Started: 2026-08-11
Original audit basis: `ce225f195546c19dc0bc2b7532c168359d774f53`
Current implementation baseline: `31d427b2ec98a96d704206523b46ab5b2d292fbf`
Parent observation: `CODE_QUALITY_CLEANUP_ROUND_AUDIT_2026-08-11.md`

## Working loop

```text
ledger + actual remote
  -> one coherent terminal-AI implementation batch
  -> tests / push / PR
  -> STOP BEFORE MERGE
  -> independent actual-diff / CI review
  -> ledger update
  -> reviewer merge decision
  -> next coherent batch
```

Implementation reports are evidence, not source of truth. Every implementation and review starts by rechecking actual `main`, open PRs, changed files, and CI.

## Permanent cleanup rules

- Do not optimize for the smallest PR. Prefer one coherent batch with a few logical commits.
- Sharing is not a goal by itself.
- `same shape + same semantic owner + same reason to change` is only a sharing candidate.
- Observable diagnostics and failure mechanisms count as behavior.
- Repeated shapes with different owners, diagnostics, signatures, or failure paths may correctly remain local.
- Prefer deletion or an existing owner over new generic `Common`, `Utils`, `Framework`, `Shared`, Form, navigation, or effect infrastructure.
- Do not split modules by size or symmetry alone.
- Do not adopt formatter/linter/dead-code/test-framework tooling as repository law without separate evidence.
- Do not modernize syntax merely because GHC2024 permits it.
- Preserve exact arithmetic, Commodity separation, identity, provenance, source ownership, writer authority, include-graph meaning, fail-closed admission, stale-write rejection, post-admission/recovery, multi-posting ordering, and current-policy versus historical-evidence separation.
- Existing CLI/TUI behavior remains stable unless a separate UX change explicitly authorizes a behavior change.

# Batch A: mechanical repository plumbing

Status: **ACCEPTED / MERGED / MAIN REQUALIFIED**

Implementation PR: #206 `cleanup: reduce repository plumbing`
Original base: `ce225f195546c19dc0bc2b7532c168359d774f53`
Final PR head: `df80e81917cd64fd5d09f5154205a6d4084c667e`
Squash merge commit: `fb5c3409677710b007230e9c15516dbbdacf1ccc`

Accepted result:

- conservative Cabal `common-defaults` / `test-defaults` with component dependencies still explicit;
- `tested-with` aligned to the actual CI matrix without changing `base` bounds;
- Editor CLI target-path -> Household-root routing totalized as `Either HouseholdRootError HouseholdRoot`, with ordinary CLI failure rather than hidden partiality;
- exact-only neutral `Test.Support` sharing, with differing diagnostics/signatures/failure paths retained locally.

Batch A established the rule:

```text
same type is not enough
same success path is not enough
same broad purpose is not enough

share only when behavior + diagnostics + failure path + semantic role agree
```

PR CI #659 and post-merge main CI #660 passed GHC 9.10.3 / 9.12.4 / 9.14.1. The 9.10.3 qualification job also passed repository ownership audit and complete report contracts.

# Batch B: TUI delivery ownership

Status: **ACCEPTED / MERGED / POST-MERGE CI RUNNING**

Implementation PR: #207 `cleanup(tui): return workspace interactions to section owners`
Base: `fb5c3409677710b007230e9c15516dbbdacf1ccc`
Reviewed head: `32c7f33187eed9d5deb24caf9304cb35d8dbce6b`
Squash merge commit: `31d427b2ec98a96d704206523b46ab5b2d292fbf`
PR stats: 6 files, +331/-208.

## Accepted ownership result

`Main.handleWorkspaceEvent` no longer owns all section-local Workspace grammar.

### Main remains the shell

Main still owns:

- `UIState` / `AppWrapper` lifecycle;
- global Workspace quit (`Esc`, `q`, `Q`);
- SectionTab mouse switching;
- global `1`..`7` section switching;
- modal application states such as Report picker and Plan Budget-sync picker;
- publication/reload orchestration and reload-failure state;
- Settings scrolling, because no independent Settings owner exists and no symmetry-only module is justified.

### Actual owns Actual Workspace grammar

`HKernel.Editor.TUI.Actual` now owns:

- Account/Transaction wheel and row selection;
- Account/Transaction focus and Tab/Left/Right transitions;
- Enter Account -> Transactions focus;
- Enter Transaction -> Reverse request;
- Daily / Income / Multi requests;
- focus-aware list movement;
- Account filter re-evaluation after account movement/selection.

Its concrete `WorkspaceAction` only expresses Actual Workspace outcomes. It does not own `AppWrapper` or global UI state.

### Plan owns Plan Workspace grammar

`HKernel.Editor.TUI.Plan` now owns:

- Plan wheel/click/list movement;
- Add / Edit / Complete-and-Advance requests;
- Budget-sync picker request.

The completed-Plan picker construction remains in the shell, so no duplicate Plan-completion/Budget-sync semantic rule was introduced.

### Maintenance keeps concrete sub-owners distinct

`HKernel.Editor.TUI.Maintenance` uses separate concrete action types for:

- Budget Workspace;
- Accounts Workspace;
- Issues Workspace.

The implementation deliberately did not collapse these similar-looking routes into one generic Maintenance router.

### Report owns Reports Workspace grammar

`HKernel.Editor.TUI.Report` now owns:

- wheel/arrow/page/home/end scrolling;
- horizontal scrolling;
- report-selection shortcut keys;
- Report picker request.

### AppContext list lenses

`Model` now owns lenses for its own list fields:

- `contextWorkspaceAccountsL`
- `contextWorkspaceListL`
- `contextPlanListL`
- `contextIssueListL`

This was accepted as AppContext-local update machinery, not a generic navigation abstraction.

## Behavior review

Independent diff review confirmed the previous event precedence remains:

```text
SectionTab
-> Esc/q/Q
-> 1..7
-> current-section handler
```

Mouse routes, focus changes, list movement, report scrolling, and flow requests map directly to the previous Main cases.

One small observation is retained for future edits: Report-picker and Plan-Budget-sync-picker shell transitions currently use the handler-call context captured by Main. Their respective request paths do not mutate AppContext before returning the request, so this is safe today. Do not create an abstraction merely for that hypothetical future coupling; re-evaluate only if those request paths later gain context mutation.

No dedicated Brick event-test infrastructure was added. This was not treated as a blocker because the ownership change is directly characterizable from the one-to-one diff, existing tests/CI remain green, and adding routing/test infrastructure solely for this refactor would conflict with the cleanup guardrails.

PR CI #663 passed GHC 9.10.3 / 9.12.4 / 9.14.1. The 9.10.3 job also passed repository ownership audit and complete report contracts.

Post-merge main CI #664 started for `31d427b2...` and was still running when this ledger entry was written.

# Next: Batch C observation before implementation

Do not jump directly into a preselected refactor.

The next work is a fresh merged-main observation of two higher-risk ownership areas:

1. `HKernel.Household.Application` canonical Household load orchestration;
2. generic safe-publication machinery currently living under the historical `HKernel.Editor.ActualWriter` owner/name.

## Observation questions

For `Household.Application`:

- Is the staged Account -> Actual -> Plan -> Budget -> configs/issues pipeline merely verbose, or does its sequencing encode real admission dependencies?
- Can control flow be made more linear without weakening the rule that `HouseholdWriteSnapshot` seals typed state and exact root source bytes from one observation?
- Would an in-progress observation record reduce hand-threading, or merely rename arguments?
- Is `ExceptT` actually clearer here, or would it hide domain admission stages?

For safe publication / `ActualWriter`:

- Which types/functions are genuinely cross-domain publication mechanics?
- Which functions are Actual/Plan/Budget-specific source admission?
- Is the problem only the historical module name, or is ownership actually mixed?
- Can a source-neutral publication owner emerge without creating a generic writer framework?
- What callers and tests depend on the current owner/API?

Treat Account-in-Actual compatibility as a separate explicit product/source-contract decision. Do not retire it incidentally during this observation.

## Non-goals for the observation

- no implementation before evidence is accumulated;
- no generic repository/session/source-loader framework;
- no automatic `ExceptT` migration;
- no writer rename/split for aesthetics;
- no compatibility retirement;
- no source-format or private Household change.
