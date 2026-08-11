# Weeder Observation 001

Date: 2026-08-11
Status: OBSERVATION ONLY
Repository main basis: `b5c129ca199db23f0a84a0c7e011a43f1f903a71`
Tool: Weeder 2.10.0

## Question

Can Weeder provide useful subtraction evidence for h-kernel without mistaking public teaching surfaces, test-only contracts, or intentionally retained APIs for dead code?

This is the second Haskell-tool experiment described by `DEVELOPMENT_TOOLING_EVALUATION.md`.

A Weeder finding is reachability evidence under a chosen root model. It is not deletion authority.

## Why root design matters here

h-kernel is both a real Household application and a teaching/public Haskell surface.

An executable-only reachability graph therefore answers a narrower question than the repository actually cares about. A declaration can be absent from today's executable paths while still being intentionally retained because it is:

- exported from a Cabal library as public/teaching API;
- used only by a contract or characterization test;
- part of a compatibility surface;
- or an explicit boundary intended for another delivery adapter.

The experiment therefore used two Weeder root models and then verified the residual findings against source/test use.

### Pass A: executable-strict roots

Roots:

- declarations matching `.*\.main$`;
- generated `Paths_*` declarations;
- type-class roots.

No Cabal `exposed-modules` were retained merely because they were exported.

This pass asks:

> What is unreachable from the currently built executable entry points?

### Pass B: public-surface-retained roots

The same roots were used, but every module listed in Cabal `exposed-modules` was additionally retained as a root module.

65 exposed modules were retained in this pass.

This pass asks a safer repository-level question:

> What remains unreachable even after the declared public/teaching library surface is protected?

The experiment deliberately did not enable Weeder's unused-type mode. The first question was declaration reachability, not the broadest possible lint surface.

## Trial compatibility result

### GHC 9.12.4

The repository successfully built all components with `.hie` information under GHC 9.12.4.

Weeder 2.10.0 then terminated with status 139 (segmentation fault) as analysis began. No reachability result from that run is treated as evidence about h-kernel declarations.

A search of the upstream Weeder issue tracker did not reveal a matching existing issue under the simple `segmentation fault` / `segfault` queries used during this experiment. That does not establish that the problem is unique or new.

### GHC 9.10.3

The same experiment completed successfully under GHC 9.10.3.

Weeder reported its HIE version as 9103 and both reachability passes completed normally with exit status 228, meaning weeds were reported.

The contrast is useful compatibility evidence:

- the h-kernel HIE build itself is not inherently incompatible with Weeder;
- Weeder 2.10.0 worked on this repository with GHC 9.10.3;
- the GHC 9.12.4 segmentation fault makes broad or mandatory adoption premature.

Do not infer a precise root cause from this single comparison.

## Reachability result

Correctly parsed GHC 9.10.3 results:

| Observation | Findings |
|---|---:|
| Executable-strict roots | 183 |
| Public-surface-retained roots | 2 |
| Removed by retaining Cabal exposed modules | 181 |

The 181 strict-only findings were distributed across:

| Source tree | Strict-only findings |
|---|---:|
| `src/` | 89 |
| `household-src/` | 57 |
| `editor-src/` | 22 |
| `spike-src/` | 13 |

This is the strongest result of the experiment.

Those 181 declarations are not a deletion list. They disappear when the repository's declared public library modules are protected. Treating them as dead merely because current executables do not reach them would erase public/teaching surface by construction.

## The two residual findings

After retaining all exposed modules, Weeder reported only:

- `tools/repository-audit/RepositoryAudit.hs:106` — `documentEntry`
- `tools/repository-audit/RepositoryAudit.hs:146` — `lookupDocumentRole`

At first glance these looked like strong dead-code candidates because `RepositoryAudit` is executable-specific rather than a Cabal exposed library module.

Repository-wide source verification changed that conclusion.

`tests/RepositoryAuditSpec.hs` imports `RepositoryAudit` and uses:

- `documentEntry` to construct document-index fixtures in multiple characterizations;
- `lookupDocumentRole` to verify that document-index admission retains the declared role.

The test component was not part of the Weeder root model used for this experiment. Therefore both residual findings are test-only reachable declarations, not verified dead code.

### Verified deletion candidates from this run

**Zero.**

This does not prove that h-kernel contains no dead code. It proves that this root model did not establish any declaration as safely deletable after public surface and exact test references were accounted for.

## What the experiment teaches about Weeder

### Strong signal

Weeder is valuable because it makes root assumptions visible.

The difference between 183 and 2 findings shows that reachability results can change by almost the entire report when the repository's public API is modeled correctly.

The final 2-to-0 verification shows the same thing for tests.

For h-kernel, a future subtraction audit must model at least:

1. real executable roots;
2. Cabal exposed/public teaching modules;
3. test roots or explicit test-only API;
4. any intentionally retained compatibility surface.

Only then should a remaining declaration become a deletion candidate.

### Compatibility cost

The GHC 9.12.4 segmentation fault is significant negative evidence.

A tool used as deletion evidence must itself be reproducible on the compiler/HIE versions the repository supports. Until the 9.12 behavior is understood or a later Weeder version resolves it, h-kernel should not make Weeder a mandatory multi-GHC gate.

### Execution cost

Once compatible `.hie` files existed, both Weeder passes plus result processing completed in roughly 1.2 seconds on the hosted runner.

The cold hosted experiment was much heavier because the environment had to be prepared:

- GHC/cabal setup: roughly 2 minutes in the final GHC 9.10.3 run;
- source-build/install of Weeder and its tool dependencies: roughly 4 minutes;
- h-kernel rebuild with `.hie`: roughly 1 minute 40 seconds;
- Weeder analysis itself: roughly 1.2 seconds.

The total cold hosted run was about 7 minutes 45 seconds.

These numbers are not a local benchmark. They separate an important operational fact: **Weeder's graph analysis is cheap once its prerequisites exist; cold provisioning is the expensive part.**

That makes caching, a preinstalled local tool, or periodic audit more plausible than installing Weeder from source on every pull request.

## Incidental compiler diagnostics

The HIE build exposed additional GHC warnings under 9.10.3, including redundant imports, name shadowing, type defaulting, and partial-list warnings.

They are not Weeder findings and are intentionally not mixed into this observation's reachability result. If useful, they should be reviewed as a separate compiler-warning cleanup slice with their own semantics and evidence.

## Decision

**Keep observing as a periodic subtraction audit. Do not adopt as a mandatory CI gate yet.**

Reason:

1. Weeder gave unusually strong architectural evidence about the difference between executable reachability and declared public surface.
2. The experiment prevented a bad deletion conclusion twice: first for 181 public-surface declarations, then for 2 test-only declarations.
3. No safely deletable declaration was established by this run.
4. The actual graph analysis is fast once `.hie` data exists.
5. Cold installation/provisioning is heavy enough that every-PR source installation would waste feedback time and CI resources.
6. Weeder 2.10.0 segfaulted under the tested GHC 9.12.4 setup while working under 9.10.3, so version compatibility is not yet trustworthy enough for a required gate.

## Current operating rule

If Weeder is used again before the compatibility question is resolved:

- use it as observation, not deletion authority;
- pin a known-working compiler/tool combination;
- preserve exact public/teaching roots;
- include or independently verify test-only reachability;
- inspect every surviving finding in its owner before deletion;
- prefer cached/preinstalled periodic runs over cold installation on every PR.

No production dependency, permanent Weeder configuration, or mandatory CI step is added by this experiment.

## Next distinct experiment

Per the tooling ledger, the next experiment is `cabal-gild` as a diff observation. It should remain separate from both Weeder-driven subtraction and any compiler-warning cleanup.