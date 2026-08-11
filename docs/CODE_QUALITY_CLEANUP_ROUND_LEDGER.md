# Code Quality Cleanup Round Ledger

Status: ACTIVE WORK LEDGER
Started: 2026-08-11
Audit basis: `main` at `ce225f195546c19dc0bc2b7532c168359d774f53`
Parent observation: `CODE_QUALITY_CLEANUP_ROUND_AUDIT_2026-08-11.md`

## Purpose

This file is the operational ledger for the repository-wide code-quality cleanup round.

The audit documents record evidence and rejected hypotheses. This ledger records what work is actually authorized, what the terminal implementation agent reports, what review finds, and what becomes the next coherent batch.

The ledger is not a substitute for re-reading current remote state. Every implementation batch and every review starts by checking actual `main`, open PRs, changed files, and CI because parallel pushes may occur.

## Working loop

```text
current ledger + current remote
  -> one coherent implementation instruction
  -> terminal AI implements, tests, pushes, opens/updates PR
  -> stop before merge
  -> reviewer re-checks actual remote, diff, tests, CI and semantics
  -> ledger records accepted/rejected findings and new evidence
  -> next coherent implementation instruction
```

The implementation agent does not merge its own cleanup PR. Review happens before merge so the ledger can remain the authority for what was actually learned.

## Batch sizing rule

Do not optimize for the smallest possible PR.

A useful batch normally contains several changes that share one broad reason to change and can be qualified together. It may contain multiple commits inside one PR when that makes review easier.

Prefer:

```text
one coherent repository-plumbing batch
one coherent TUI ownership batch
one coherent canonical-observation batch
```

over:

```text
one PR for one helper
one PR for one import
one PR for one stanza
one PR for one case expression
```

Split a batch only when:

- a change has materially different semantic risk;
- qualification requirements differ enough that review becomes unclear;
- one change blocks another but should not be coupled to it;
- the combined diff obscures ownership rather than clarifying it.

A large diff is not automatically bad, and a small diff is not automatically coherent.

## Permanent guardrails

- Sharing is not a goal by itself.
- Repeated shapes with different semantic owners may correctly remain duplicated.
- Prefer deletion or an existing owner over new `Common`, `Utils`, `Framework`, or `Shared` architecture.
- Do not split modules by size alone.
- Do not adopt a test framework, effect stack, generic navigation system, Form DSL, formatter, linter, or dead-code tool as repository law without independent evidence.
- Do not modernize syntax merely because GHC2024 permits a newer spelling.
- Preserve exact arithmetic, identity, provenance, source ownership, writer authority, include-graph meaning, stale-write rejection, post-admission, recovery, multi-posting ordering, and current policy versus historical evidence.
- Existing CLI/TUI behavior remains stable unless a separate UX change explicitly authorizes behavior change.

## Review checklist for every implementation batch

Reviewer checks:

1. actual remote `main` and implementation PR head have not moved unexpectedly;
2. changed files match the batch purpose;
3. no unrelated refactor or formatting churn entered the diff;
4. shared code has one real owner and one reason to change;
5. no domain fixture or workflow was generalized merely for DRYness;
6. partiality was reduced rather than hidden;
7. component/public API changes are intentional;
8. current CLI/TUI semantics remain characterized where applicable;
9. required build/tests/repository audit pass;
10. new evidence is written here before choosing the next batch.

## Baseline findings

The fresh audit currently classifies the strongest candidates as:

- Cabal mechanical repetition and warning/support-policy drift;
- Editor CLI target-path -> Household-root repetition and production `error "unreachable"`;
- neutral test-helper duplication;
- TUI `Main` knowing section-local interaction grammar;
- hand-threaded canonical Household load orchestration;
- cross-domain safe-publication ownership living under the `ActualWriter` name.

Counter-findings remain important:

- large `Journal`, `PlanCompleteAdvance`, and `Render` modules are not size-driven split targets;
- retained Account-in-Actual compatibility is still live and is not automatic dead code;
- blanket `!!` removal, lint-driven rewriting, formatter migration, or public-surface shrinking is not authorized by this round.

## Batch A: mechanical repository plumbing

Status: READY FOR IMPLEMENTATION

### Goal

Remove a meaningful layer of mechanical repository and adapter plumbing in one pass before touching TUI or canonical Household architecture.

### Included work

1. Cabal defaults
   - introduce conservative `common` stanza(s) for truly shared compiler/test metadata;
   - keep component-specific `build-depends` explicit;
   - investigate the `h-kernel-editor-actual-writer-test` warning difference instead of silently normalizing it;
   - only change `tested-with` / `base` bounds if current compiler/package evidence justifies the exact statement.

2. Editor CLI root admission
   - remove the repeated target-path -> directory -> `mkHouseholdRoot` plumbing used by Account, Budget Movement, and Issue commands;
   - remove production `error "unreachable"` from that path;
   - use one small total adapter-level helper and ordinary/typed CLI failure;
   - keep Account/Budget/Issue preparation and publication explicit and distinct.

3. Neutral test plumbing
   - measure current exact helper bodies first;
   - consolidate only clearly mechanical neutral helpers where the final diff is a net simplification;
   - domain fixtures, source snippets, scenarios, Account/Plan/Journal/Budget meaning stay local by default;
   - do not migrate to Hspec/Tasty or create a test framework.

### Explicit non-goals

- no TUI routing refactor yet;
- no Household.Application refactor yet;
- no `ActualWriter` rename/split yet;
- no Account compatibility retirement;
- no source-format or private Household changes;
- no broad formatting/lint cleanup;
- no unrelated import-only cleanup unless required by the touched code.

### Qualification

At minimum:

```bash
cabal build all
cabal test all
cabal run exe:repository-audit
```

Also run the repository's normal CI matrix after pushing. Run targeted CLI tests during development. If Cabal support bounds or compiler declarations change, verify them against the actual supported GHC matrix rather than inference.

### Delivery shape

Prefer one PR for Batch A, with a few logical commits if useful. Do not split Cabal, CLI root totalization, and exact neutral test-helper cleanup into tiny PRs merely because they can be separated mechanically.

If one subpart proves materially unsafe or produces a worse diff, leave it out and report the evidence rather than forcing the planned shape.

### Review state

Implementation result: pending.
Reviewer result: pending.
Merge decision: pending.

## Later batches

### Batch B: TUI delivery ownership

Candidate scope after Batch A review:

- shrink `handleWorkspaceEvent` knowledge;
- keep true global keys/transitions in shell;
- delegate section-local Actual / Plan / Budget / Accounts / Issues / Reports interaction to concrete owners;
- characterize keyboard/mouse behavior before/while moving it;
- only then reconsider tiny presentation helpers such as `PreviewResult` / `labelField`.

No generic navigation framework.

### Batch C: canonical observation and publication ownership

Candidate scope after Batch B review:

- make `HKernel.Household.Application` load orchestration more linear while preserving the sealed `HouseholdWriteSnapshot` observation;
- then re-audit generic safe publication versus Actual/Plan/Budget admission ownership currently living in `HKernel.Editor.ActualWriter`;
- treat Account-in-Actual compatibility as an explicit product/source-contract decision, not incidental cleanup.

These are higher-risk ownership changes and should not be mixed into Batch A.

## History

### 2026-08-11 / ledger initialization

- repository-wide cleanup Draft and fresh audit created in Draft PR #205;
- fresh audit found domain core generally cohesive and accidental complexity concentrated in adapters/orchestration/test/build plumbing;
- operating model changed from potentially separate micro-slices to reviewer-mediated coherent batches;
- Batch A defined as Cabal defaults + Editor CLI root totalization + exact neutral test plumbing;
- implementation must stop before merge for independent review and ledger update.
