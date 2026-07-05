# Zig engineering guidelines

Normative baseline for Zig source. Project-specific conventions may tighten these rules or define narrower vocabulary, but must do so explicitly.

## Priorities

Prefer designs in this order:

1. correctness and safety;
2. predictable performance;
3. developer experience.

Readable code is required, but readability serves correctness. Prefer explicit, bounded, boring designs over clever abstractions.

## Source of truth

- Approved specs and project convention documents define contracts.
- Planning notes, task lists, chats, and examples do not define stable APIs or behavior.
- If implementation needs an unresolved contract, stop at that boundary and resolve the contract before landing public API.
- Code comments may cite stable specs. They must not cite planning notes, milestones, task IDs, or conversations.

## File and module ownership

- Each file owns one concept or one type family.
- Split by responsibility, not arbitrary size.
- Keep dependency direction explicit. Lower layers must not import orchestration layers.
- Facades and root modules must be thin: re-exports and aliases only, no hidden allocation, validation, synchronization, probing, or policy.
- Avoid catch-all files such as `utils.zig`, `helpers.zig`, `common.zig`, and `misc.zig`.
- Use names that identify the owned concept: `parse.zig`, `validate.zig`, `alignment.zig`, `ring.zig`.

## Imports and declarations

Top-level declarations at the head of a file must be partitioned into the following groups. Non-empty groups are separated by exactly one blank line; empty groups collapse. No group is split by a blank line internally.

1. **Module imports.** Bare `@import("...")` bindings. Split into three subgroups, in order, one blank line between non-empty subgroups: `std`/`builtin`, then external packages, then local modules. A subgroup of one entry still stands alone; do not fold `std` into local imports.
2. **Type aliases.** Bindings whose *name* is `TitleCase` and whose RHS resolves to a type. This covers renaming a foreign type (`const Node = foreign.Node;`), naming an instantiated generic (`const IndexMap = HashMap(usize, Entry);`), naming a primitive under a domain identity (`const Word = u64;`), and pulling a type through an import expression (`const Range = @import("core/range.zig").Range(usize);`).
3. **Value aliases.** Bindings whose *name* is `camelCase` or `snake_case` and whose RHS is a runtime value or comptime data — not a function. This covers computed constants (`const word_bits = @bitSizeOf(Word);`), string and integer literals (`const default_prompt = "?> ";`, `const max_depth = 32;`), and re-exports of enum tags or comptime constants (`const default_mode = foreign.Mode.strict;`).
4. **Function aliases.** Bindings whose *name* is `camelCase` or `snake_case` and whose RHS is a function — an identifier resolving to a function declaration, a member access producing one (`const alignUp = alignment.alignUp;`), or a comptime-invoked type factory used at the value level.

The type/value split is decided by naming: `TitleCase` names a type, anything else names a value. A binding whose case violates that is a naming defect, not a grouping exception. The value/function split is decided by the RHS: a function alias re-exports something callable, a value alias re-exports data or a comptime constant. When the split is ambiguous (a comptime function that returns a value in every practical use), pick the group that matches how the alias is read at call sites and keep it consistent.

Within a group, keep dependency order only when reordering would obscure a top-to-bottom dependency. Otherwise sort by alias name. Do not add comments that merely label obvious groups.

Module imports must use the module's natural name. Do not add `_mod` or `_module` suffixes to avoid a collision; rename the local declaration instead.

Prefer a top-level type alias when a file repeatedly uses one type from a module. Keep the module namespace when several declarations are used through the same namespace.

Facade and aggregate files must apply the same grouping rules to public re-exports. A facade that re-exports both types and functions from the same submodule places the types above the functions with one blank line between.

## Formatting

- Run `zig fmt`.
- Use 4 spaces; no hard tabs.
- Keep lines at or below 120 columns; never beyond unless an external literal or generated content makes the alternative worse.
- Use trailing commas to let `zig fmt` wrap long parameter lists, calls, literals, and type declarations.
- Add braces to every `if` / `while` / `for` / `switch` body unless the entire construct fits on one line. Single-line braceless bodies are allowed only when the body is one statement, the header and body fit together within the column limit, and no nested control flow is present.
- A `for` / `while` with an explicit step expression (`while (cond) : (i += 1) { ... }`) is always braced.
- Vertical and horizontal spacing follow the `Vertical rhythm` and `Horizontal density` sections below.

## Vertical rhythm

Spacing follows fixed rules from the file down to the statement. The goal is dense code with consistent break points, not whitespace for its own sake.

**One blank line is the only separator.** Every rule below defines where exactly one blank line is required and where exactly zero blank lines are permitted. Two or more consecutive blank lines anywhere in source are prohibited. End of file is exactly one trailing newline.

### File level

**Header separation.** The module `//!` header sits at the top of the file. One blank line follows the header before the first declaration. Do not indent, banner, or box the header.

**Import and alias grouping.** Follow the group order in `Imports and declarations`. One blank line between non-empty groups; no blank lines inside a group. A group of one entry still stands alone.

**Between top-level declarations.** Exactly one blank line separates two adjacent top-level declarations (functions, types, tests, `comptime {}` blocks, module-private helpers). This applies whether or not the declaration carries a doc comment.

**Doc-comment adherence.** A `///` doc-comment block touches the declaration it documents; no blank line between the last `///` line and the declaration. The single blank line that separates one declaration from the previous one goes above the doc comment, not between the doc comment and its declaration.

### Type body

**Fields then members.** Struct/union/enum fields form a contiguous block with no internal blank lines. One blank line separates the field block from the first ordinary member declaration.

**`const Self = @This();`** — when present, it is the *first* member. One blank line above (following the standard field-to-members separator) and one blank line below (before the first `pub const` or method). Treat it as a bridge declaration that isolates the type identity from the payload it points at.

**Constant families.** Two or more `pub const` declarations that share a role on the same type (error sets, capacity constants, associated types) pack with no internal blank lines when undecorated, and with the standard one-blank-line separation when each carries its own `///` block. Do not mix decorated and undecorated entries inside one family; either every member has a doc comment, or none does.

**Members.** One blank line separates any two adjacent methods, nested types, or member `const`s that are not part of a packed constant family.

### Function body

**Phases, not statements.** A function body reads as an ordered sequence of *phases*, each one a small group of statements that pursues a single sub-goal. Adjacent phases are separated by exactly one blank line; statements inside a phase pack with no blank lines. The recognizable phases, in order when present:

1. **Precondition assertions** — argument checks (`assert`, `debug.assert`), tag/shape validations, comptime contracts asserted at runtime. Two or more form an assertion cluster.
2. **Argument-driven guards** — early-exit checks that reject invalid or empty inputs (`if (cond) return ...;`). Form one guard cluster.
3. **Preparation** — locals derived from the arguments: masks, capacities, cached loads, decoded fields.
4. **Core work** — the load-bearing computation. Long cores split into further phases at each sub-goal transition (e.g. "search" → "commit", "read" → "verify" → "write").
5. **Postcondition assertions and return** — invariant checks on the result, then the return statement. A single postcondition assert sits touching the return; two or more form a cluster with one blank line above.

A phase of one statement is still a phase — it takes its own blank-line boundary. A phase absent in this function is skipped entirely; do not insert an empty separator.

**Assertion clusters.** Two or more consecutive `assert(...)` / `debug.assert(...)` calls form a cluster with no internal blank lines. One blank line separates the cluster from the code above and below, even when that code is a single expression. A lone assertion is not a cluster: place it on the boundary of the phase it defends.

**Guard clusters.** Single-line early-exit guards (`if (cond) return ...;`, `if (cond) continue;`, `if (cond) break;`) form one contiguous cluster with no internal blank lines. One blank line follows the cluster before the main work.

**Block flanks.** A multi-line `if` / `else` / `while` / `for` / `switch` / `comptime` / anonymous block inside a function is separated from adjacent non-block statements by one blank line above and one blank line below. Two adjacent multi-line blocks take one blank line between them. The flank is omitted when the block is the first or last statement of its enclosing scope.

**Resource grouping.** A resource acquisition and its matching `defer` or `errdefer` form a pair. Put one blank line above the acquisition and one blank line below the deferral. The pair then reads as a visual block and a missing `defer` is easier to spot.

**Local-binding placement.** A `const` or `var` whose first use is inside a block sits immediately above that block, with no blank line between binding and block. Multiple bindings that prepare one block group together with no internal blank lines.

**In-function comments.** A comment touches the statement or block it describes: no blank line between the comment and its target. The one blank line that separates the annotated statement from the previous statement goes above the comment.

**Trivial functions.** Bodies of three or fewer statements take no internal blank lines; a lone precondition assert also stays touching the work.

**No decorative blank lines.** A blank line inside a function body must satisfy one of the rules above. Blank lines added only to "let the code breathe" are prohibited.

## Horizontal density

**Intermediate binding.** When a single expression chains three or more operations of different kinds (arithmetic, indexing, bit ops, casts, slicing), lift intermediates to named `const`s. Two-operation expressions stay inline.

**Boolean condition split.** A two-operand boolean condition stays inline. Three or more operands must be lifted to named `const`s above the conditional; if branches still need to be audited separately, nest `if/else` rather than continue chaining `and`/`or`.

**Cast clustering.** Chained `@ptrCast` / `@alignCast` / `@bitCast` stay on one line. If the chain exceeds the column limit, lift the inner cast to a named `const`. Casts never break across lines without a name.

**`else if` and `switch`.** Replace `else if` chains of more than three arms over a closed input domain with `switch`. `switch` prong layout: multi-line bodies on their own line; single-expression prongs may share the line with the case label; no blank lines between prongs.

## Naming

Default to Zig naming:

- `TitleCase` for types and type factories.
- `camelCase` for runtime functions and methods.
- `snake_case` for variables, fields, files, directories, and namespaces.

Rules:

- Names must encode domain meaning, ownership, units, and lifetime when those facts matter.
- Put units and qualifiers last: `size_bytes`, `offset_bytes`, `latency_ms_max`. Sort qualifiers by descending significance so related variables align in source.
- Treat acronyms as words unless an external ABI or spec requires exact spelling.
- Avoid names that add no information: `Data`, `Value`, `Context`, `Manager`, `Utils`, `Misc`.
- Avoid namespace stutter in fully qualified names.
- Use allocator names that communicate ownership and lifetime, such as `gpa`, `arena`, `scratch`, or `pool`.
- Names must not imply guarantees stronger than the owning spec provides.
- Do not use vague labels such as `thread_safe`; state the access model and progress guarantee explicitly.
- When a function exists primarily to serve one caller, prefix its name with the caller's name to show the call chain: `readSector` / `readSectorCommit`, `parseHeader` / `parseHeaderField`.
- When several related names appear in the same code (`source`/`target`, `start`/`end`, `head`/`tail`), prefer names of the same character length so derived identifiers line up vertically in calculations and slices.
- Prefer nouns over present participles for state names: `pipeline`, not `preparing`; `queue`, not `enqueuing`. Nouns compose cleanly into derived identifiers (`pipeline_max`).
- When two same-typed arguments could be swapped at a call site, the function must take an options struct. A function taking two `u64` operands without an options struct is a defect.
- Dependencies (allocators, tracers, clocks) are positional, from most general to most specific. Callbacks go last.

**Intra-file order.** Source files read top-down. Place the most important declaration near the top. Within a struct: fields, then nested types, then `pub fn init`, then other methods. A `const Self = @This();` alias concludes the types section. Nested types complex enough to need their own methods become top-level structs.

## Comments and docs

Omit comments unless they satisfy one of the allowed categories below.

Use comments for:

- module headers that state purpose and owning spec;
- exported API docs for semantic facts the type or signature cannot carry;
- non-obvious invariants, hazards, external constraints, and why the obvious alternative is wrong.

Module headers (`//!`) must be one to three terse lines. They state the module's purpose and owning spec path.
They must not describe project status, future work, implementation history, milestones, or process flow.

Exported `///` docs must state semantic facts the type or signature cannot carry: ownership, lifetime, units,
allocation behavior, blocking or waiting behavior, capacity behavior, concurrency/access contract,
pointer/index/iterator invalidation, memory ordering, and public error conditions.

Do not use comments for:

- narration of code;
- changelog notes;
- milestone, task, roadmap, or planning references;
- chat, review, or "per discussion" references;
- process narration such as "filled in later", "future phase", or "when a consumer needs it";
- commented-out code;
- decorative banners;
- TODO/FIXME/XXX in landed code;
- restating a function signature or field declaration.

Code comments may cite stable specs or ADRs. They must not cite planning docs, milestones, task IDs, roadmap
stages, chats, reviews, or informal agreements.

**Prose style.**

- Comments are complete sentences: capital letter, terminal period. End-of-line comments may be phrases without punctuation.
- Spacing around comments follows `Vertical rhythm`: a `///` block touches its declaration, an in-function comment touches the statement or block it describes, and the blank line goes above the annotation.

**Always motivate.**

- Say why. Code records what; comments record why. Without rationale, the next reviewer cannot tell intent from accident.
- Say how. Each non-trivial test has a one-line description of goal and methodology above the body. Each non-trivial module documents its mental model in the module header or a top-level comment block, not in scattered margin notes.

Comments are concise prose. Prefer one load-bearing paragraph over several vague paragraphs.

## Control flow

- Use simple, explicit control flow.
- Avoid recursion in critical, bounded, or hot code.
- Every loop must have an obvious bound, an asserted bound, or an intentional non-termination contract.
- State invariants positively. The form `if (index < length) { /* holds */ } else { /* fails */ }` reads correctly against the loop condition that produced it; the negated form `if (index >= length) { /* invariant fails */ }` is harder to verify.
- Compound boolean conditions of three or more operands must be lifted to named `const`s above the conditional. Use nested `if/else` when each operand selects a distinct case the reviewer must audit separately.
- Prefer exhaustive `switch` over broad `else` when the input domain is closed.
- Push branching up and keep leaf helpers narrow and predictable.
- Never alias a variable or copy it under a second name solely to shorten an expression. Aliases drift out of sync.

## Function shape and length

A function fits the screen. The hard limit is **80 lines** including signature and closing brace; pure data tables (lookup arrays, generated literals) are exempt and noted as such. Many functions should be shorter — 80 is the ceiling, not the target.

- Good function shape is an inverse hourglass: a few parameters, a simple return, and the meaty logic between.
- Centralize control flow in the parent. Helpers compute; the parent branches. "Push `if`s up and `for`s down" — keep branching at the orchestration layer and let leaves stay pure.
- Centralize state in the parent. Helpers return what should change; the parent commits the change. Leaf functions stay pure.
- Extract hot loops into stand-alone functions that take primitive arguments instead of `self`. This removes the compiler's burden of proving fields cacheable in registers and lets a human spot redundant computations.
- Return-type dimensionality is a design pressure. Prefer `void` over `bool`, `bool` over `T`, `T` over `?T`, `?T` over `!T`. Every layer added at the leaf propagates branch handling up the call chain.

## Variable scope and lifetime

- Declare every variable at the smallest scope that admits its uses.
- Minimize the number of variables live at any point. A variable referenced once is usually inlinable; introducing a name should pay for itself in clarity or shared subexpression elimination.
- Compute or check a value close to its use. Long distances between place-of-check and place-of-use breed bugs; most defects come from a gap in time or space that breaks a check's relevance to its use.
- Never alias a variable to shorten an expression. Aliases drift; reads and writes diverge.

## Assertions and invariants

Assertions are part of the design. Assertions detect programmer errors; operating errors must still be handled.

- Assert function preconditions, postconditions, and internal invariants. The average assertion density is at least two per non-trivial function.
- Prefer split assertions over compound: write `assert(a); assert(b);`, not `assert(a and b);`. A split assertion names the failing fact at the failing line.
- Use `if (a) assert(b);` for implications: "when `a`, `b` must hold."
- Pair assertions across boundaries: caller/callee, producer/consumer, writer/reader, encoder/decoder, before/after a checkpoint.
- Assert the **positive space** of expected valid inputs **and** the **negative space** of inputs expected to be impossible. Interesting bugs hide at that boundary.
- Add compile-time assertions for type sizes, alignments, field offsets, enum values, bit masks, and constant relationships. Type-owned `comptime` checks live inside the type body.
- An assertion encodes a programmer error. User, input, environment, and resource failures must still be handled as explicit errors.
- A blatantly true assertion is allowed when it documents a critical and surprising invariant more loudly than a comment would.
- Spacing of assertion clusters, guard clusters, and post-condition asserts follows `Vertical rhythm`.

## Types, ABI, and layout

- Use explicit integer widths for persisted, ABI, wire, and cross-platform data.
- Use `usize` for host memory sizes, indexes, and APIs where pointer width is actually the unit.
- Use strong types for addresses, sizes, pages, offsets, IDs, and handles when mixing them would be a bug.
- `index`, `count`, and `size` are distinct conceptual types even when their representation is `usize`. The conversions are explicit: `count = index + 1`, `size = count * unit_bytes`. Include the unit in the destination name (`size_bytes`, `count_items`) so the cast direction is obvious at the call site.
- For division, use `@divExact`, `@divFloor`, `@divTrunc`, or a project `divCeil`. Plain `/` on integers without an explicit rounding choice is forbidden in landed code; the reader must see which rounding mode the author intended.
- Model flag words as typed structures or enums with named operations; avoid raw mask arithmetic in high-level code.
- ABI-boundary types must use the layout required by their ABI and carry scoped compile-time layout assertions inside the type body.
- Reserved bits and fields must be zeroed on output and validated on input when the contract requires it.
- Keep `@ptrCast`, `@alignCast`, `@bitCast`, and narrowing integer casts close to the boundary that justifies them.
- Pass arguments by `*const` when the parameter type is at least 16 bytes and the function does not require an owned copy. Passing by value at that size silently copies onto the stack and hides bugs where the caller expected to share state.

## Memory and allocation

Allocation behavior is part of the public contract.

- Public APIs must not hide allocation.
- Hot paths, panic paths, interrupt/signal paths, ABI callbacks, and dispatch loops must not allocate unless their contract explicitly allows it.
- Prefer caller-provided storage, fixed buffers, bounded containers, and precomputed immutable tables when bounds are known.
- Initialize and freeze hot-path structures before entering the hot path.
- Put `defer` or `errdefer` immediately after successful acquisition. Flank the acquisition and the deferral with blank lines so the pair reads as a single block.
- Owned types should expose `deinit`; borrowed views must be named and documented as borrowed.
- Pass large immutable inputs by `*const` when copying would be accidental or expensive (see the 16-byte threshold under Types).
- Construct large or pointer-stable values **in place** via an out-pointer instead of returning by value. In-place initialization assumes pointer stability and immovable types and avoids intermediate copy-move stack growth:

  ```zig
  fn init(target: *LargeStruct, gpa: Allocator) !void {
      target.* = .{ ... };
  }

  // call site
  var target: LargeStruct = undefined;
  try target.init(gpa);
  ```

  In-place initialization is viral: once one field requires it, the enclosing container initializes in place too.
- A function with active assertions about its arguments must run to completion without yielding. Do not interleave `await` or callback re-entry into a body whose assertions must hold for the body's lifetime.

## Errors

- All errors must be handled, translated, or propagated.
- Use narrow, domain-owned error sets at module boundaries.
- Use `anyerror` only at true orchestration boundaries where narrower sets would hide real dependencies.
- Log or diagnose errors at the point with the most context; avoid duplicate noisy logs up the stack.
- `catch unreachable` requires local proof that the error is impossible.
- Degradation must be explicit and observable. Do not silently continue in a half-valid state.

## API shape

- Constructors and operations must live on the type they affect.
- Use `Type.init(...)` for non-allocating initialization unless the owning convention defines a different constructor
  vocabulary.
- Use distinct methods or enums instead of public boolean mode parameters.
- Use an options struct when same-typed arguments can be confused.
- Pass dependencies and allocators explicitly.
- Pass callbacks last.
- Explicitly pass load-bearing options at call sites instead of relying on defaults. The next library release may change a default; a call site that names the option survives.
- Separate pure transforms from I/O, allocation, synchronization, syscalls, architecture probing, and privileged
  operations.
- Do not leave compatibility aliases after a rename; update callers.
- Public `anytype` requires an intentional comptime interface. Do not use it to avoid naming a contract.
- Do not introduce catch-all registries, object systems, or vtables unless the owning spec defines that abstraction.
- Avoid ambiguous `usize` APIs when the value has units. Use strong types or names that encode the unit.

Construction-related `Error`, option/parameter structs, iterators, handles, and owned helper types must nest under
the type they serve.

Avoid module-scope `build*`, `make*`, or `from*` free functions when the result type can own the constructor.

Use `from` for pure reinterpretation or conversion from one input. Project overlays may define narrower constructor
vocabulary such as `build`, `validate`, `wrap`, or `seal`.

## Public contracts

Every non-trivial public API must document the contracts it exposes:

- allocation behavior;
- blocking, waiting, and spinning behavior;
- capacity model;
- execution bounds;
- concurrency/access contract;
- progress guarantee where concurrent;
- pointer, index, handle, and iterator stability;
- invalidation rules;
- deterministic iteration behavior;
- memory ordering where relevant.

## Concurrency and ordering

- Public APIs must not hide blocking, sleeping, spinning, or waiting.
- State access contracts explicitly: single-threaded, externally synchronized, SPSC, MPSC, MPMC, owner/thief, interrupt-safe, or signal-safe.
- Atomic operations must name the ordering at the operation site.
- Ordering comments must sit near the operation that enforces the ordering.
- Compiler barriers, CPU fences, I/O barriers, and DMA barriers must not promise effects outside their documented scope.

## Performance

- Think about performance from design forward. The largest wins come from the shape of the system, not from micro-tuning after profiling.
- Back-of-envelope every non-trivial change across the four resources (network, disk, memory, CPU) and the two characteristics (bandwidth, latency). Sketches are cheap and land within 90% of the global maximum.
- Optimize for the slowest resource first, weighted by frequency: a frequent memory miss can cost more than a rare disk write.
- Distinguish control plane from data plane. Control may be expensive and assertion-heavy; data must be cheap and batched. A clear delineation enables high assertion safety without losing throughput.
- Amortize network, disk, memory, and CPU costs by batching.
- Let the CPU run straight: predictable branches, predictable memory access, large enough work units that the pipeline does not stall.
- Avoid avoidable allocation, copying, formatting, syscalls, locks, and indirect dispatch in hot paths.
- Be explicit. Extract hot loops into stand-alone functions with primitive arguments and no `self` so the compiler does not have to prove that fields cache in registers and a human can spot redundant computation.
- Prefer simple immutable tables and direct data layouts when they make costs predictable.
- Use explicit arithmetic operations that state rounding, wrapping, saturation, and overflow intent.
- Do not accept cleverness solely because it benchmarks well on one workload.

## Tests and verification

- Test behavior and invariants, not incidental implementation shape.
- Cover valid inputs, invalid inputs, boundary values, and every public error variant. Test the negative space (inputs the API rejects) as exhaustively as the positive space.
- Allocation behavior, waiting behavior, invalidation, and ordering are testable contracts when public APIs expose them.
- Optimized structures should be compared against a simple reference model when practical.
- Layout and ABI properties belong in compile-time assertions colocated with the type; tests may add behavior coverage.
- Integration or target-specific checks must be gated when the required target, hardware, or permission is unavailable.
- Each non-trivial test opens with a one-line description of goal and methodology so a reviewer can skim the file.

## Agentic implementation workflow

Automated implementation agents must follow the same rules as human contributors.

- Read the owning spec and conventions before editing.
- Identify the module owner before adding code.
- Make the smallest complete change that satisfies the approved contract.
- Update every callsite; do not leave compatibility aliases unless explicitly requested.
- Add assertions where a new invariant is created and where it is consumed.
- Add or update tests for changed behavior.
- Do not land placeholders, fake fallbacks, TODOs, or speculative extension points.
- Do not invent unresolved contracts. Resolve the contract first.
