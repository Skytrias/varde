# Varde agent guide

## Purpose

Varde is an experimental, standalone Odin documentation toolchain. It can
consume compatible `.odin-doc` artifacts or extract a limited subset of source
facts, then generate an offline static API site.

The project is AI-authored and maintainer-directed. Keep public-facing text
accurate about that provenance and about the tool's experimental status.

## Current shape

- `runtime/varde.odin` owns static-site generation and project configuration.
- `runtime/markup.odin` parses safe documentation markup.
- `doc_format` owns an allocated, validated `.odin-doc` reader/writer and
  deterministic multi-document merge.
- `extractor` provides the focused compiler-free source discovery, parsing,
  and lowering path.
- `runtime/runtime.odin` exposes the in-process `Runtime_Build` façade; `cli/main.odin`
  is a thin caller of it.

Source mode is incomplete by design. It must report unknown semantic facts and
require `--allow-incomplete` before emitting a source-derived artifact or site.
Do not describe it as compiler-equivalent.

## Non-negotiable boundaries

- Varde source mode must not invoke, download, bundle, or discover an Odin
  executable. Odin is a development and Varde-build dependency only.
- `.odin-doc` compatibility follows the public
  `core:odin/doc-format` specification. Do not invent a Varde-private binary
  replacement.
- Validate untrusted document inputs before dereferencing: magic, version,
  sizes, offsets, bounds, hashes, and local indices.
- Keep parsed document data owned. Never retain pointers into input buffers.
- Preserve document-local index identity through normalization. Merge packages
  deterministically by canonical path; prefer more public entries and preserve
  the earlier input on a tie.
- Generated sites must work from `file://`, offline, without a server, CDN, or
  browser fetch requirement.

## Source and licensing

`doc_format/doc_format.odin` includes modified/adapted material from
Odin's public doc-format source. Preserve its attribution comment and the
notice in `THIRD_PARTY_NOTICES.md`. Varde uses the zlib license in `LICENSE`.

Do not add compiler binaries, Odin source trees, built sites, generated
`.odin-doc` artifacts, or local editor files to Git. Root `docs/` is local and
ignored; generated CI and preview output is also ignored.

## Working conventions

- Keep extraction, normalization, and rendering independent. The CLI and
  embedding APIs call library layers rather than reimplementing them.
- Keep allocation ownership explicit and match every allocation with cleanup
  consistent with nearby Odin code.
- Preserve declaration order, source positions, flags, attributes,
  aliases/re-exports, and structured type information when the source supports
  it. Do not fabricate unavailable facts.
- Treat documentation comments as authored prose. Do not rewrite paths within
  them.
- Do not restore ignored documentation or build output to the public repository
  without an explicit maintainer decision.

## Verification

Run these after relevant changes:

```sh
make test
make build-cli
./dist/varde build --source . --allow-incomplete --out .varde-preview/site
make preview PREVIEW_PORT=8787
make preview-watch
```

The final command succeeds with expected diagnostics while source mode remains
incomplete. Confirm the generated `index.html` and `varde-site-manifest.json`
exist before treating it as a successful site build.
