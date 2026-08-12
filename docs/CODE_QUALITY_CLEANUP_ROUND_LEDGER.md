# Code Quality Cleanup Round Ledger

Status: ACTIVE WORK LEDGER
Started: 2026-08-11
Original audit basis: `ce225f195546c19dc0bc2b7532c168359d774f53`
Current implementation baseline: `a0c08501b956d589d57d2c71264922ea606f0bc0`
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
  -> merged-main requalification
  -> next observation
```

Implementation reports are evidence, not source of truth. Every implementation and review starts by rechecking actual `main`, open PRs, changed files, and CI.

## Permanent cleanup rules

- Do not optimize for the smallest PR. Prefer one coherent batch with a clear owner.
- Sharing is not a goal by itself.
- `same shape + same semantic owner + same reason to change` is only a sharing candidate.
- Observable diagnostics, error precedence, and failure mechanisms count as behavior.
- Prefer deletion or an existing owner over new generic `Common`, `Utils`, `Framework`, `Shared`, Form, navigation, repository, session, or effect infrastructure.
- Do not split modules by size or symmetry alone.
- Do not adopt formatter/linter/dead-code/test-framework tooling as repository law without separate evidence.
- Do not modernize syntax merely because GHC2024 permits it.
- Preserve exact arithmetic, Commodity separation, identity, provenance, source ownership, writer authority, include-graph meaning, fail-closed admission, stale-write rejection, post-admission/recovery, multi-posting ordering, and current-policy versus historical-evidence separation.
- Existing CLI/TUI behavior remains stable unless a separate UX change explicitly authorizes a behavior change.
- Safe publication capability and canonical writer authority are different concepts.

# Batch A: mechanical repository plumbing

Status: **ACCEPTED / MERGED / MAIN REQUALIFIED**

Implementation PR: #206 `cleanup: reduce repository plumbing`
Original base: `ce225f195546c19dc0bc2b7532c168359d774f53`
Final reviewed head: `df80e81917cd64fd5d09f5154205a6d4084c667e`
Squash merge: `fb5c3409677710b007230e9c15516dbbdacf1ccc`

Accepted result:

- conservative Cabal `common-defaults` / `test-defaults`, with component dependencies still explicit;
- `tested-with` aligned to the real CI matrix without changing `base` bounds;
- Editor CLI target path -> Household root routing totalized through `Either HouseholdRootError HouseholdRoot`;
- exact-only neutral `Test.Support` sharing, while meaningful local diagnostic/signature/failure variants remain local.

Batch A cleanup law:

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
Squash merge: `31d427b2ec98a96d704206523b46ab5b2d292fbf`
Final stats: 6 files, +331/-208.

Accepted ownership result:

- `Main` remains application shell and global routing owner;
- Actual / Plan / Budget / Accounts / Issues / Reports own section-local Workspace interaction grammar;
- Maintenance keeps Budget / Accounts / Issues action types concrete instead of forcing one generic router;
- Settings remains shell-owned because symmetry alone does not justify a module;
- AppContext list lenses live with `Model`, their natural owner;
- keyboard/mouse precedence and current interaction semantics remain stable;
- no generic navigation/Form/effect framework was introduced.

PR CI #663 and post-merge main CI #664 passed all supported GHC versions; 9.10.3 also passed repository ownership audit and complete report contracts.

# Batch C: canonical observation and safe publication ownership

Batch C was intentionally split because the two findings had different risk classes:

```text
C1 Household.Application
  -> correct owner, hand-threaded orchestration

C2 historical ActualWriter name
  -> coherent cross-domain publication owner, stale name
```

Do not recombine them merely because coordinated publication connects the domains.

# Batch C1: Household application orchestration

Status: **ACCEPTED / MERGED / MAIN REQUALIFIED**

Implementation PR: #208 `cleanup(household): linearize canonical application assembly`
Base: `31d427b2ec98a96d704206523b46ab5b2d292fbf`
Initial reviewed head: `74022c11bb8088cad466405c7b4eb30e1b3a87c4`
Final reviewed head: `460842561a4c931b43454249daf332dddc10c72f`
Squash merge: `e9f088b25f8eb2b366d69dddfe8af3f0d19c7de8`
Final stats: 3 files, +290/-241.

Accepted result:

- `HKernel.Household.Application` remains the canonical composition owner;
- `HouseholdWriteSnapshot` remains the sealed same-observation boundary;
- nested callback orchestration was replaced by one local `ExceptT (NonEmpty HouseholdLoadError) IO` pipeline;
- source-specific Accounts / Actual / Plan / Budget / TOML / Issues admission remains explicit;
- filesystem include-graph resolution and pure in-memory source resolution remain intentionally different owners;
- only genuine post-admission Household semantics are shared: registry agreement, Household policy/account-policy validation, Daily Target / final `HouseholdState` assembly;
- filesystem and pure direct-canonical paths now have a focused `HouseholdState` parity characterization.

## C1 review correction

The first implementation moved Household policy/account-policy validation after Report and Issues admission. That changed observable first-failure precedence and was rejected.

The accepted head restores:

```text
budget.toml
-> household.toml
-> Household policy/account-policy validation
-> report.toml
-> issues.tsv
-> Daily Target assembly
-> HouseholdState
```

A focused characterization verifies Household policy failure still wins when Report syntax is invalid at the same time.

Cleanup law added:

> Failure precedence is observable behavior. Moving validation across another admission boundary is not merely rearranging code.

PR CI #668 passed all supported GHC versions. Post-merge main CI #669 initially hit a stale Hackage index-state during GHC 9.10.3 dependency resolution; rerunning that job without any code/dependency change passed Build, Test, repository ownership audit, and complete report contracts. No CI workaround or dependency-bound change was introduced.

# Batch C2: source publication owner

Status: **ACCEPTED / MERGED / MAIN REQUALIFIED**

Implementation PR: #209 `cleanup(editor): rename source publication owner`
Base: `e9f088b25f8eb2b366d69dddfe8af3f0d19c7de8`
Reviewed head: `39e4bdcdb15969989a192c9acb25827d5a067fcb`
Squash merge: `a0c08501b956d589d57d2c71264922ea606f0bc0`
Final stats: 15 files, +18/-18, one implementation commit.

## Accepted owner correction

```text
HKernel.Editor.ActualWriter
  -> HKernel.Editor.SourcePublication

editor-src/HKernel/Editor/ActualWriter.hs
  -> editor-src/HKernel/Editor/SourcePublication.hs

EditorActualWriterSpec
  -> EditorSourcePublicationSpec

h-kernel-editor-actual-writer-test
  -> h-kernel-editor-source-publication-test
```

The historical `ActualWriter` name had become narrower than the module's real responsibility. The owner already covered source-neutral publication coordinates and laws:

- `ExpectedSource` / `CandidateSource`;
- `WriteIntent` / `WriteError`;
- `WriterFileSystem` / default filesystem;
- text/path admission publication;
- stale detection;
- unique sibling staging;
- pre-rename stale fence;
- atomic publication;
- post-publication candidate verification;
- guarded rollback;
- final candidate re-check.

Actual / Plan / Budget named admission/publication adapters remain in the same module because they are concrete admission choices around that coherent publication law. Their coexistence was not evidence for a split.

Independent diff review confirmed:

- 15 changed files exactly matched the observed repository reference inventory;
- the source module and test owner were GitHub rename-only changes;
- the production module changed only its declaration and one owner-description comment;
- base/head export lists are identical except for module name;
- no public function/type name or signature changed;
- stale checks, staging, rollback, admission, final verification, diagnostics, source semantics, writer authority, Household semantics, and TUI/CLI behavior did not change;
- the old module/test paths are absent from the accepted head;
- no compatibility re-export was added because repository inspection found no release, tag, or concrete external consumer contract requiring the stale owner name.

The central distinction remains:

```text
safe publication capability
!=
canonical writer authority
```

Renaming the code owner does not transfer Plan / Budget / Issue canonical writer authority.

## C2 CI observation

The initial PR GHC 9.14.1 job failed before compilation after `cabal update` selected Hackage index-state `2025-09-28T15:38:05Z`, where the solver could not satisfy `microlens-th` against GHC 9.14's installed `template-haskell-2.24`.

The failed job was rerun without code or dependency changes. The rerun passed Build and Test. PR qualification therefore passed GHC 9.10.3 / 9.12.4 / 9.14.1; 9.10.3 also passed repository ownership audit and complete report contracts.

Post-merge main CI #674 on `a0c08501b956d589d57d2c71264922ea606f0bc0` passed all three supported GHC versions. The 9.10.3 qualification job also passed repository ownership audit and complete report contracts.

C2 cleanup law:

> When behavior and responsibility are already coherent but the historical module name has drifted, correct the owner name before inventing new module boundaries.

# Next: repository-wide re-observation

Do not automatically turn another visible smell into Batch D.

Re-observe the merged repository from `a0c08501b956d589d57d2c71264922ea606f0bc0` and compare remaining findings against the original audit. In particular:

- distinguish debt already removed by B / C1 / C2 from still-live debt;
- do not split large cohesive modules merely because they are large;
- keep `ActualAccountAppend` compatibility paths unless actual current call sites prove retirement is safe;
- treat existing Draft observations such as TUI multi-posting duplicate state as evidence to examine, not as an implementation mandate;
- avoid spending a coherent batch on tiny unrelated import/warning edits unless they combine into a real owner-level cleanup;
- prefer one next batch only if a concrete owner, behavior boundary, and reason to change are visible after re-observation.

Qualification baseline remains:

```bash
cabal build all
cabal test all
cabal run exe:repository-audit
./report-build
./report-verify --fixture
./report-verify --corpus
```
