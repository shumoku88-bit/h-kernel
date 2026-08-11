# Code Quality Cleanup Round Ledger

Status: ACTIVE WORK LEDGER
Started: 2026-08-11
Original audit basis: `ce225f195546c19dc0bc2b7532c168359d774f53`
Current implementation baseline: `e9f088b25f8eb2b366d69dddfe8af3f0d19c7de8`
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
- Editor CLI target-path -> Household-root routing totalized as `Either HouseholdRootError HouseholdRoot`;
- exact-only neutral `Test.Support` sharing, with differing diagnostics/signatures/failure paths retained locally.

Batch A established:

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

Accepted ownership result:

- `Main` remains application shell and global routing owner;
- Actual / Plan / Budget / Accounts / Issues / Reports own their section-local Workspace interaction grammar;
- Maintenance keeps Budget / Accounts / Issues action types concrete rather than forcing one generic router;
- Settings remains shell-owned because there is no independent owner and symmetry does not justify a module;
- AppContext list lenses live with `Model`, their natural owner;
- no generic navigation/Form/effect framework was introduced.

Independent diff review confirmed keyboard/mouse precedence and section behavior remained stable. PR CI #663 and post-merge main CI #664 passed all supported GHC versions; 9.10.3 also passed repository ownership audit and complete report contracts.

# Batch C: canonical observation and safe publication ownership

The original Batch C observation identified two different risk classes and intentionally split them:

```text
C1 Household.Application
  -> correct owner, hand-threaded orchestration

C2 safe publication under historical ActualWriter name
  -> cross-domain mechanics already exist, ownership/name may be stale
```

Do not combine these merely because coordinated publication connects them.

# Batch C1: Household application orchestration

Status: **ACCEPTED / MERGED / POST-MERGE CI RUNNING**

Implementation PR: #208 `cleanup(household): linearize canonical application assembly`
Base: `31d427b2ec98a96d704206523b46ab5b2d292fbf`
Initial reviewed head: `74022c11bb8088cad466405c7b4eb30e1b3a87c4`
Final reviewed head: `460842561a4c931b43454249daf332dddc10c72f`
Squash merge commit: `e9f088b25f8eb2b366d69dddfe8af3f0d19c7de8`
Final PR stats: 3 files, +290/-241.

## Accepted result

`HKernel.Household.Application` remains the canonical composition owner and `HouseholdWriteSnapshot` remains the sealed same-observation boundary.

The old nested IO chain:

```text
loadCanonicalHouseholdWriteSnapshot
  -> accounts read/parse
  -> loadActual
  -> loadPlan
  -> loadBudget
  -> loadConfigsAndIssues
```

was replaced with one local `ExceptT (NonEmpty HouseholdLoadError) IO` orchestration block. `ExceptT` was accepted here because it deletes nested callback plumbing while keeping source-specific stages visible. It was not generalized into an application effect framework.

Source-specific admission remains explicit:

- Accounts: `parseAccountJournal`;
- Actual / Plan / Budget: exact root Text -> Loader root observation -> named domain admission;
- Budget / Household / Report TOML: their existing parsers;
- Issues TSV: its existing parser.

Filesystem include-graph resolution and pure in-memory resolution remain intentionally different owners.

The shared seams are limited to genuinely common Household semantics:

- registry agreement checking;
- Household policy/account-policy validation;
- final Daily Target / `HouseholdState` assembly.

The pure and filesystem paths now have a direct synthetic `HouseholdState` parity characterization.

## Review correction

The first implementation moved Household policy/account-policy validation after Report and Issues admission. That changed observable first-failure precedence and was rejected as a cleanup semantic change.

The final accepted head restores the original ordering in both filesystem and pure paths:

```text
budget.toml
-> household.toml
-> Household policy/account-policy validation
-> report.toml
-> issues.tsv
-> Daily Target assembly
-> HouseholdState
```

A focused characterization now places invalid Household policy evidence and invalid Report syntax together and verifies that the Household policy validation error remains first.

This review reinforces the cleanup rule:

> failure precedence is observable behavior; moving validation across another admission boundary is not merely rearranging code.

## Preserved boundaries

- exact root byte ownership for Accounts / Actual / Plan / Budget / Issues;
- same-observation `HouseholdWriteSnapshot` integrity;
- source read/admission order and first-failure behavior;
- Account registry agreement with Actual / Plan / Budget;
- include-graph behavior;
- Daily Target typed Plan metadata/reservation behavior;
- public `HouseholdState`, `HouseholdWriteSnapshot`, `HouseholdLoadError` and public entrypoint semantics;
- current canonical source topology;
- no C2 writer/publication changes.

PR CI #668 passed GHC 9.10.3 / 9.12.4 / 9.14.1. The GHC 9.10.3 job also passed repository ownership audit and complete report contracts.

Post-merge main CI #669 started for `e9f088b25f8eb2b366d69dddfe8af3f0d19c7de8` and was still running at this ledger update.

# Next: Batch C2 observation only

Do not jump directly to a rename or split.

Re-observe safe publication on merged main after C1 and determine the smallest honest owner correction.

Current evidence already established that `HKernel.Editor.ActualWriter` contains a real source-neutral publication kernel:

- `ExpectedSource`
- `CandidateSource`
- `WriteIntent`
- `WriteError`
- `WriterFileSystem`
- `defaultWriterFileSystem`
- `publishWithAdmission*`
- `publishWithPathAdmission*`
- stale detection
- unique sibling staging
- atomic publication
- post-admission
- guarded rollback
- final candidate re-check

It is used across Actual, Plan, Account, Budget, Issue and coordinated Plan+Actual paths, so the historical module name is genuinely narrower than its current responsibility.

However writer capability and canonical writer authority remain different concepts. Current source-authority documentation says canonical `actual.journal` writer authority belongs to h-kernel editor, while Plan / Budget / Issue write capability does not itself transfer canonical writer authority.

Before implementation, inventory on actual merged main:

1. every production import of `HKernel.Editor.ActualWriter`;
2. every exported source-neutral type/function versus Actual/Plan/Budget-specific admission adapter;
3. `EditorActualWriterSpec` law coverage and whether the test name is also stale;
4. `PlanCompleteAdvance` dependency on `WriterFileSystem`;
5. h-kernel.cabal exposed-module/API consequences;
6. writer-authority and migration docs that could be semantically confused by a source-neutral module name;
7. retained Account-in-Actual compatibility paths.

Possible outcomes to compare, not preselect:

- rename the existing owner with minimal movement;
- extract one source-neutral publication owner and keep named domain adapters nearby;
- split only the publication kernel from domain-specific admission if that yields a clearer owner with fewer misleading imports.

Explicit non-goals:

- no generic repository/session framework;
- no universal Writer typeclass/framework;
- no `ActualWriter` / `PlanWriter` / `BudgetWriter` / `IssueWriter` symmetry fan-out;
- no writer-authority migration;
- no source-format change;
- no Account-in-Actual retirement;
- no coordinated writer rewrite merely to reuse more code;
- no behavior change to stale checks, atomic staging, rollback, or final verification.
