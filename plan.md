# Varde: native Odin documentation extraction plan

## Purpose

Varde is becoming a standalone documentation toolchain, not merely Vigil's
static-site exporter.

The intended product pipeline is:

```text
Odin workspace
    │
    ▼
Varde native extractor
    │
    ├── compatible `.odin-doc` artifact (optional but first-class)
    └── normalized Varde render model
                 │
                 ▼
        file://-safe static API site
```

Varde must not invoke, download, bundle, or otherwise depend on an `odin`
executable for its source-workspace mode. A prebuilt `.odin-doc` remains a
fully supported alternative input for users who already produce one with Odin
or another compatible producer.

This document is deliberately a handoff plan. The extractor is a compiler
adjacent project and should be developed independently from Vigil's desktop
release cadence.

## Implementation status — 2026-08-17

The roadmap below remains authoritative. The following is the current
implementation snapshot, so supported behavior and remaining work are visible
without treating planned milestones as completed work.

| Milestone | Status | Delivered | Still required |
| --- | --- | --- | --- |
| M0 — project boundary | Partial | Standalone Varde workspace, no-Odin-exec boundary, and ADRs for parser ownership and the compatibility window. | Independent release metadata and compatibility table. |
| M1 — doc-format input and merge | Substantially implemented | Strict owned 0.3.2 reader/writer, validation, deterministic merge, `inspect`, and `build --doc`. | Retained compiler-produced fixtures and differential conformance tests. |
| M2 — structured renderer | Partial | Doc-workspace adapter, offline static renderer, markup, semantic code links where resolvable, source links, expandable package navigation, search, reader presentation settings, trusted project insertion slots, and workspace-relative file labels. | Complete structured type coverage, aliases/re-exports, machine data, and output comparison with upstream sites. |
| M3 — native parser and graph | Partial | Compiler-free discovery, file tags, comments/positions, focused top-level parsing, imports, package graphing, and diagnostics. | Full Odin syntax/attributes/visibility and complete collection/import semantics. |
| M4 — semantic extraction and writer | Experimental partial | A source lowerer can write valid 0.3.2 artifacts for established facts; unresolved facts diagnose and require `--allow-incomplete` to emit. | Documentation-focused resolver/checker, cross-package type resolution, broad type/declaration support, and differential testing. |
| M5 — Vigil and CI integration | Partial | `Runtime_Build` owns source/document input, site generation, optional sidecar emission, and structured owned results; the CLI delegates to it. | Vigil worker integration, published Varde-only binaries, CI templates, and measured migration from Vigil's bridge. |
| M6 — developer preview server | Deferred | `make preview` produces an ignored local output and serves it with Python. | A loopback-only native `varde serve` command after Odin provides sufficient HTTP primitives. |

### Current supported commands

```sh
make test
make build-cli
./dist/varde inspect project.odin-doc
./dist/varde scan --source . --target-os linux --target-arch amd64
./dist/varde extract --source . --out build/project.odin-doc --allow-incomplete
./dist/varde build --doc project.odin-doc --workspace . --out dist/varde
./dist/varde build --source . --allow-incomplete --out dist/varde --emit-doc build/project.odin-doc
```

`--allow-incomplete` is intentional: source mode does not yet claim compiler
parity. Without that opt-in, Varde refuses to write a document or build a site
when semantic diagnostics remain.

## Why this is a real extractor, not a formatter

The current Odin compiler's `doc` command establishes the required bar:

1. It parses the initial package and reachable imports (`parse_packages`).
2. It initializes the normal compiler checker.
3. It type-checks all parsed files (`check_parsed_files`).
4. It calls `generate_documentation` only after that succeeds.
5. With `-doc-format`, it serializes the resulting `CheckerInfo` through the
   compiler's `odin_doc_write` implementation.

The writer therefore has resolved package ownership, type graphs, source
positions, procedure groups, declaration flags, attributes, and public scopes.
It is not possible to achieve equivalent output by merely scanning comments or
printing parsed declarations.

Relevant Odin sources in the current development checkout:

- `src/main.cpp`: command dispatch, parsing, and checker invocation.
- `src/docs.cpp`: `generate_documentation` dispatch.
- `src/docs_writer.cpp`: construction of the binary doc records.
- `core/odin/doc-format/doc_format.odin`: public, versioned binary format
  reader/specification.

Vigil's existing `src/docs` scanner remains useful for the native local
browser, but it is not a replacement for this semantic extractor. It is a
temporary publishing bridge until Varde source mode is complete.

## Product contract

### CLI modes

The current standalone CLI makes the data source explicit. Until M4 reaches
semantic parity, source commands that report unresolved facts require the
explicit `--allow-incomplete` opt-in:

```sh
# Native extraction and site build. No Odin executable involved.
varde build --source . --allow-incomplete

# Generate a reusable standard document artifact only.
varde extract --source . --out build/project.odin-doc --allow-incomplete

# Build directly from one or more compatible artifacts.
varde build --doc build/project.odin-doc
varde build --doc core.odin-doc --doc vendor.odin-doc

# Native source build while retaining the generated artifact.
varde build --source . --allow-incomplete --emit-doc build/project.odin-doc
```

`build --source` may use a configured documentation entry package rather than
blindly treating the workspace root as a single package. This covers the common
`examples/all`/aggregate-entry style used by Odin projects.

### Configuration

`varde.json` remains site configuration, but later schema versions should add
source extraction and collection metadata. The exact JSON shape should be
validated before freezing it; the intended concepts are:

```jsonc
{
  "source": {
    "entry": "docs/all.odin",
    "all_packages": true,
    "target_os": "",
    "target_arch": "",
    "defines": {}
  },
  "collections": [
    {
      "name": "project",
      "root_path": ".",
      "route_prefix": "",
      "source_url": "https://github.com/example/project/tree/main"
    }
  ]
}
```

Collections are Varde metadata, not part of `.odin-doc`. They map absolute or
workspace paths to routes, navigation roots, and source URLs. They replace the
current single `source_url_prefix` once the doc-format adapter lands.

### Compatibility commitment

- Read the public `core:odin/doc-format` format strictly, including magic,
  size, hash, and version checks.
- Write a compatible `.odin-doc` artifact for the supported upstream format
  version, not a Varde-private substitute.
- Record Varde version, doc-format version, extraction options, and input
  hashes in the Varde site manifest.
- Reject unsupported format versions with a clear upgrade/downgrade message.
- Treat the public doc-format source as the compatibility specification; add
  conformance fixtures whenever it changes upstream.

## Architecture

### 1. `format`: safe read, normalize, and write

Start here. This layer has no parser or renderer dependency.

Responsibilities:

- Read one `.odin-doc` byte buffer with the upstream reader contract.
- Validate magic, declared total size, header size, bounds of every offset and
  array, and the format version before dereferencing records. The upstream
  `read_from_bytes` check is necessary but Varde should add defensive bounds
  validation before consuming untrusted CI inputs.
- Convert offset-backed records into owned Varde values. Never allow pointers
  into an input byte slice to escape the reader lifetime.
- Preserve source-document identity and local indices during normalization so
  a type/entity reference can always be resolved to its origin document.
- Write the public `.odin-doc` layout from extracted semantic data, including
  alignment, sentinel index zero, offsets, string interning, and data hash.

Suggested initial source files after Varde is split from Vigil:

```text
varde/
  format_reader.odin
  format_validate.odin
  format_writer.odin
  normalized_model.odin
```

Do not use the existing site `Model` as the only normalized form. It is a
rendering-shaped model and currently loses structured types, entity flags,
attributes, grouped procedures, and source-document identity. Introduce a
richer `Document`/`Workspace` model first, then derive the renderer's model.

### 2. Multi-document merge

Varde must accept several `.odin-doc` files and produce one deterministic
workspace. Match the useful behavior of `pkg.odin-lang.org`:

- Input order is stable and observable.
- Package identity is canonical full path.
- Duplicate packages are resolved by the largest public-entry count.
- Equal counts keep the earlier input, not map iteration order.
- Each selected package keeps its origin document for local type/entity/file
  lookup.
- Rebuild global package, entity, and type maps only after deduplication.
- Report duplicate choices and conflicting package metadata in diagnostics.

The merge must not mix raw numeric indexes from separate files: every index in
the upstream format is document-local.

### 3. Native source extractor

This is the substantial work. It replaces the extraction portion of
`odin doc`, not the site renderer.

The extractor needs these phases:

1. **Workspace and collection resolution**
   - Resolve the configured entry, workspace-relative imports, named
     collections, and package roots deterministically.
   - Normalize paths and avoid implicit network access.
   - Implement source file selection and platform/file-tag filtering.

2. **Lexer and parser**
   - Reuse appropriate public Odin core parser/tokenizer code only where its
     APIs are sufficient and licensing/maintenance permits it; otherwise keep
     the Varde parser isolated behind its own AST.
   - Preserve exact source offsets, line/column positions, comments,
     attributes, package declarations, imports, and declaration ordering.

3. **Package graph and scopes**
   - Build imports, aliases, package scopes, exports/re-exports, foreign
     libraries, init/runtime/builtin package distinctions, and visibility.
   - Detect cycles and produce actionable source diagnostics.

4. **Documentation-oriented semantic analysis**
   - Resolve named types and type expressions across packages.
   - Build the type graph needed by the public doc format: procedures,
     parameters/results, structs, unions, enums, bit sets, arrays, maps,
     pointers, SIMD/SOA, polymorphic parameters, tags, and where clauses.
   - Populate declaration flags and source ownership correctly.
   - Keep this phase deliberately documentation-focused, but do not silently
     manufacture type information when resolution fails. Surface a diagnostic
     and support explicit incomplete-document policy only if it is designed and
     tested.

5. **Public document serialization**
   - Emit the standardized doc-format artifact through `format_writer`.
   - Feed the same owned normalized model to the Varde renderer. Do not parse
     Varde's freshly written artifact merely to render it.

The source extractor should be written as a library API, with the CLI and
Vigil Publish scene acting as thin callers. It must not know about HTML, MVG,
Corbel, or desktop UI state.

### 4. Renderer adapter

The existing static builder becomes a consumer of the richer normalized model.
Its required upgrades are:

- Render all declaration signatures from structured types rather than a flat
  signature string.
- Emit semantic spans for Odin syntax and links for resolvable named types,
  parameters, and declarations.
- Preserve public declaration aliases/re-exports with stable anchors.
- Generate source URLs through collection root/source mappings.
- Build package navigation from collection/package paths.
- Keep the generated browser runtime free of fetches so `file://` continues to
  work.
- Continue generating `assets/search-index.js`; optionally emit a
  machine-readable `varde-data.json`, but do not make JSON fetching a runtime
  requirement.

The current Varde markup renderer remains responsible for presentation of docs
text. `.odin-doc` carries documentation strings, not a markup AST.

### 5. Imports and file metadata

The upstream document format records files and package membership, and it has
an `Import_Name` entity kind. It does **not** provide a website-ready imports
list. The existing `pkg.odin-lang.org` generator excludes import/library
entities from normal declaration rendering and does not generate an imports
section.

Varde may provide an imports panel only from the native extractor's package
graph. It must be identified as enrichment, not reconstructed from a supplied
`.odin-doc`. For pure doc-file input, omit that panel gracefully.

The same policy applies to SLOC and file-level overview metadata: generate
them during native extraction when available, but do not require or fabricate
them for imported doc artifacts.

## Milestones

### M0 — extraction project boundary

- Move Varde into its own repository/workspace while keeping `shared:varde`
  as Vigil's temporary pinned dependency.
- Preserve the existing renderer and its tests unchanged.
- Establish an independent release version and a compatibility table.
- Add this plan and an architecture decision record naming the no-Odin-exec
  rule.

### M1 — doc-format input and merge

- Implement the safe reader and owned normalized document model.
- Implement deterministic multi-document merge.
- Adapt the existing static renderer to a doc-format-derived model while
  retaining the Vigil snapshot adapter temporarily.
- Add `varde build --doc` with repeated inputs.
- Add tests using real compiler-produced fixtures from several Odin versions.

The implemented portion of this milestone already produces a useful independent
CI tool for projects that generate `.odin-doc` elsewhere.

### M2 — structured declaration renderer

- Replace flat declaration signatures with a complete structured type printer.
- Add semantic classes, cross-package links, re-export handling, source links,
  related procedure groups, package/sidebar data, and machine data output.
- Compare representative output against the existing `pkg.odin-lang.org`
  project and current Odin core docs.

### M3 — native parser and graph

- Implement source discovery, file tags, lexing/parsing, import resolution,
  package graphing, comments, positions, and declarations.
- Use a focused corpus before attempting full semantic type resolution.
- Make source extraction diagnostics a stable public CLI interface.

### M4 — semantic extraction and compatible writer

- Implement the documentation-required type resolver/checker.
- Emit valid `.odin-doc` and validate it using the upstream format reader.
- Differential-test Varde-generated output against Odin-generated output for
  supported fixture programs.
- Add `varde extract` and `varde build --source`.

### M5 — Vigil and CI integration

- Keep `Runtime_Build_Request`/`Runtime_Build_Result` as the stable owned
  in-process consumer boundary: site directory, optional compatible
  `.odin-doc` sidecar, diagnostics, counts, completion, cancellation, and
  output paths without spawning the CLI.
- Change Vigil Publish to call Varde's source/document API on its dedicated
  worker and display extraction/build diagnostics.
- Retire the desktop snapshot publishing bridge only after parity is measured.
- Publish platform-specific Varde CLI binaries; they contain Varde only, not
  Odin.
- Provide a GitHub Action/template that downloads Varde, checks out source,
  and runs native source mode.

The executable-distribution design, Linux ABI policy proposal, CI separation,
release-integrity requirements, and staged delivery gates live in
[docs/executable-distribution.md](docs/executable-distribution.md). The first
release target is intentionally Linux amd64 only; do not call a GitHub-runner
binary portable until it has been built and executed against its recorded ABI
baseline.

### M6 — developer preview server (deferred)

- Keep `make preview` as the intentionally small local workflow: build to an
  ignored `.varde-preview/` directory and serve it with Python on loopback.
- Do not add a third-party server or watcher dependency to Varde.
- Once Odin has a practical HTTP foundation, add an optional `varde serve`
  command that calls the build library directly, serves the last successful
  staged output, and reloads local clients after a successful rebuild.
- Scope server and reload behavior to development only. Generated output must
  still open offline from `file://` with no fetch, server, or CDN dependency.

## Test and conformance strategy

### Fixture corpus

Maintain checked-in, small fixtures covering:

- nested and multi-collection package layouts;
- imports, aliases, re-exports, import cycles, and unresolved imports;
- every public entity kind and flag;
- every public type kind and relevant type flag;
- generic/polymorphic declarations, where clauses, procedure groups, foreign
  declarations, attributes, Unicode, and hostile documentation text;
- file tags/platform variants and source positions;
- duplicate packages across separate doc-format inputs.

For each fixture, retain both an Odin-produced reference `.odin-doc` and
expected normalized/rendered assertions where licensing and fixture size allow.

### Required checks

- Parse every accepted doc artifact with Varde and, where possible, Odin's
  `core:odin/doc-format` reader.
- Ensure Varde-written artifacts are accepted by the upstream reader.
- Differential-test normalized package/entity/type shape against Odin output.
- Assert every generated internal link, source link, route, anchor, and search
  target exists.
- Test multi-input merge determinism under shuffled input ordering and equal
  duplicate counts.
- Test malformed/truncated/hostile binary input without out-of-bounds reads.
- Run static sites directly through `file://`, offline, and under a normal
  static server.
- Benchmark parsing, semantic analysis, normalization, and rendering
  separately; do not hide a slow extractor behind UI worker threads.

## Non-goals and decision gates

- Do not call an Odin executable from Varde source mode.
- Do not ship a hidden Odin executable/toolchain as a workaround.
- Do not claim full compiler compatibility before the differential suite passes.
- Do not make static-site browsing depend on server-side APIs, fetch, or a CDN.
- Do not replace Vigil's native documentation browser as part of the initial
  extractor work.

The parser-ownership decision is complete: Varde owns its parser and does not
invoke an Odin executable (ADR 0001). The narrow initial doc-format window is
also complete: Varde reads and writes 0.3.2 (ADR 0002). The remaining M4
decision is when the incomplete-output opt-in can be removed; that requires a
documented semantic subset and the differential suite, not just successful
serialization of a partial artifact.

## Handoff checklist

1. Create the standalone Varde repository from `shared/varde`.
2. Copy this plan and the relevant Varde renderer tests.
3. Add a tracked upstream Odin revision and doc-format compatibility version.
4. Implement M1 before changing Vigil's Publish behavior.
5. Keep Vigil consuming pinned Varde releases/commits through a thin adapter.
