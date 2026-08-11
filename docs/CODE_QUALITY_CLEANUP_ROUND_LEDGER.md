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

Status: **ACCEPTED / MERGED / MAIN REQUALIFIED**

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

Post-merge main CI #664 also passed all three supported GHC versions; the GHC 9.10.3 job again passed repository ownership audit and complete report contracts.

# Batch C observation: canonical observation and safe publication ownership

Status: **OBSERVED / SPLIT BY SEMANTIC RISK**

Observation baseline: `main` at `31d427b2ec98a96d704206523b46ab5b2d292fbf`, main CI #664 successful.

The two original Batch C candidates are related by coordinated publication, but they are not the same kind of cleanup debt. Do not force them into one PR merely because they were listed together in the repository-wide audit.

```text
C1 Household.Application
  -> correct owner, hand-threaded orchestration

C2 publication owner / historical ActualWriter name
  -> cross-domain mechanics already exist, ownership/name may be stale
```

The risk differs enough to justify separate coherent implementation/review cycles.

## C1 observation: `HKernel.Household.Application`

### What is already correct

`HKernel.Household.Application` is the correct canonical composition owner.

Current source topology remains eight canonical inputs:

```text
accounts.journal
actual.journal
plan.journal
budget.journal
budget.toml
household.toml
report.toml
issues.tsv
```

`loadCanonicalHouseholdWriteSnapshot` remains the canonical observation boundary. `HouseholdWriteSnapshot` deliberately retains exact mutable root bytes for Accounts / Actual / Plan / Budget / Issues together with the typed `HouseholdState` produced by the same load pass. It is not a repository/session abstraction and must not grow merely for symmetry.

Actual / Plan / Budget still use named source-specific admission after Loader root observation. Config and Issue sources retain their own parsers. No generic source parser is wanted.

### The actual debt

The IO path is currently expressed as a nested chain:

```text
loadCanonicalHouseholdWriteSnapshot
  -> accounts read/parse
  -> loadActual
  -> loadPlan
  -> loadBudget
  -> loadConfigsAndIssues
```

Each stage carries an increasing positional argument list containing exact root `Text` plus the typed value admitted from that root. The semantics are coherent, but the control flow makes the ownership harder to scan and creates repeated `read -> case -> parse/admit -> case` scaffolding.

This is orchestration debt, not domain-model debt.

### A second duplication seam

`admitCanonicalHousehold` independently performs the same broad assembly invariants for the pure in-memory path:

- Account registry admission;
- Actual / Plan / Budget registry agreement;
- Budget policy and Household configuration;
- Household policy Account validation;
- Household Account policy registry validation;
- Report configuration;
- Issues;
- Daily Target scope;
- final `HouseholdState` construction.

Its source acquisition differs intentionally from the IO path: the in-memory helper resolves only the explicitly supplied canonical text relationship, while the filesystem Loader supports ordinary include graphs. Do not collapse those source-acquisition semantics.

The promising shared boundary is therefore **after source-specific admission**, at common Household validation/assembly, not before it.

### C1 likely implementation direction

One coherent C1 PR should investigate a linear orchestration with these constraints:

1. Preserve source read/admission order and first-failure behavior.
2. Preserve exact root bytes paired with the typed meaning admitted from those bytes.
3. Preserve Loader include-graph behavior for filesystem Journal roots.
4. Keep source-specific Actual / Plan / Budget admission named and visible.
5. Extract only genuinely common post-admission Household validation/assembly shared by the IO and in-memory paths.
6. Remove growing positional hand-threading where a small private typed record materially prevents source/value mismatches.
7. `ExceptT` is an allowed implementation candidate because this is genuinely sequential fail-closed IO, but it is not a predetermined requirement. Adopt it only if the final code is visibly more linear and the extra `transformers` dependency on the Household application library is a net simplification.
8. Do not parallelize source reads. Current sequencing controls dependencies and observable first failure.
9. Do not accumulate independent errors merely for cleanup aesthetics; current loader is fail-closed and effectively first-failure.
10. Do not change public `HouseholdState`, `HouseholdWriteSnapshot`, or `HouseholdLoadError` semantics in this cleanup slice unless an actual impossibility is discovered.

A focused synthetic parity law would be useful if the refactor exposes the seam naturally: for a direct canonical synthetic source set, filesystem `loadCanonicalHousehold` and pure `admitCanonicalHousehold` should assemble the same `HouseholdState`. This does not claim parity for arbitrary filesystem include graphs; it only protects the common post-admission assembly contract.

### C1 non-goals

- no generic repository/session/source-loader framework;
- no new universal `LoadedSource` hierarchy merely to reduce argument count;
- no change to canonical source count or formats;
- no change to source-specific include semantics;
- no `HouseholdWriteSnapshot` widening for config files without a concrete coordinated writer need;
- no publication/writer rename in the same PR.

## C2 observation: safe publication under `HKernel.Editor.ActualWriter`

### The generic kernel is already real

The current module name understates the responsibility. The following exported machinery is source-neutral:

- `ExpectedSource`
- `CandidateSource`
- `WriteIntent`
- `WriteError`
- `WriterFileSystem`
- `defaultWriterFileSystem`
- `publishWithAdmission*`
- `publishWithPathAdmission*`
- stale detection, unique sibling staging, atomic rename, post-admission, guarded rollback, and final candidate re-check.

The test suite named `EditorActualWriterSpec` already exercises generic safe-publication laws and Plan publication in addition to Actual publication.

`PlanCompleteAdvance` imports `WriterFileSystem` and `defaultWriterFileSystem` from `HKernel.Editor.ActualWriter` solely for coordinated Plan+Actual publication. This is direct evidence that the filesystem/publication kernel is not Actual-owned.

### Production callers are cross-domain

The current Editor CLI imports `HKernel.Editor.ActualWriter` broadly and uses its generic publication functions for canonical Account, Budget and Issue publication, while also using Actual and Plan-specific adapters.

The TUI likewise uses:

- Actual-specific block publication for Actual;
- Plan-specific root admission/publication for Plan;
- generic whole-Household `publishWithPathAdmission` for Budget, Account, Issue, and Plan Budget-sync publication.

Therefore the naming mismatch is not hypothetical.

### But writer authority is a separate product contract

Current writer-authority documentation deliberately states that canonical `actual.journal` writer authority belongs to the h-kernel editor, while write capability for Plan / Budget / Issue does **not** automatically move canonical writer authority for those sources.

A source-neutral code owner must not be named or documented in a way that implies:

```text
has safe publication capability
== canonical writer authority for every source
```

This is the main semantic risk in C2.

### C2 conclusion for now

Do **not** preselect a module rename/split yet.

After C1 is reviewed, re-audit whether the smallest honest correction is:

- a source-neutral publication module with domain-named adapters;
- a rename of the existing module without structural splitting;
- or a generic publication kernel plus thin Actual/Plan/Budget admission owners.

Module size alone is not evidence. Avoid creating `ActualWriter`, `PlanWriter`, `BudgetWriter`, `IssueWriter` merely for symmetry.

Any C2 proposal must separately inventory:

- exposed-module/API impact;
- all production imports;
- safe-writer law tests;
- writer-authority documentation;
- coordinated `PlanCompleteAdvance` filesystem dependency;
- retained compatibility paths.

Account-in-Actual compatibility remains a separate product/source-contract decision and must not be retired incidentally.

# Next coherent implementation candidate

**C1 only: linearize `HKernel.Household.Application` orchestration and unify only the genuinely shared post-admission Household assembly boundary.**

Do not implement C2 in the same PR. Re-observe publication ownership after C1 is independently reviewed and merged.