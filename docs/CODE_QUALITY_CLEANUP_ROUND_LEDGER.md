# Code Quality Cleanup Round Ledger

Status: ACTIVE WORK LEDGER
Started: 2026-08-11
Original audit basis: `ce225f195546c19dc0bc2b7532c168359d774f53`
Current implementation baseline: `fb5c3409677710b007230e9c15516dbbdacf1ccc`
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
Final actual PR head: `df80e81917cd64fd5d09f5154205a6d4084c667e`
Squash merge commit: `fb5c3409677710b007230e9c15516dbbdacf1ccc`
Final GitHub PR stats: 39 changed files, +201/-534.

The terminal report contained a small final-head typo and stale aggregate diff statistics. Review used GitHub's actual head and PR metadata.

## Accepted result

### Cabal

- `common-defaults` owns shared GHC2024 / warning policy.
- `test-defaults` owns ordinary test-source plumbing.
- component-specific `build-depends` remain explicit.
- `tested-with` matches CI: GHC 9.10.3 / 9.12.4 / 9.14.1.
- the historical actual-writer-test warning difference was normalized only after verification.
- no `base` bound change, formatter/linter migration, or dependency architecture change entered the batch.

### Editor CLI

Account / Budget Movement / Issue target-path root derivation now shares one adapter-local total helper:

```haskell
resolveHouseholdRoot
  :: FilePath
  -> Either HouseholdRootError HouseholdRoot
```

Each command handles failure through the ordinary CLI `die` path. No replacement `error`, `fromJust`, `fromRight`, or impossible-pattern escape remains in that path. Domain preparation/publication and canonical-versus-compatibility behavior remain explicit.

### Exact neutral test support

Final shared API:

```haskell
assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertTrue  :: String -> Bool -> IO ()
mustRight   :: Show error => Either error value -> value
mustJust    :: Maybe value -> value
```

Final classification against the original base:

- `mustRight`: 39 occurrences, 34 exact shared, 5 local;
- `mustJust`: 7 occurrences, 2 exact shared, 5 local;
- `assertEqual`: 38 occurrences, 28 exact shared, 10 local;
- `assertTrue`: 2 occurrences, 2 exact shared.

Differing domain/setup diagnostics, different signatures, custom `failTest` paths, and different output formats remain local.

Batch A established this stronger-than-DRY rule:

```text
same type is not enough
same success path is not enough
same broad purpose is not enough

share only when behavior + diagnostics + failure path + semantic role agree
```

Do not parameterize a shared helper merely to absorb meaningful local variants.

## Review history

1. First review rejected a supposedly total CLI helper because it still ended in a production `error`.
2. Second review accepted CLI totalization but rejected test sharing that had normalized non-exact diagnostics.
3. Third review confirmed exact variants only, unchanged Cabal/CLI work, and no material open-PR overlap; #206 was accepted and squash-merged.

PR CI #659 passed all three supported GHC versions. GHC 9.10.3 also passed repository ownership audit and complete report-contract verification, which are intentionally conditional on that matrix member.

Post-merge main CI #660 also passed all three GHC versions; GHC 9.10.3 again passed ownership audit and complete report contracts.

# Batch B: TUI delivery ownership

Status: **READY FOR IMPLEMENTATION**

Current actual baseline: `main` at `fb5c3409677710b007230e9c15516dbbdacf1ccc` with main CI #660 successful.

## Fresh merged-main observation

`editor-tui-app/Main.hs` still owns one large `handleWorkspaceEvent` that combines:

- global quit and section switching;
- Reports scrolling, selection, and picker entry;
- Budget / Accounts / Settings viewport scrolling;
- Actual workspace account/transaction mouse selection, list movement, focus, Daily/Income/Multi entry, and Reverse entry;
- Plan list movement, add/edit/complete, and Budget-sync picker entry;
- Issue list movement, add, and close entry.

At the same time, existing concrete modules already own the corresponding Workspace rendering and flow/start operations:

- `HKernel.Editor.TUI.Actual`
- `HKernel.Editor.TUI.Plan`
- `HKernel.Editor.TUI.Maintenance`
- `HKernel.Editor.TUI.Report`

This is an ownership cleanup opportunity, not a request for a new navigation architecture.

## Goal

Reduce the amount of section-local Workspace interaction grammar known by `Main` while preserving current keyboard/mouse behavior exactly.

## Candidate scope

- characterize current `handleWorkspaceEvent` routes before moving them;
- keep genuinely global application behavior in `Main`: quit, top-level section switching, `UIState` dispatch, and true cross-section/application transitions;
- move or delegate Actual Workspace keyboard/mouse grammar toward `Actual`;
- move or delegate Plan Workspace keyboard/mouse grammar toward `Plan`;
- move or delegate Budget / Accounts / Issues Workspace grammar toward `Maintenance`;
- move or delegate Reports Workspace grammar toward `Report`;
- keep Settings local to `Main` unless a real owner emerges; do not create a Settings module for symmetry;
- preserve list selection, focus, viewport scrolling, picker entry, reload/snapshot behavior, and existing flow transitions;
- only after routing ownership is clearer, re-evaluate tiny duplicates such as `PreviewResult`, `labelField`, list/mouse mechanics, or manual lenses. They are not mandatory Batch B deliverables.

## Explicit non-goals

- no generic navigation/event framework;
- no generic Workspace router abstraction merely to reduce case count;
- no generic Form DSL;
- no module splitting by file size or symmetry;
- no Household.Application pipeline refactor;
- no ActualWriter rename/split;
- no Account-in-Actual compatibility retirement;
- no source-format or private Household change;
- no UX redesign hidden inside the ownership refactor;
- no Multi Actual posting-count interaction change unless separately justified as UX;
- no changes to accounting/report semantics.

## Qualification expectation

At minimum:

```bash
cabal build all
cabal test all
cabal run exe:repository-audit
./report-build
./report-verify --fixture
./report-verify --corpus
```

Add focused TUI evidence that is proportionate to the implementation. Prefer tests or characterization at the concrete section boundary if the refactor naturally creates a testable seam; do not invent a routing framework merely to make testing possible.

# Later Batch C

Only after Batch B review:

- re-observe and possibly linearize `HKernel.Household.Application` load orchestration while preserving sealed `HouseholdWriteSnapshot` semantics;
- separately re-audit generic safe publication versus Actual/Plan/Budget source admission currently under `HKernel.Editor.ActualWriter`;
- keep Account-in-Actual compatibility as an explicit product/source-contract decision rather than incidental cleanup.
