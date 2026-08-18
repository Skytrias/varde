# `.odin-doc` generation conformance

## Objective

Varde should produce source-derived `.odin-doc` artifacts that are as close as
practicable to the Odin compiler's public documentation output, while keeping
Varde source mode entirely compiler-free at runtime.

The Odin compiler is a **test-only reference producer**. It is never invoked,
downloaded, discovered, or bundled by Varde's source extraction path.

The aim is semantic conformance, not accidental byte identity. Binary offsets,
string-table placement, allocation order, and other layout choices are writer
implementation details. We compare parsed public records, edges, ordering, and
rendered meaning instead.

## What counts as conformant

For a supported fixture and fixed target configuration, Varde must produce a
parsed document equivalent to its reference artifact with respect to:

- package identity, flags, docs, files, and public scope order;
- declaration kind, name, flags, source position, comments, docs,
  initializer, attributes, links, groups, and where clauses;
- the complete structural type graph, including type flags, element counts,
  calling convention, polymorphic parameters, tags, and local edges;
- aliases, re-exports, imports, foreign libraries, visibility, and package
  ownership where the public format represents them; and
- deterministic output for the same source and configuration.

An unsupported source form must produce a precise diagnostic and an
incomplete result. It must never be silently approximated as a different
semantic construct.

## The differential loop

```text
fixture source + target manifest
        │
        ├── reference-only: Odin compiler ──> reference.odin-doc
        │                                      │
        │                                      ▼
        └── Varde source extractor ───────> varde.odin-doc
                                               │
                         Varde public reader ──┴──> canonical semantic diff
                                                        │
                                            focused fixture + regression test
```

1. Add the smallest fixture that exercises one language or doc-format fact.
2. Generate and retain a compiler-produced reference artifact outside Varde's
   runtime path. Record its compiler revision, command, target OS/architecture,
   collection mapping, and source hash in the fixture manifest.
3. Generate Varde's artifact from exactly the same fixture and target.
4. Parse both using Varde's owned public format reader. Convert each document
   to a deterministic, index-free comparison view that retains declaration and
   scope order while replacing local indices with canonical record paths.
5. Diff every public field. The report must name the source fixture, document
   path, field, expected value, and actual value.
6. Fix the smallest responsible parser, resolver, lowerer, writer, or renderer
   layer; add the fixture to the permanent regression corpus.

The canonical comparison must not sort declarations or scope entries: their
order is observable output. It may canonicalize only implementation-local
offsets and index numbers after preserving the graph edges they denote.

## Renderer check: secondary but useful

After the semantic diff passes, build two Varde sites:

1. one from `reference.odin-doc`; and
2. one from Varde's source-derived artifact.

Compare normalized page structure, entry anchors, signatures, links, search
records, and source locations. This isolates renderer behavior from extraction:
if the reference artifact renders incorrectly, it is a renderer defect; if the
two sites differ after normalization, it is usually a source-document defect.

Pixel comparison is optional visual QA, not the primary oracle. It is too
fragile for typography, browser, and styling changes to serve as the semantic
gate.

## Self-improvement loop

The conformance corpus is the feedback loop for development. It must turn each
observed discrepancy into a small, reproducible unit of work instead of asking
an implementer to broadly “make Varde more compiler-like”.

For every differential run:

1. Produce a machine-readable mismatch report grouped by doc-format field and
   source construct, with the smallest failing fixture first.
2. Classify each group as a parser loss, source-model loss, resolver/lowerer
   loss, writer loss, renderer loss, intentionally unsupported behavior, or a
   reference-corpus change.
3. Select one group whose required facts are available without compiler
   execution. Add or reduce it to one focused fixture before changing code.
4. Implement the narrowest layer that can preserve the missing fact; do not
   patch a rendered string to hide a document mismatch.
5. Run the full semantic corpus, deterministic-output check, and paired-site
   comparison. A new mismatch is a regression unless explicitly classified.
6. Keep the new fixture and its reference artifact permanently. Only then mark
   the capability supported and permit it to contribute to a complete result.

The loop should report progress as coverage, not an ungrounded confidence
score: for example, “12/12 map fixtures match; maps may now be enabled”, or
“procedure attributes remain unsupported in 4 fixtures.” A compact coverage
ledger should list every source construct, its fixture count, status, owner
layer, and first known mismatch.

Automation can generate candidate fixtures, run the reference producer in CI,
shrink a failing source case, and summarize diffs. It must not automatically
bless a new reference artifact, reclassify a failure as supported, or suppress
a mismatch. Those are maintainer decisions because they change Varde's public
truthfulness contract.

## Fixture corpus

Keep compact, source-controlled fixtures grouped by capability. The generated
reference `.odin-doc` files belong under `fixtures/` and are explicitly
allowlisted by `.gitignore`; arbitrary local output does not belong in Git.

Each fixture needs a manifest with target settings, reference provenance, and
one status:

- `match` — expected to be exactly semantically equivalent;
- `unsupported` — Varde must reject without `--allow-incomplete` and report
  the documented diagnostic; or
- `compiler-required` — the source fact cannot be established by the current
  documentation-focused resolver and must remain explicit.

Start with one fixture per item, then add interaction fixtures only after the
isolated cases pass:

1. packages, file tags, docs/comments, imports, aliases, visibility, and
   declaration order;
2. constants, variables, named types, aliases, structs, unions, enums, bit
   sets, and bit fields;
3. every type constructor: pointers, arrays, maps, procedure types,
   dynamic/fixed-capacity arrays, SIMD/SOA, relative pointers, and matrices;
4. procedures: parameters, multiple/named results, defaults, calling
   conventions, `where` clauses, attributes, procedure groups, and foreign
   declarations;
5. cross-package definitions, re-exports, generic/polymorphic declarations,
   and collection imports; and
6. malformed input, duplicate names, cyclic imports, conditional files, and
   intentionally unresolved expressions.

## Immediate correctness work

Before expanding the corpus, fix the completeness contract:

- extraction and graph diagnostics that invalidate the discovered workspace
  must make the build incomplete, not merely print beside a “complete” result;
- `--allow-incomplete` must be required for every such source-derived result;
- diagnostics must remain structured and source-positioned through the runtime
  API and CLI.

Then populate existing doc-format fields that are source-syntactic rather than
compiler-dependent: attributes, flags/visibility, comments, import entities,
aliases, foreign metadata, grouped fields, procedure metadata, and type
constructor structure.

## Guardrails

- Do not compare raw bytes as the pass criterion.
- Do not use the Odin compiler in Varde runtime code, examples, or generated
  sites. Reference generation belongs only to an explicit development/CI task.
- Do not bless a diff by omitting a field. Every omission needs an
  `unsupported` or `compiler-required` fixture status and a reason.
- Pin reference provenance. A compiler upgrade is a deliberate corpus update,
  reviewed separately from extractor changes.
- Run the corpus in CI where a pinned reference compiler is available; retain
  the checked-in artifacts so ordinary Varde tests remain runnable without it.

## Definition of “really close”

Varde is close enough to remove `--allow-incomplete` for a fixture category
only when every `match` fixture in that category has a clean semantic diff,
both artifacts render to equivalent normalized Varde sites, and the category
has negative tests proving unsupported facts are rejected rather than guessed.

Compiler-equivalent documentation for arbitrary Odin projects is a later goal.
The immediate standard is more useful and auditable: exact public artifact
semantics for each claimed source subset, with honest diagnostics everywhere
else.
