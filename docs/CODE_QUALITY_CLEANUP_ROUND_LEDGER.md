# Code Quality Cleanup Round Ledger

Status: ACTIVE WORK LEDGER
Started: 2026-08-11
Original audit basis: `main` at `ce225f195546c19dc0bc2b7532c168359d774f53`
Current implementation baseline after Batch A: `fb5c3409677710b007230e9c15516dbbdacf1ccc`
Parent observation: `CODE_QUALITY_CLEANUP_ROUND_AUDIT_2026-08-11.md`

## Working loop

```text
current ledger + actual remote
  -> one coherent terminal-AI implementation batch
  -> tests / push / PR
  -> STOP BEFORE MERGE
  -> independent actual-diff / CI review
  -> ledger update
  -> reviewer merge decision
  -> next coherent batch
```

Every implementation and review starts by rechecking actual `main`, open PRs, changed files, and CI. Reports from implementation agents are evidence, not source of truth.

## Batch sizing rule

Do not optimize for the smallest possible PR. Prefer one coherent batch with a few logical commits over one PR per helper/import/stanza/case expression.

Split only when semantic risk, qualification, blocking dependencies, or ownership clarity materially differ.

## Permanent guardrails

- Sharing is not a goal by itself.
- `same shape + same semantic owner + same reason to change` is only a sharing candidate.
- Observable diagnostics and failure mechanisms count as behavior for cleanup review.
- Repeated shapes with different owners, diagnostics, signatures, or failure paths may correctly remain local.
- Prefer deletion or an existing owner over new generic `Common`, `Utils`, `Framework`, `Shared`, Form, navigation, or effect infrastructure.
- Do not split modules by size alone.
- Do not adopt formatter/linter/dead-code/test-framework tooling as repository law without separate evidence.
- Do not modernize syntax merely because GHC2024 permits it.
- Preserve exact arithmetic, Commodity separation, identity, provenance, source ownership, writer authority, include-graph meaning, fail-closed admission, stale-write rejection, post-admission/recovery, multi-posting ordering, and current-policy versus historical-evidence separation.
- Existing CLI/TUI behavior remains stable unless a separate UX change authorizes behavior change.

# Batch A: mechanical repository plumbing

Status: **ACCEPTED AND MERGED**

Implementation PR: #206 `cleanup: reduce repository plumbing`
Original base: `ce225f195546c19dc0bc2b7532c168359d774f53`
Final actual PR head: `df80e81917cd64fd5d09f5154205a6d4084c667e`
Squash merge commit: `fb5c3409677710b007230e9c15516dbbdacf1ccc`
Final GitHub PR stats: 39 changed files, +201/-534.

The terminal report contained a small head-SHA typo (`df80e816...`) and stale aggregate diff statistics. Review used GitHub's actual head and actual PR metadata instead.

## Accepted result

### A1 Cabal defaults

- introduced `common-defaults` for shared GHC2024 / warning policy;
- introduced `test-defaults` for ordinary test-source plumbing;
- component-specific `build-depends` remain explicit;
- `tested-with` matches the actual GHC CI matrix: 9.10.3, 9.12.4, 9.14.1;
- historical `h-kernel-editor-actual-writer-test` warning drift was normalized only after confirming it builds cleanly with the ordinary incomplete-pattern policy;
- no `base` bound change, formatter migration, linter migration, or dependency architecture change was mixed in.

### A2 Editor CLI root admission

Repeated Account / Budget Movement / Issue target-path root derivation was replaced with one adapter-local total helper:

```haskell
resolveHouseholdRoot
  :: FilePath
  -> Either HouseholdRootError HouseholdRoot
```

The helper normalizes an empty `takeDirectory` result to `"."` and delegates to `mkHouseholdRoot`. Each CLI command handles `Left` through the ordinary `die` failure path.

Final review confirmed:

- no replacement `error` / `fromJust` / `fromRight` escape;
- Account, Budget, and Issue preparation/publication remain explicit and distinct;
- canonical-versus-compatibility target behavior remains unchanged.

### A3 Exact neutral test support

Final `Test.Support` API:

```haskell
assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertTrue  :: String -> Bool -> IO ()
mustRight   :: Show error => Either error value -> value
mustJust    :: Maybe value -> value
```

Strict re-measurement against the original base established:

- `mustRight`: 39 occurrences, 34 exact shared, 5 kept/restored local;
- `mustJust`: 7 occurrences, 2 exact shared, 5 kept/restored local;
- `assertEqual`: 38 occurrences, 28 exact shared, 10 kept local;
- `assertTrue`: 2 occurrences, 2 exact shared.

Examples deliberately kept local include domain/setup-specific `mustRight` diagnostics, two-argument `mustJust`, `mustJust` variants with different error text, custom `failTest` assertions, and assertion output using `actual:` rather than the shared `but got:` format.

The accepted rule from this batch is stronger than ordinary DRY:

```text
same broad purpose is not enough
same type is not enough
same success behavior is not enough

share only when behavior + diagnostics + failure path + semantic role agree
```

Do not parameterize shared helpers merely to absorb meaningful local variants.

## Review history

### First review

Rejected the first CLI helper because it moved the old partial escape into a new `error "empty household root path"` branch while claiming totality.

Correction required an explicit total result and ordinary CLI failure handling.

### Second review

Accepted CLI totalization, then rejected overly broad test-helper consolidation after discovering non-exact diagnostics had been normalized into the shared helper.

Concrete evidence included `BalanceLawSpec.mustRight` and `AccountJournalSpec.mustJust`.

### Third review

Actual final head `df80e819...` was re-read independently.

Confirmed:

- correction commit touched tests only, so accepted Cabal/CLI work did not move;
- differing helper variants were restored local;
- shared helper diagnostics now match the admitted exact variants;
- PR body reflects the corrected classification;
- no overlap with open cleanup PR #201 or #202 affected Batch A production paths.

PR CI run #659 succeeded on GHC 9.10.3, 9.12.4, and 9.14.1. The 9.10.3 job also passed repository ownership audit and complete report-contract verification, which are intentionally conditional on 9.10.3 in the workflow.

Reviewer accepted #206 and squash-merged it to `main` as `fb5c3409677710b007230e9c15516dbbdacf1ccc`.

Post-merge main CI run #660 started automatically and was still in progress when this ledger entry was written.

# Batch B: TUI delivery ownership

Status: **NEXT COHERENT BATCH AFTER MAIN REQUALIFICATION**

## Goal

Reduce the amount of section-local interaction grammar known by `editor-tui-app/Main.hs` without inventing a navigation framework and without changing current keyboard/mouse behavior.

## Candidate scope

- characterize current `handleWorkspaceEvent` behavior before moving code;
- keep genuinely global application behavior in `Main`: quit, top-level section switching, and true application-level transitions;
- move/delegate section-local Actual / Plan / Budget / Accounts / Issues / Reports key and mouse handling toward the concrete section owners already present;
- preserve workspace reload/snapshot semantics and user-visible interaction;
- treat `PreviewResult`, `labelField`, list/mouse mechanics, and manual lenses as secondary observations only after routing ownership becomes clearer;
- share tiny presentation helpers only when they have the same owner and reason to change.

## Explicit non-goals

- no generic navigation/event framework;
- no generic Form DSL;
- no module splitting by file size or symmetry;
- no Household.Application pipeline refactor;
- no ActualWriter rename/split;
- no Account-in-Actual compatibility retirement;
- no source-format or private Household change;
- no UX redesign hidden inside an ownership refactor;
- no change to Multi Actual posting-count interaction unless separately justified as UX.

## Qualification expectation

At minimum preserve and run:

```bash
cabal build all
cabal test all
cabal run exe:repository-audit
./report-build
./report-verify --fixture
./report-verify --corpus
```

Add targeted TUI interaction/contract evidence sufficient to prove keyboard and mouse routes did not drift.

# Later Batch C: canonical observation and publication ownership

Only after Batch B review:

- make `HKernel.Household.Application` load orchestration more linear while preserving sealed `HouseholdWriteSnapshot` semantics;
- separately re-audit generic safe publication versus Actual/Plan/Budget source admission currently living under `HKernel.Editor.ActualWriter`;
- keep Account-in-Actual compatibility as an explicit product/source-contract decision rather than incidental cleanup.
