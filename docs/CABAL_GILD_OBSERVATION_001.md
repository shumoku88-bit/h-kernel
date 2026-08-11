# cabal-gild Observation 001

Date: 2026-08-11
Status: OBSERVATION ONLY
Repository main basis: `b5c129ca199db23f0a84a0c7e011a43f1f903a71`
Tool: cabal-gild 1.8.4.1

## Question

Can cabal-gild reduce future `.cabal` maintenance churn while keeping h-kernel's component structure and explicit public/teaching surface easy to read?

This is the third Haskell-tool experiment described by `DEVELOPMENT_TOOLING_EVALUATION.md`.

The experiment measures the formatter's source-shape effect before deciding whether h-kernel should adopt that shape.

## Trial design

The experiment used the official Linux x64 release binary for cabal-gild 1.8.4.1 and verified its published SHA-256 digest before execution.

Only `h-kernel.cabal` was observed.

No `-- cabal-gild:` pragmas were present, and none were added. In particular, the experiment did not use automatic module discovery. The explicit Cabal `exposed-modules` declarations therefore remained the source of the public module list.

The temporary hosted workflow performed:

1. `cabal-gild --mode=check h-kernel.cabal` before formatting;
2. one formatting pass;
3. `--mode=check` after formatting;
4. a second formatting pass followed by a byte comparison;
5. an exact unified diff between the original and first formatted result.

The formatted Cabal file was not committed.

## Result

| Observation | Result |
|---|---:|
| Original lines | 792 |
| Formatted lines | 1041 |
| Net line change | +249 |
| Unified diff hunks | 1 |
| Added diff lines | 923 |
| Removed diff lines | 674 |
| Check before formatting | not formatted |
| Check after formatting | formatted |
| Second formatting pass | byte-identical |

The one observed input was therefore deterministic under a repeated second pass, but the initial migration would rewrite almost the whole package description.

## Source-shape changes

The result was regular rather than random. cabal-gild consistently changed the file toward its own canonical presentation.

Observed changes included:

- removing vertically aligned field values such as `name:               h-kernel` in favor of `name: h-kernel`;
- expanding multi-value fields into one item per line;
- using trailing commas for dependency/module lists where applicable;
- inserting blank lines between logical fields and lists;
- formatting `ghc-options` vertically when several options are present;
- tightening version-range spacing, for example `>= 4.14 && < 5` to `>=4.14 && <5`;
- sorting or otherwise deterministically reordering module and dependency entries;
- adding a final newline.

The important point is that adoption would not be only a whitespace decision. It would also transfer ownership of list ordering to the formatter.

## Public and teaching surface

The experiment did **not** auto-discover `exposed-modules` and did not make the public API implicit.

That is positive for h-kernel: the package description would continue to enumerate its public/teaching modules explicitly.

However, the formatter reorders those explicit module lists. Examples observed in this run include:

- `HKernel.Plan.Completion` moving relative to `HKernel.Plan.Journal`;
- `HKernel.Editor.ActualAccountAppend` moving before `HKernel.Editor.ActualAppend`.

Those changes are harmless if Cabal lists are treated purely as sets. They matter if h-kernel wants the package description itself to teach a deliberate domain or conceptual order.

Because cabal-gild intentionally has no normal formatting configuration surface, h-kernel should not assume it can adopt the formatter while retaining arbitrary hand-selected list ordering.

## Diff quality tradeoff

There are two distinct kinds of churn here.

### First migration

The first migration is very large:

- 792 lines become 1041;
- 923 additions and 674 removals appear in one unified hunk.

That would be poor review material if mixed with a feature, dependency change, component move, or public-API change.

Any future adoption must therefore be a dedicated formatting-only change.

### Subsequent edits

After migration, several properties could improve future diffs:

- one dependency/module per line;
- deterministic ordering;
- no manual column alignment to repair;
- stable trailing-comma style;
- byte-identical repeated formatting in this trial.

This is plausible future value, but one trial cannot establish how much real h-kernel review churn it would save over time.

## Operational cost

Operationally, cabal-gild was much lighter than the preceding Weeder experiment.

The official prebuilt binary required no GHC installation and no source build. On the single hosted run, downloading, verifying and unpacking the binary completed in well under a second, and the check/format/idempotence/diff sequence also completed in well under a second before log printing finished.

These are hosted-run observations, not a benchmark.

The important conclusion is narrower: execution cost is not currently the main adoption concern. Source shape and teaching/review quality are.

## Semantic verification boundary

The cabal-gild project states that formatted output should be semantically equivalent to its input, and the formatter successfully parsed and checked its own formatted result in this trial.

However, this experiment did **not** run h-kernel's full build/test matrix against the temporary formatted `h-kernel.cabal`.

Therefore this record does not claim independently established h-kernel build equivalence for the formatted file.

If h-kernel later chooses to adopt cabal-gild, the actual formatting-only change should run the normal full repository CI before merge.

## Decision

**Keep observing. Do not adopt cabal-gild as repository law or a mandatory CI gate yet.**

Reason:

1. The tool was cheap to obtain and execute through its official prebuilt binary.
2. Repeated formatting was byte-identical in the observed input.
3. Its one-item-per-line and deterministic presentation could improve later diffs.
4. The first migration would be a near-whole-file rewrite and must not be mixed with semantic work.
5. The formatter also owns list ordering, which is a real teaching/source-shape choice for h-kernel rather than mere whitespace.
6. No automatic module discovery was needed or desired; h-kernel should keep its public teaching API explicit.
7. The experiment did not independently qualify the formatted file through h-kernel's full CI because no adoption was being proposed.

## Current operating rule

Until the source-shape question is deliberately decided:

- do not make cabal-gild a required tool;
- do not add `--mode=check` to CI;
- do not add discovery pragmas for public modules;
- do not mix a formatter migration with component, dependency, or public-API changes;
- if adoption is reconsidered, use a dedicated formatting-only PR and run the normal full CI;
- judge the resulting Cabal file as a teaching surface, not only by formatter consistency.

No production dependency, permanent configuration, mandatory CI step, or formatted `h-kernel.cabal` is retained by this experiment.

## Next distinct experiment

Per the tooling ledger, the next low-dependency direction is GHC's built-in runtime observation.

That experiment should not run a profiler merely because it exists. It should begin from a concrete h-kernel question, then choose the smallest GHC/RTS facility that can answer it.
