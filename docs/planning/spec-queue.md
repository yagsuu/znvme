# Spec queue

This document is planning material. Normative requirements live only under `docs/specs/`.

Transcription sources: the NVMe Base Specification 2.0 and the NVM Command Set Specification 1.0 (see `docs/specs/project/scope.md`).

## Workflow

1. Pick the next item from `Queue`.
2. Present the draft shape to the user before writing:
   - owned scope;
   - deferred scope;
   - wire/layout invariants;
   - public API shape;
   - builder/view behavior;
   - validation behavior;
   - example usage;
   - open questions.
3. Wait for explicit approval.
4. Write the approved spec under `docs/specs/`.
5. Move the item from `Queue` to `Approved`.
6. Repeat.

Implementation of a slice begins only after the required specs for that slice are approved and written. A module without its owning spec does not land.

## Draft requirements

Drafts must include: owned scope, deferred scope, wire/layout invariants, public API shape, builder/view behavior, validation behavior, example usage, open questions, and — when the module composes stdx primitives — the exact `stdx` types consumed.

Every draft names the domain-neutral primitives it needs. If any is not yet provided by stdx, propose the primitive upstream against `../zstdx` before writing the `znvme` spec. znvme does not implement local replacements.

Drafts must not include: rejected alternatives unless the user asks for comparison, implementation work, speculative future phases, non-normative prose inside the final spec.

## Approved

- `docs/guidelines/zig.md`
- `docs/guidelines/conventions.md`
- `docs/guidelines/testing.md`
- `docs/decisions.md`
- `docs/specs/project/scope.md`
- `docs/specs/architecture.md`
- `docs/specs/core/ids.md`
- `docs/specs/core/dma.md`
- `docs/specs/core/status.md`
- `docs/specs/core/registers.md`
- `docs/specs/core/doorbell.md`
- `docs/specs/core/prp.md`
- `docs/specs/commands/sqe.md`
- `docs/specs/commands/cqe.md`
- `docs/specs/controller/queue.md`
- `docs/specs/controller/init.md`
- `docs/specs/commands/admin.md`
- `docs/specs/identify/controller.md`
- `docs/specs/identify/namespace.md`
- `docs/specs/commands/nvm.md`
- `docs/specs/verification/test-strategy.md`

## Queue

### Examples

- `docs/specs/examples/controller-bringup.md`
- `docs/specs/examples/read-namespace.md`
- `docs/specs/examples/malformed-inputs.md`
