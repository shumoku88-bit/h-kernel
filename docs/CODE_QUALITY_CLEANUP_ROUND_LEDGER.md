# Code Quality Cleanup Round Ledger

Status: ACTIVE WORK LEDGER
Started: 2026-08-11
Audit basis: `main` at `ce225f195546c19dc0bc2b7532c168359d774f53`
Parent observation: `CODE_QUALITY_CLEANUP_ROUND_AUDIT_2026-08-11.md`

## Working loop

```text
current ledger + actual remote
  -> one coherent terminal-AI implementation batch
  -> tests / push / PR
  -> STOP BEFORE MERGE
  -> independent actual-diff / CI review
  -> ledger update
  -> merge decision
  -> next coherent batch
```

Every implementation and every review starts by rechecking actual `main`, open PRs, changed files, and CI. Parallel pushes are possible.

## Batch sizing rule

Do not optimize for the smallest possible PR. Prefer one coherent batch with a few logical commits over one PR per helper/import/stanza/case expression.

Split only when semantic risk, qualification, blocking dependencies, or ownership clarity materially differ.

## Permanent guardrails

- Sharing is not a goal by itself.
- `same shape + same semantic owner + same reason to change` is a sharing candidate.
- Repeated shapes with different owners or diagnostics may correctly remain local.
- Prefer deletion or an existing owner over new generic `Common`, `Utils`, `Framework`, `Shared`, Form, navigation, or effect infrastructure.
- Do not split modules by size alone.
- Do not adopt formatter/linter/dead-code/test-framework tooling as repository law without separate evidence.
- Do not modernize syntax merely because GHC2024 permits it.
- Preserve exact arithmetic, Commodity separation, identity, provenance, source ownership, writer authority, include-graph meaning, fail-closed admission, stale-write rejection, post-admission/recovery, multi-posting ordering, and current-policy versus historical-evidence separation.
- Existing CLI/TUI behavior remains stable unless a separate UX change authorizes behavior change.

## Baseline findings

Strongest cleanup candidates from the fresh audit:

1. Cabal mechanical repetition and support/warning drift.
2. Editor CLI target-path -> Household-root repetition and production partial escape.
3. Neutral test-helper duplication.
4. TUI `Main` knowing too much section-local interaction grammar.
5. Hand-threaded canonical Household load orchestration.
6. Cross-domain safe-publication ownership living under the `ActualWriter` name.

Important counter-findings:

- large `Journal`, `PlanCompleteAdvance`, and `Render` modules are not size-driven split targets;
- Account-in-Actual compatibility is still live, not automatic dead code;
- blanket `!!` removal, lint-driven rewriting, formatter migration, or public-surface shrinking is not authorized.

# Batch A: mechanical repository plumbing

Status: **REVIEW BLOCKED / SECOND CORRECTION REQUESTED**

Implementation PR: #206 `cleanup: reduce repository plumbing`
Base: `ce225f195546c19dc0bc2b7532c168359d774f53`
Current reviewed head: `09804db8464882717e0b582cb13707b719d659fd`

## Authorized scope

### A1 Cabal defaults

- conservative common stanza(s) for genuinely shared compiler/test metadata;
- keep component-specific `build-depends` explicit;
- inspect, do not blindly normalize, the historical `h-kernel-editor-actual-writer-test` warning difference;
- only state compiler/base support that actual CI/package evidence supports.

### A2 Editor CLI root admission

- remove repeated target-path -> directory -> `mkHouseholdRoot` plumbing for Account/Budget Movement/Issue;
- remove production partial escape;
- use one small total adapter-level helper and ordinary/typed CLI failure;
- keep domain preparation/publication explicit and distinct.

### A3 Neutral test plumbing

- re-measure current helper bodies first;
- share only exact neutral helper variants where net simplification is real;
- keep differing signatures/diagnostics local;
- keep domain fixtures/source snippets/scenarios local by default;
- no Hspec/Tasty migration or new test framework.

## Accepted parts after review

### Cabal

Accepted direction:

- `common-defaults` contains shared GHC2024/warning defaults;
- `test-defaults` carries ordinary test-source plumbing;
- component-specific dependency lists remain explicit;
- `tested-with` matches the actual CI GHC matrix;
- no `base` bound change was mixed in;
- no unrelated formatter/linter migration entered the PR.

### Editor CLI

First review found the initial `resolveHouseholdRoot` still ended in a production `error` and rejected the claimed totalization.

The corrected head `09804db...` fixes that blocker:

```haskell
resolveHouseholdRoot
  :: FilePath
  -> Either HouseholdRootError HouseholdRoot
resolveHouseholdRoot targetFile =
  let dir = takeDirectory targetFile
      rootDir = if null dir then "." else dir
  in mkHouseholdRoot rootDir
```

Account, Budget Movement, and Issue commands now handle `Left` through the ordinary CLI `die` path. No `fromJust`, `fromRight`, impossible-pattern assertion, or replacement production `error` was introduced in this path.

**CLI totalization is accepted.**

## Second-review blocker: helper variants were normalized beyond the contract

The first review accepted the general `Test.Support` direction but a deeper pass over the actual commit diff found that some local helpers imported from `Test.Support` were not exact variants.

Concrete evidence:

### `BalanceLawSpec`

The local helper previously failed with:

```haskell
error ("invalid Balance law fixture: " ++ show err)
```

It was replaced by shared `Test.Support.mustRight`, whose failure text is:

```haskell
error ("invalid test fixture: " ++ show err)
```

The observable diagnostic differs.

### `AccountJournalSpec`

The local helper previously had:

```haskell
mustJust Nothing = error "invalid test fixture: missing expected value"
```

The shared helper has:

```haskell
mustJust Nothing = error "invalid test fixture: expected Just"
```

Again, these are not exact variants.

The Batch A rule was deliberately narrower than ordinary DRY cleanup: differing diagnostics/signatures should remain local instead of being normalized merely to increase sharing.

This is not an accounting/runtime correctness failure and the tests may all pass. It is an ownership/cleanup-contract failure: the first cleanup batch must demonstrate that shared mechanics do not erase useful local distinctions.

## Required correction for PR #206

Keep the same PR. Do not create a micro-PR.

1. Re-measure every helper occurrence actually replaced by `Test.Support` against current base `ce225f...`.
2. Share only helpers whose semantics and observable diagnostics are genuinely identical, allowing irrelevant formatting/pattern-spelling differences only when behavior/diagnostics are the same.
3. Restore local variants whose error text, label behavior, failure mechanism, or signature differs.
4. Do **not** add message/config parameters to `Test.Support` merely to absorb variants.
5. Update PR body/counts/net reduction to the corrected actual scope.
6. Re-run targeted test suites plus:

```bash
cabal build all
cabal test all
cabal run exe:repository-audit
./report-build
./report-verify --fixture
./report-verify --corpus
```

7. Push to the existing PR and re-run the GHC 9.10.3 / 9.12.4 / 9.14.1 CI matrix.

## Current merge decision

**DO NOT MERGE #206 YET.**

At second review time:

- actual `main` still remained `ce225f195546c19dc0bc2b7532c168359d774f53`;
- PR #206 remained mergeable and 3 commits ahead of that base;
- open cleanup PRs #201 and #202 had no changed-file overlap with #206's production paths (`#201`: three import-only production files; `#202`: repository-audit Haskell files);
- CI run #657 for head `09804db...` was still in progress;
- CI success cannot override the exact-helper-boundary blocker.

# Later batches

## Batch B: TUI delivery ownership

Candidate scope only after Batch A is accepted/merged:

- reduce `handleWorkspaceEvent` knowledge;
- retain real global keys/application transitions in the shell;
- delegate section-local Actual / Plan / Budget / Accounts / Issues / Reports behavior to concrete owners;
- preserve and characterize keyboard/mouse behavior;
- only after routing is clearer, reassess tiny presentation duplicates such as `PreviewResult` and `labelField`.

No generic navigation framework and no size-based module splitting.

## Batch C: canonical observation and publication ownership

Candidate scope after Batch B review:

- make `HKernel.Household.Application` load orchestration more linear while preserving sealed `HouseholdWriteSnapshot` semantics;
- then re-audit generic safe publication versus Actual/Plan/Budget source admission currently living under `HKernel.Editor.ActualWriter`;
- handle Account-in-Actual compatibility as a separate explicit product/source-contract decision.

# History

## 2026-08-12 / Batch A second independent review

- corrected PR head `09804db8464882717e0b582cb13707b719d659fd` independently re-read;
- CLI totalization blocker is fixed and accepted;
- current `main` independently rechecked and unchanged;
- deeper test-helper review found non-exact diagnostic variants had been collapsed into `Test.Support`;
- concrete examples recorded from `BalanceLawSpec` and `AccountJournalSpec`;
- correction comment added to PR #206;
- merge remains blocked until exact-helper scope is restored and verification/CI rerun.

## 2026-08-11 / Batch A first independent review

- first reviewed head `c143b3184071ba28a6561922032d1ecb594e5bbd`;
- Cabal/test-support direction stayed within Batch A's broad plumbing scope;
- first blocker: new CLI helper still contained `error "empty household root path"` despite claiming totality;
- same-PR correction requested.

## 2026-08-11 / ledger initialization

- cleanup Draft and fresh audit established in Draft PR #205;
- operating model changed from potential micro-slices to reviewer-mediated coherent batches;
- Batch A defined as Cabal defaults + Editor CLI root totalization + exact neutral test plumbing;
- implementation agents stop before merge so review evidence is recorded before the next batch.
