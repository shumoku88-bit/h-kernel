# AI Concierge consultation lane

## Purpose

`tools/hk concierge` is the read-only entry point for asking an AI about the
Household as a financial concierge. It is intentionally separate from normal
repository development and from every Household writer command.

The AI is an observer and adviser. It is not a Household authority.

## Commands

```text
tools/hk concierge protocol
tools/hk concierge overview
tools/hk concierge export
tools/hk concierge packet
```

`protocol` prints the epistemic and mutation rules without reading private
Household data.

`overview` emits the protocol plus the canonical Haskell report. This is the
normal first observation for a consultation.

`export` emits the protocol plus the exact eight canonical root source texts and
the explicit `issue-relations.tsv` provenance sidecar. Use it only when the AI
needs source evidence that the report does not contain.

`packet` emits both the canonical report and the exact root-source text in one
observation. It is useful for a one-shot consultation but is intentionally
larger than `overview`.

All data-bearing commands use the same `--base`, `HKERNEL_LEDGER_DATA_DIR`, or
`ledger-data.local` Household root selection already owned by `tools/hk`.

## Read-only boundary

The concierge route has no command that forwards arbitrary arguments to
`h-kernel-editor-cli`. It does not expose Account, Actual, Plan, Budget, Issue,
or relation writers.

During a consultation the AI must not leave this route to call:

```text
tools/hk actual-add
tools/hk actual-multi
tools/hk actual-reverse
tools/hk account
tools/hk plan
tools/hk budget
tools/hk issue
tools/hk edit
```

A recommendation to change the Household is prose until a human deliberately
leaves consultation mode and performs a normal admitted write through the
existing writer path.

This is a capability boundary for the consultation workflow, not an operating
system sandbox. A terminal agent with unrestricted shell access can still see
other repository commands, so its consultation instruction must explicitly
require the concierge protocol.

## Implementation boundary

`tools/hk` is routing-only. The consultation command is executed by the existing
Haskell `exe:h-kernel` application as:

```text
h-kernel concierge protocol
h-kernel concierge overview
h-kernel concierge export
h-kernel concierge packet
```

The Haskell application owns canonical Household admission, source observation,
staleness fencing, canonical report calculation, and packet rendering. The
concierge lane introduces no Python transport, no shell-owned Household
semantics, and no second Household engine.

The editor library is not involved in the consultation path. Writer commands
remain separate `h-kernel-editor` capabilities reached only after explicitly
leaving consultation mode.

## Canonical configuration

Concierge report calculation uses the admitted canonical
`householdStateReportConfig` from the selected Household. It does not consult
the development-time `HKERNEL_REPORT_CONFIG` override used by ordinary report
experiments.

Because `concierge` is dispatched before ordinary Journal input resolution,
`HKERNEL_JOURNAL` and `LEDGER_FILE` are not consultation evidence either.
`tools/hk --base DIR` resolves only the Household root and passes it as
`HKERNEL_LEDGER_DATA_DIR` to the read-only Haskell application.

## Observation fence

A data-bearing concierge command does not print a packet after one admission or
one source read.

The Haskell application performs:

1. a first exact source-text snapshot of the eight canonical root coordinates
   and the explicit relation sidecar;
2. a first canonical `HouseholdState` admission;
3. a first canonical Report projection;
4. a second exact source-text snapshot;
5. a second canonical `HouseholdState` admission;
6. a second canonical Report projection;
7. a third exact source-text snapshot.

Output is emitted only when all three source snapshots, both admitted
`HouseholdState` values, and both Report projections are equal. A concurrent
Household change therefore fails closed instead of producing a mixed-time
packet.

Comparing admitted Household state also observes semantic changes reached
through Journal include resolution even when root text itself is unchanged.

The canonical Report projection is shared with the ordinary default Household
Report path through the same Haskell rendering function. Concierge supplies the
admitted canonical `report.toml` configuration directly; it does not fork a
second report implementation.

The eight canonical paths and the relation sidecar path are read through typed
`HouseholdSourcePaths`; the concierge does not maintain a second basename table.

## Evidence hierarchy

The AI must distinguish these classes instead of blending them into one story:

- **observed fact**: admitted Actual or other canonical fact;
- **plan**: admitted future or intended fact;
- **configuration**: current policy, routing, presentation, or Envelope
  configuration;
- **relation/history**: an explicitly recorded provenance relation;
- **report projection**: a deterministic Haskell-derived view of admitted
  Household state;
- **recommendation**: the AI's advice, which is never evidence by itself.

Identity and relations must never be inferred from similar dates, descriptions,
amounts, Account shapes, or source positions. Stable identities and explicit
relation rows are the only relationship evidence.

## Relation sidecar status

`issue-relations.tsv` remains an explicit provenance sidecar and is not promoted
into the canonical eight-source `HouseholdState` by this lane.

Concierge v1 fences and exports its exact source text, but does not introduce a
second relation-reference admission path merely for AI export. That omission is
made explicit in the protocol as `sidecar_admission` rather than pretending the
sidecar is a ninth canonical source or inferring relation validity from
similarity.

A later Haskell read-only relation observation boundary may strengthen this
without changing the consultation command surface.

## Recommended terminal-agent instruction

A terminal AI acting as a household financial concierge should be given a small
instruction equivalent to:

```text
You are a read-only household financial concierge.
Use only `tools/hk concierge ...` for Household evidence during consultation.
Start with `tools/hk concierge overview`.
Use `export` only when source evidence is required, or `packet` when a complete
one-shot observation is appropriate.
Treat the emitted protocol as binding.
Do not infer identity or relationships from similarity.
Distinguish facts, plans, configuration, explicit history, report projections,
and your recommendations.
Never perform a Household write during consultation.
```

This instruction is intentionally vendor-neutral. Claude, Codex, OpenCode, or
another terminal agent should consume the same Household observation protocol
rather than receiving provider-specific accounting semantics.
