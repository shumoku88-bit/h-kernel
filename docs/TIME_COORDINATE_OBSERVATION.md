# Time as Coordinate — Observation Note

Status: exploratory only. No implementation or architecture decision is made here.

## Why keep this note

h-kernel already contains several independently evolved temporal ideas that appear to share a deeper shape. Before introducing a new abstraction, preserve the observation and later test it against the code.

The question is not mainly whether computation executes sequentially. It is whether the household domain must be modelled as a state that moves from past to present to future, or whether time can instead be treated as a coordinate on a larger structure.

A rough distinction:

```text
state progression

past -> present -> future

versus

temporal field

Household x Time -> view / meaning
```

In the second picture, the present is not necessarily privileged in the model. It can be the coordinate from which an observer currently looks.

## Existing evidence in h-kernel

This is not a proposal starting from zero.

### Period is already a temporal coordinate

`HKernel.Period` explicitly describes `Period` as a resolved temporal coordinate consumed by pure calculations. It does not claim that household history itself is partitioned by the period.

### Plan observation is already as-of observation

`HKernel.Plan.Open` resolves open and completed Plans at an explicit observation day. Planned transaction date is not itself the selection coordinate for whether a commitment exists.

This matters because a future-directed commitment can already be a fact of the present without the future event being an Actual fact.

### Cycle already sees past and future together

`HKernel.Household.Cycle.observeHouseholdCycle` uses Actual anchors at or before an observation coordinate and a future Plan anchor after that coordinate to derive previous and current periods in one pure observation.

The observer does not need to process "past, then present, then future" as three semantic stages.

### Envelope Change is already a relation between coordinates

`HKernel.Household.EnvelopeObservation` represents Change between two typed observations. The result retains `from` and `through` coordinates and every value is later minus earlier.

Change is therefore already close to being a first-class relation between temporal coordinates rather than merely the output of sequential mutation.

## Candidate temporal meanings

Do not collapse these into one `TimeCoordinate` type without evidence. They may be different semantic roles that happen to use `Day` operationally today.

```text
Event coordinate
  When something happened in household time.

Knowledge coordinate
  When that fact became known to this household model or observer.

Intention coordinate
  When a commitment or plan is directed toward.

Focus coordinate
  Which day an observer is looking at.

Interval coordinate
  Which temporal region a calculation concerns.

Relation coordinates
  Two or more coordinates whose relation is itself meaningful, such as Change.
```

Past, present, and future may then be relations between coordinates rather than three different containers of data.

## The important unresolved question

Suppose an Actual transaction happened on 2026-08-05 but was first recorded or learned on 2026-08-21.

When asking for an observation as of 2026-08-10, should that transaction be visible?

Two legitimate questions exist:

```text
What was true by 2026-08-10?

What was known by 2026-08-10?
```

The current model primarily answers the first kind using transaction/event dates. Source provenance retains physical source coordinates, but h-kernel does not currently appear to retain a separate canonical knowledge-time coordinate for each fact.

If the second question matters, event time and knowledge time must not be silently identified.

This resembles bitemporal modelling, but that name should not dictate the design. First determine which temporal questions the household domain actually needs.

## Future is not a pre-existing Actual fact

Treating future time as a coordinate must not imply that future contingent facts are already known or fixed.

```text
future coordinate exists
!=
future Actual fact exists
```

A Plan, expectation, possibility, or commitment may point toward a future coordinate while being evidence that exists now.

A useful distinction to preserve:

> A future event is not yet an Actual fact, while a present commitment toward that future can already be a fact.

## Questions for the later observation

Before changing code, inspect the repository across Plan, Actual, Issue, Envelope, Cycle, Report, provenance, and editor boundaries and ask:

1. Which `Day` values denote event time, observation time, intention time, due time, or focus time?
2. Which distinctions are currently protected only by names and module boundaries?
3. Where is "current" unnecessarily privileged?
4. Which calculations are already relations between two or more temporal coordinates?
5. Can an observation be reproduced from the knowledge that was available at an earlier coordinate, or only reconstructed from facts known now?
6. Where would separating valid/event time from knowledge time materially change semantics?
7. Can Change, provenance, Plan lifecycle, and Cycle be described more simply as projections or relations over one temporal structure?
8. Which laws emerge repeatedly before any shared abstraction is introduced?

## Guardrail

Do not create a grand temporal framework merely because the vocabulary sounds elegant.

First look for the same law appearing independently in several mature parts of the code. If a shared abstraction eventually appears, it should be discovered from those laws rather than imposed on them.
