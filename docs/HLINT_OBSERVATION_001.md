# HLint Observation 001

Date: 2026-08-11
Status: OBSERVATION ONLY
Repository basis: `b5c129ca199db23f0a84a0c7e011a43f1f903a71`
Tool: HLint 3.10

## Question

Can HLint add useful simplification or teaching evidence to h-kernel without turning stylistic preference into repository law or weakening domain/source boundaries?

This is the first experiment described by `DEVELOPMENT_TOOLING_EVALUATION.md`.

No HLint suggestion in this observation is deletion or edit authority. The purpose is to classify signal before deciding whether the tool pays enough rent to keep using.

## Trial shape

The experiment ran once on a temporary GitHub Actions branch-only workflow.

- HLint 3.10 official x86_64 Linux release archive was pinned explicitly.
- The downloaded archive was SHA-256 verified before execution.
- The run used a GitHub-hosted Ubuntu 24.04 runner.
- Production/application Haskell was observed; `tests/`, `tools/`, `dist-newstyle/`, and `.git/` were excluded.
- 78 Haskell files were observed.
- HLint's non-zero result was treated as observation data, not a failing quality gate.
- The temporary workflow was removed after the run. No HLint dependency, configuration, or permanent CI step remains from the experiment.

The hosted run is useful for signal collection, not a local performance baseline.

## Raw result summary

HLint reported 65 findings:

- Warning: 35
- Suggestion: 30

| Hint | Count |
|---|---:|
| Use newtype instead of data | 14 |
| Unused LANGUAGE pragma | 7 |
| Eta reduce | 7 |
| Use fromMaybe | 6 |
| Redundant bracket | 5 |
| Avoid lambda | 5 |
| Use catMaybes | 3 |
| Use isNothing | 3 |
| Use isDigit | 3 |
| Use void | 2 |
| Use isJust | 2 |
| Replace case with maybe | 2 |
| Use mapMaybe | 1 |
| Use join | 1 |
| Use fromLeft | 1 |
| Use min | 1 |
| Use record patterns | 1 |
| Move map inside list comprehension | 1 |

The observation step itself took roughly 20 seconds on the hosted runner, after a roughly 14 MiB HLint archive download. This is operational evidence for this one hosted run only.

## Classification

### Useful simplification candidates

The strongest low-ceremony signals are small, explicit transformations whose semantics remain visible:

- 7 apparently unused `OverloadedStrings` pragmas;
- `catMaybes (map f xs)` -> `mapMaybe f xs`;
- `mapMaybe id` -> `catMaybes`;
- repeated `maybe default id` -> `fromMaybe default`;
- `fmap (const ())` -> `void`;
- direct `Maybe` presence tests -> `isJust` / `isNothing` where the predicate is the actual meaning;
- one direct `if start <= day then start else day` -> `min start day`;
- `ParsedTransaction _ _ _ _ _` -> `ParsedTransaction {}` when only constructor identity matters.

These are candidates, not an edit batch. Each should still be checked in its owner because a shorter spelling is useful only when it preserves or improves the domain reading.

### Teaching / design candidates: `newtype`

HLint proposed `newtype` for 14 single-constructor/single-field declarations, including several error evidence types and raw configuration wrappers.

This is genuinely relevant to h-kernel because `newtype` is part of the repository's Haskell teaching vocabulary. It is not, however, a mechanical rewrite rule.

HLint itself notes that the change decreases laziness. More importantly, the repository must decide whether the declaration represents:

- a domain distinction whose one-field representation is intentionally opaque;
- an error ADT expected to gain cases later;
- raw-source admission evidence;
- adapter-local input state;
- or simply a wrapper that is naturally a `newtype`.

The useful observation is therefore not "14 data declarations are wrong". It is "HLint found 14 places worth an owner-by-owner `data` versus `newtype` teaching review".

### Neutral or low-priority style signal

Several categories are mostly style or local readability choices:

- 7 eta reductions;
- 5 lambda-to-composition suggestions in TUI adapter wiring;
- 5 redundant-parenthesis suggestions in Brick layout expressions;
- 2 `case` -> `maybe` suggestions;
- one `>>= id` -> `join` suggestion;
- one `either id (const [])` -> `fromLeft []` suggestion;
- one list-comprehension/map reshaping suggestion.

Some are harmless and some may be pleasant, but they do not by themselves justify a repository-wide style policy.

The existing Haskell-native policy explicitly allows either point-free or explicit-argument style according to which form makes the data flow and domain relation clearer. HLint therefore must not turn eta reduction or function composition into a default goal.

### Semantically worse suggestions: `isDigit`

The three `Use isDigit` hints are a concrete counterexample to treating HLint as law.

#### Plan ID slugification

Both Plan Add/Edit and Plan Complete & Advance intentionally classify ASCII letters with `isAsciiUpper` / `isAsciiLower` and accept digits only through the explicit range `'0' <= c && c <= '9'`.

Replacing only that digit check with `Data.Char.isDigit` would widen the accepted character class to Unicode digits while the surrounding grammar remains deliberately ASCII-shaped.

That is not a readability-only rewrite. It changes the lexical contract.

#### ANSI SGR parsing

`HKernel.Editor.TUI.ReportStyle` accepts SGR parameter characters as `';'` or ASCII digits `0` through `9`.

Replacing the explicit ASCII range with `isDigit` would accept Unicode digits in a terminal-control grammar whose numeric syntax is ASCII.

Again, the shorter spelling would broaden the parser boundary.

These three findings are classified as **semantically worse for the current owners**.

### False positives / not applicable

No finding is labelled a definite false positive merely because it is unwanted. HLint is correctly recognizing source patterns in most cases; the important distinction is whether its proposed transformation matches h-kernel's semantics and teaching goals.

The `isDigit` cases are better described as valid syntactic pattern matches with semantically inappropriate replacements.

## What HLint did and did not reveal

HLint produced useful local simplification and teaching prompts. It did not reveal a correctness defect, an ownership violation, a writer-safety failure, or a new accounting-law problem in this run.

That matters for tool placement:

- compiler/tests/laws remain the primary correctness boundary;
- HLint is useful as an occasional source-reading assistant;
- HLint output requires semantic review before edits;
- HLint should not currently be a mandatory CI gate.

## Decision

**Keep observing. Do not adopt as repository law or CI gate yet.**

Reason:

1. The run produced real useful signal, especially unused pragmas, small `Maybe`/Functor simplifications, and `data` versus `newtype` teaching candidates.
2. A substantial portion is style-level noise or context-dependent shortening.
3. Three `isDigit` suggestions would weaken intentionally ASCII lexical boundaries if applied mechanically.
4. The repository already has stronger correctness evidence from GHC, tests, ownership audits, and domain contracts.
5. The experiment required no persistent dependency or CI configuration, so periodic observation remains cheap to reconsider.

## Possible follow-up slices

Do not mix these into this observation PR.

A later behavior-preserving cleanup may review the seven unused pragmas and a small set of obvious named combinator substitutions. A separate teaching-oriented review may inspect the 14 `data` / `newtype` cases by owner rather than mass-converting them.

Per the tooling ledger, the next distinct experiment is Weeder as a subtraction audit.
