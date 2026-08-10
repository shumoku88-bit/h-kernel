# Development Tooling Evaluation Ledger

> **Status**: ACTIVE OBSERVATION LEDGER
> **Scope**: Haskell development tools, build/test/analysis tools, and AI-assisted development tooling
> **Baseline main**: `028a051b5b85464328129221d7b6099f8273d6d4`
> **Principle**: adopt tools because measured evidence says they improve h-kernel, not because they are fashionable or Haskell-specific.

## Purpose

h-kernel is expected to grow while remaining useful as both a real Household application and a Haskell teaching surface.

Development tooling can help preserve that quality, but every tool also adds cost:

- another dependency or binary to install;
- another configuration surface;
- more CI time;
- more generated noise;
- possible pressure to rewrite clear domain code merely to satisfy a tool;
- possible AI-context waste when command output is unnecessarily large.

This ledger treats tooling itself as something to observe and qualify.

The goal is not to maximize the number of tools. The goal is to keep the smallest set that demonstrably improves one or more of:

- correctness;
- source clarity and teaching value;
- architecture cleanup;
- development feedback time;
- reproducibility;
- performance diagnosis;
- AI context efficiency;
- resource stewardship.

## Adoption rule

A tool moves through these states:

```text
Candidate
  -> Baseline recorded
  -> Trial
  -> Evidence reviewed
  -> Adopt / Keep observing / Reject
```

Do not make a new tool a mandatory CI gate merely because it produced useful output once.

Prefer observation-only use first. Promote it to a local convention or CI gate only when:

1. the signal is repeatedly useful;
2. false positives / irrelevant suggestions are acceptably low;
3. the tool does not distort domain vocabulary or architecture;
4. maintenance cost is understood;
5. the failure mode is appropriate for a required gate.

## Measurement axes

### Quality signal

Record:

- real defects found;
- dead or unreachable code found;
- incomplete/unsafe patterns found;
- redundant code found;
- formatting/config drift prevented;
- useful refactoring/navigation support;
- false positives or suggestions deliberately rejected.

### Simplicity cost

Record:

- repository files/config added;
- runtime dependencies added;
- development-only dependencies added;
- CI steps added;
- developer setup steps added;
- whether the tool introduces a framework or vocabulary into production code.

A tool that improves development should normally not become part of the Household runtime model.

### Feedback cost

Record where practical:

- local cold/warm execution time;
- additional CI time;
- download/install cost;
- whether it can run only on a narrow GHC version;
- whether failures are deterministic and reproducible.

### AI context efficiency

For AI-output filters such as `sqz` or `rtk`, record at least:

- commands observed;
- raw tokens / compressed tokens, where the tool reports them;
- percentage reduction;
- repeated-read/dedup savings;
- commands that bypass compression;
- number of times original output had to be recovered;
- extra commands caused by missing context;
- any wrong conclusion attributable to compressed output.

The useful quantity is not maximum compression. It is **useful information retained per token**.

A compression tool loses if it saves tokens but causes enough rereads, retries, or mistaken edits to erase the gain.

### Resource stewardship

Token volume, command-output volume, repeated executions, CI duration, and unnecessary rebuilds are useful operational resource proxies.

Do **not** convert token counts directly into carbon or energy claims without a defensible energy measurement. Record what h-kernel can actually observe:

```text
less redundant context
less repeated output
fewer unnecessary executions
less avoidable CI/build work
```

Resource stewardship and software quality often point in the same direction: avoid work that carries no new evidence.

### Teaching value

Ask:

- Does the tool make Haskell semantics easier to see?
- Does it reveal a real language/compiler concept?
- Does it encourage clearer domain code?
- Does it instead encourage opaque cleverness or tool-specific ceremony?

h-kernel should remain understandable without knowing every optional development tool.

## Current baseline

The repository already has strong compiler/test evidence without a large tool stack:

- GHC `-Wall`;
- `-Werror=incomplete-patterns`;
- multiple supported GHC versions in CI;
- QuickCheck law/property coverage in selected suites;
- focused executable contract tests;
- repository ownership/audit checks;
- complete report contracts;
- explicit benchmark/observation work rather than an always-on performance framework.

New tools must add evidence beyond this baseline.

## Candidate inventory

| Tool / facility | Intended value | Initial mode | Main risk | Status |
|---|---|---|---|---|
| Haskell Language Server | type/navigation/refactor feedback | local development | editor/setup complexity | Candidate / likely keep |
| HLint | suspicious/redundant Haskell idioms | observation only | stylistic noise / bad suggestions | Candidate |
| Weeder | whole-program dead-code detection | periodic cleanup audit | version/GHC constraints; false roots | Candidate, high interest |
| cabal-gild | deterministic `.cabal` formatting | local/CI trial | large format churn | Candidate |
| Fourmolu | deterministic Haskell formatting | local experiment later | huge historical reformat diff | Deferred |
| hdb / Haskell debugger | step-through IO/TUI debugging | targeted experiment | GHC/version/editor constraints | Candidate |
| GHC `+RTS -s` | allocation/GC/runtime observation | targeted, no new dependency | easy to misread one run | Candidate, low cost |
| GHC eventlog / heap profiling | explain runtime/GC behaviour | targeted performance work | measurement complexity | Candidate |
| GHC Core/STG dumps | teaching + optimization diagnosis | targeted observation | overwhelming compiler output | Candidate |
| Criterion | stable microbenchmarking | only after a kernel is identified | benchmark framework before a question | Deferred |
| cabal-audit | dependency security advisory checks | periodic/CI observation | advisory/tool maintenance | Investigate |
| `cabal outdated` / plan inspection | dependency drift visibility | periodic maintenance | update churn | Investigate |
| `sqz` | AI tool-output compression + cross-call dedup | local Codex experiment | hidden context / dedup recovery | Candidate, high interest |
| `rtk` | deterministic command-aware AI output filtering | local Codex experiment | PATH/shim interception; hidden detail | Candidate, high interest |

## AI tooling: `sqz` and `rtk`

These are development-environment tools, not h-kernel runtime dependencies.

They must not be required to build, test, or understand the repository.

### Why investigate

Long-lived AI coding sessions repeatedly inspect:

- `git status` / `git diff` / `git log`;
- search results;
- compiler and test output;
- the same source files after nearby changes.

Raw output can consume context without adding new evidence. This becomes increasingly relevant as h-kernel grows.

### `sqz` trial hypothesis

Potential strengths to measure:

- command-output compression;
- cross-call dedup of repeated content;
- explicit recovery of original content;
- per-project token statistics.

Primary question:

> Does dedup materially reduce repeated source-reading cost in a long h-kernel session without making source provenance or changed content confusing?

### `rtk` trial hypothesis

Potential strengths to measure:

- deterministic command-aware filters;
- especially large savings for build/test/search output;
- per-command savings statistics.

Primary question:

> Does command-aware filtering remove routine shell noise while preserving the exact identifiers, failures, diffs, and diagnostics needed for safe repository work?

### Trial design

Do not install both transparently at the same time for the first comparison.

Use comparable real h-kernel sessions:

```text
A. ordinary Codex CLI / raw shell output
B. sqz enabled
C. rtk enabled
```

Prefer real maintenance tasks over synthetic giant-output commands.

For each mode capture:

- session/task description;
- number of shell/tool commands where available;
- reported token/input-output savings;
- original-output recoveries;
- retries/repeated commands;
- any missed diagnostic/detail;
- task result (tests/CI/review correctness);
- subjective friction only as a secondary note.

Do not compare different tasks as if their token counts were controlled experiments. Accumulate several ordinary sessions before deciding.

### Safety rule

For source mutation, publication, CI failures, compiler errors, and security-sensitive output, exact evidence wins over compression.

If a compressed summary hides the detail needed to establish correctness, recover the original output rather than reasoning from an incomplete summary.

## Haskell tooling trial order

### Trial 1: HLint as observation, not law

Run against production Haskell source without changing code first.

Record suggestions into buckets:

```text
useful simplification
teaching improvement
neutral style preference
semantically worse suggestion
false positive / not applicable
```

Only recurring useful categories justify configuration or CI adoption.

Do not rewrite named Household/domain operations into clever point-free forms merely because HLint can shorten them.

### Trial 2: Weeder as subtraction audit

This directly matches the architecture cleanup question:

> Which declarations survive in the repository but are unreachable from the real application/test roots?

Before deleting anything:

- verify roots/config;
- distinguish public teaching API from accidental dead code;
- distinguish compatibility surfaces intentionally retained;
- confirm no plugin/reflection/generated use is invisible to the analysis.

A Weeder report is evidence for observation, not deletion authority.

### Trial 3: cabal-gild

First measure its diff against the current hand-maintained Cabal file.

Adopt only if it keeps component/public-surface structure easy to read and does not create noisy churn.

Do not auto-discover/export modules if that makes the teaching/public API less explicit.

### Trial 4: GHC built-in runtime observation

Before adding a performance library, use the compiler/runtime facilities already present:

```text
+RTS -s
heap/eventlog profiling
-ddump-timings
selected Core/STG inspection
```

Use these to answer a concrete question. Do not make compiler dumps routine repository artifacts.

### Later: hdb / Criterion / formatter decisions

Use hdb when a real IO/TUI/state problem benefits from stepping through execution.

Use Criterion only when a repeatable pure/small kernel has been identified and wall-clock observation is too noisy.

Consider Fourmolu only after deciding whether a repository-wide formatting migration is worth the review noise.

## Dependency/library policy

Do not add a Haskell library merely because it is idiomatic or powerful.

In particular, avoid introducing large generic abstraction stacks unless a recurring h-kernel problem has already demonstrated the need.

Examples that require a concrete justification before adoption:

- lens frameworks;
- effect systems;
- generic command/query frameworks;
- generic validation frameworks;
- generic state-machine frameworks;
- benchmark frameworks without an identified benchmark question.

Prefer ordinary ADTs, newtypes, named functions, modules, and existing GHC capabilities while they remain sufficient.

## Experiment record template

Copy this section for each actual trial.

```text
### <tool> experiment N

Date:
Repository main/head:
Tool version:
Environment:
Question:
Baseline:
Trial configuration:
Workload:

Observed:
- quality findings:
- false/noisy findings:
- elapsed/local or CI cost:
- token/output savings (if relevant):
- rereads/retries/recoveries:
- configuration/repository cost:
- teaching/readability effect:

Decision:
- Adopt / Keep observing / Reject / Defer

Reason:
```

## Initial decisions

- **Do not change production dependencies yet.**
- **Do not add a new mandatory CI gate yet.**
- Start with observation-only trials.
- First Haskell candidates: HLint, then Weeder.
- First AI-context candidates: compare sqz and rtk separately in real local Codex work.
- Prefer built-in GHC runtime/profiling evidence before adding Criterion.
- Keep this ledger on `main`; update it when an experiment produces actual evidence.

## Working rule

A development tool must pay rent.

Its rent may be correctness, deletion of dead code, faster feedback, clearer teaching, better diagnosis, or materially smaller AI context. If the benefit cannot be observed, or if the tool adds more ceremony than evidence, remove or defer it.
