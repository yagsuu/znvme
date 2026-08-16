# Spec writing

## Authority

Value: Essential.

Rules:

- Approved specifications MUST define contracts.
- Planning documents MUST NOT define production-code contracts.
- Each public module MUST have one approved owning specification. Its module
  header MUST cite that specification.
- Implementation work MUST land only from an `Approved` specification.

## Status values

Value: Essential.

Every specification MUST start with exactly one status line after its title:

```text
Status: Draft.
Status: Approved.
Status: Superseded by <path>[, <path>...].
```

Rules:

- `Draft` specifications are review material.
- `Approved` specifications are implementation contracts.
- A `Superseded` specification MUST name each replacement path.

## Language

Value: Essential.

Rules:

- Each contract requirement MUST be normative and testable.
- Each contract requirement MUST identify its actor, applicable condition, and
  observable action or constraint.
- Mandatory requirements MUST use RFC 2119 terms.
- Each specification MUST state applicable observable behavior, ownership,
  lifetime, invalidation, ordering, allocation, waiting, errors, and
  concurrency effects.
- Specifications MUST omit rationale, decision history, meeting context,
  approval context, implementation diaries, proposal language, marketing,
  tutorials, filler, and narration.
- Specifications MUST NOT cite material required to interpret a contract unless
  that material is available in the repository.
- Specifications MUST NOT describe speculative future work unless they
  explicitly exclude it.
- Specifications MUST NOT use non-contractual phrases such as `as discussed`,
  `for now`, `future work`, `until a consumer appears`, `the approved
  proposal`, `recommended`, or `where practical`.
- Specifications MUST replace vague debug behavior with exact conditions and
  configuration values.
- The specification text and its linked repository paths MUST contain enough
  information to implement and test the primitive.

## Section value model

Each specification MUST use the smallest section set that preserves its
production contracts.

Value levels:

- Essential: every approved specification MUST include it.
- High: the specification MUST include it when the primitive has the
  corresponding contract surface.
- Conditional: the specification MAY include it only when it removes ambiguity
  or prevents misuse.
- Medium: the specification MAY include it only when it clarifies composition.

## Standard section order

New and substantially revised specifications MUST use this order. Authors MUST
omit irrelevant conditional sections.

1. `# <Spec title>` — Essential.
2. `Status: Draft.`, `Status: Approved.`, or `Status: Superseded by <path>.` — Essential.
3. Short description — Essential.
4. `## What this spec is` — Conditional.
5. `## What this spec is not` — Conditional.
6. `## Terminology` — Conditional.
7. `## Public namespace` — Essential.
8. `## Cross-spec relationships` — High.
9. `## Data structures and representation` — High when state or layout matters.
10. `## Global invariants` — Essential.
11. `## API` — Essential.
12. Per-operation sections — High for non-trivial public operations.
13. `## Implementation constraints` — High.
14. `## Testing` — Essential.
15. `## Usage examples` — Medium.

Existing approved specifications MUST NOT receive format-only rewrites.

## Section rules

### Short description

Value: Essential.

Rules:

- The short description MUST be one paragraph.
- The short description MUST identify the primitive and its concrete job.
- The short description MUST NOT include rationale, marketing, tutorial text,
  or consumer history.

### What this spec is

Value: Conditional.

Include this section only when the short description, public namespace, API,
invariants, and testing sections do not make the owned scope clear.

Rules:

- This section MUST list only scope controlled by this specification.
- This section MUST identify each applicable owned type, operation, storage rule,
  state transition, ordering rule, invalidation rule, or required test.
- This section MUST NOT duplicate a contract stated elsewhere in the
  specification.
- This section MUST NOT include motivation or implementation strategy.

### What this spec is not

Value: Conditional.

Include this section only when an explicit exclusion prevents ambiguity,
prevents misuse, or distinguishes ownership from an adjacent specification.

Rules:

- This section MUST explicitly exclude only applicable adjacent policy domains.
- This section MUST name a sibling specification when that specification owns an
  excluded behavior.
- This section MUST NOT include generic disclaimers or rationale.

### Terminology

Value: Conditional.

This section MAY define only terms used by later contracts, invariants, APIs,
or tests.

Rules:

- Each defined term MUST have one fixed meaning.
- This section MUST NOT define common English words.
- This section MUST NOT include an unused glossary entry.

### Public namespace

Value: Essential.

This section MUST state:

- public import, module, or package paths owned by this specification;
- public exports from a facade owned by this specification, when applicable;
- explicit non-exports that prevent ambiguity or namespace collisions.

Rules:

- A feature specification MUST NOT approve or require an export from a package
  or subsystem facade that it does not own.
- Only the specification that owns a package or subsystem facade, or the
  top-level architecture specification, MAY approve exports from that facade.
- A facade MAY import, re-export, and alias approved public surfaces. A facade
  MUST NOT contain implementation logic.
- Project architecture rules MUST assign implementation source and test file
  ownership. A specification MUST NOT list those paths unless a path is a
  required public or build contract.

### Cross-spec relationships

Value: High.

Rules:

- This section MUST list required dependencies and intentional composition
  points.
- This section MUST distinguish `depends on` from `composes with but does not
  own`.
- This section MUST NOT cite a speculative sibling specification unless this
  specification excludes that scope or the sibling specification exists.
- This section MUST NOT duplicate another specification's contract.

### Data structures and representation

Value: High when representation affects behavior. Conditional otherwise.

Rules:

- The specification MUST state the conceptual model when it controls behavior.
- The specification MUST state representation only when observable behavior,
  ABI, layout, safety, complexity, or tests depend on it.
- The specification MUST state each required layout, ABI, wire format, packing,
  padding, and field-name guarantee.
- The specification MUST state each non-guarantee that callers could otherwise
  infer from layout or encoding.
- The specification MUST NOT include a `typical representation` sketch.
- The specification MUST NOT constrain private implementation strategy without
  contract value.

### Global invariants

Value: Essential.

Rules:

- This section MUST list invariants preserved by every operation.
- Each invariant MUST be testable.
- This section MUST specify applicable capacity, ordering, ownership, lifetime,
  invalidation, allocation, waiting, pointer stability, state-machine, and
  no-mutation-on-error rules.
- This section MUST NOT include implementation details unless representation is
  normative.

### API

Value: Essential.

Rules:

- This section MUST show the approved public surface in
  implementation-language snippets.
- All public signatures in this section are normative.
- This section MUST include associated public types and constants.
- This section MUST NOT include a private helper unless its shape is part of
  the public contract.
- This section MUST state an absent method when omission prevents misuse.

### Per-operation sections

Value: High for public operations that mutate state, fail, wait, allocate,
perform atomics, affect lifetime, invalidate handles or pointers, or define
ordering/concurrency semantics.

Each public operation with this contract surface MUST have a per-operation
section. Each per-operation section MUST include each applicable subsection:

- `Contract` — preconditions, postconditions, caller responsibilities.
- `Invariants` — operation-local invariants not covered globally.
- `State transitions` — before/after state changes.
- `Errors and fault behavior` — returned errors, no-mutation-on-error,
  caller-contract violations, assertions, traps, release-mode behavior.
- `Locking and waiting` — locks, backend calls, spinning, yielding, parking, or
  `never`.
- `Allocation behavior` — allocation, freeing, borrowing, allocator calls, or
  `never`.
- `NMI/interrupt safety` — safe contexts and caller obligations.
- `Memory ordering` — atomic orderings and happens-before edges.
- `Concurrency effects` — legal concurrent callers and external serialization.
- `Invalidation and lifetime` — handles, pointers, borrowed storage, copying,
  moving, deinitialization.
- `Complexity/progress` — cost, boundedness, lock-freedom, wait-freedom,
  blocking, retry behavior.

Rules:

- Trivial accessors MAY share a section only when their contracts are
  identical.
- Each mutating fallible operation MUST state its no-mutation-on-error rule.
- Each operation that returns or receives a handle, pointer, borrowed storage,
  or entry MUST state invalidation effects.
- When an effect is plausible, the operation MUST state whether it allocates,
  waits, reads clocks, invokes callbacks, touches hidden globals, or calls
  scheduler or backend APIs.

### Implementation constraints

Value: High.

Rules:

- This section MUST state each implementation constraint required to preserve a
  public contract.
- This section MUST state a no-hidden-globals, no-callbacks, no-allocation,
  no-syscalls, no-scheduler-calls, exact-field-names, cache-line-padding,
  atomic-publication, or algorithm-shape constraint only when
  contract-relevant.
- This section MUST NOT include implementation preference, rationale, or
  examples.

### Testing

Value: Essential.

Rules:

- This section MUST state each required test.
- Tests MUST cover contracts, invariants, errors, boundaries, transitions,
  ordering, invalidation, concurrency, and representation guarantees when
  applicable.
- Tests MUST NOT cover incidental implementation mechanics unless
  representation is normative.
- This section MAY group tests by purpose:
  - construction and capacity;
  - positive behavior;
  - negative/error behavior;
  - edge cases;
  - ordering;
  - invalidation and lifetime;
  - concurrency, model, and stress behavior;
  - memory ordering;
  - layout and representation.

### Usage examples

Value: Medium.

Rules:

- This section MAY include an example only when it clarifies a composition
  boundary or prevents misuse.
- Each example MUST be short.
- Each example is illustrative unless it states a normative requirement.
- This section MUST NOT include a tutorial or duplicate an API contract.

## Template

```md
# <Spec title>

Status: Draft.

<One-paragraph short description.>

<!-- Omit when the short description and contract sections make scope clear. -->
## What this spec is

<Owned scope that is not clear elsewhere.>

<!-- Omit when no explicit exclusion prevents ambiguity or misuse. -->
## What this spec is not

<Excluded policy domains or adjacent-spec ownership.>

## Terminology

<Only fixed terms used by contracts. Omit if unnecessary.>

## Public namespace

<Public import, module, or package paths and facade exports owned by this
spec.>

## Cross-spec relationships

<Dependencies and composition points.>

## Data structures and representation

<Conceptual model, required representation/layout, invalid states, guarantees,
and non-guarantees.>

## Global invariants

<Invariants every operation preserves.>

## API

<Approved public surface.>

### `<function/type/member>`

#### Contract

<Preconditions, postconditions, caller responsibilities.>

#### Invariants

<Function-specific invariants. Omit if fully covered globally.>

#### State transitions

<Before/after state. Omit for pure accessors.>

#### Errors and fault behavior

<Returned errors, no-mutation-on-error, caller-contract violations, traps.>

#### Locking and waiting

<Locks taken, backend calls, spin/park/yield behavior, or `never`.>

#### Allocation behavior

<Allocates/frees/borrows/calls allocator, or `never`.>

#### NMI/interrupt safety

<Safe contexts and caller obligations.>

#### Memory ordering

<Atomic orderings and happens-before edges.>

#### Concurrency effects

<Concurrent callers and serialization ownership.>

#### Invalidation and lifetime

<Handles, pointers, borrowed storage, copying/moving, deinit effects.>

#### Complexity/progress

<O(1), O(n), bounded/unbounded retry, lock-free/wait-free/blocking.>

## Implementation constraints

<Contract-relevant implementation constraints.>

## Testing

<Required contract tests.>

## Usage examples

<Short illustrative examples. Omit if unnecessary.>
```
