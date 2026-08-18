package doc_format

import "core:testing"
import upstream "core:odin/doc-format"

merge_test_document :: proc(entry_count: int) -> Document {
	document := Document_Init()
	pkg := Package{fullpath = "/workspace/example", name = "example", files = make([dynamic]u32, 0), entries = make([dynamic]Scope_Entry, 0, entry_count)}
	for index in 0 ..< entry_count do append(&pkg.entries, Scope_Entry{name = "entry", entity = 0})
	append(&document.packages, pkg)
	return document
}

@(test)
test_document_round_trips_through_compatible_wire_layout :: proc(t: ^testing.T) {
	document := Document_Init()
	defer Document_Destroy(&document)
	append(&document.files, File{pkg = 1, name = "/work/demo/main.odin"})
	pkg := Package{fullpath = "/work/demo", name = "demo", docs = "Demo package.", files = make([dynamic]u32, 0, 1), entries = make([dynamic]Scope_Entry, 0, 1)}
	append(&pkg.files, 1)
	append(&pkg.entries, Scope_Entry{name = "Answer", entity = 1})
	append(&document.packages, pkg)
	entity := Entity{kind = 1, pos = {file = 1, line = 3, column = 1, offset = 24}, name = "Answer", type = 1, init_string = "42", docs = "The answer.", attributes = make([dynamic]Attribute, 0, 1), grouped_entities = make([dynamic]u32, 0), where_clauses = make([dynamic]string, 0)}
	append(&entity.attributes, Attribute{name = "deprecated", value = "use Question"})
	append(&document.entities, entity)
	typ := Type{kind = 1, name = "int", types = make([dynamic]u32, 0), entities = make([dynamic]u32, 0), where_clauses = make([dynamic]string, 0), tags = make([dynamic]string, 0)}
	append(&document.types, typ)
	data, write_err := Write(&document)
	defer delete(data)
	testing.expect(t, write_err.kind == .None && len(data) > HEADER_SIZE, "writer should produce a document")
	parsed, read_err := Read(data[:])
	defer Document_Destroy(&parsed)
	testing.expect(t, read_err.kind == .None, error_string(read_err))
	testing.expect(t, len(parsed.packages) == 2 && parsed.packages[1].name == "demo", "package data should survive a round trip")
	testing.expect(t, len(parsed.entities) == 2 && parsed.entities[1].attributes[0].value == "use Question", "entity attributes should survive a round trip")
	testing.expect(t, parsed.types[1].name == "int" && parsed.entities[1].pos.line == 3, "type and source positions should survive a round trip")
	upstream_header, upstream_err := upstream.read_from_bytes(data[:])
	testing.expect(t, upstream_err == .None && upstream_header != nil, "Varde bytes should be accepted by the upstream doc-format reader")
}

@(test)
test_reader_rejects_tampered_headers :: proc(t: ^testing.T) {
	document := Document_Init()
	defer Document_Destroy(&document)
	data, err := Write(&document)
	defer delete(data)
	testing.expect(t, err.kind == .None, "empty sentinel document should be writable")
	data[64] = 0xff
	_, format_err := Read(data[:])
	testing.expect(t, format_err.kind == .Invalid_Hash, "tampered bytes should fail hash validation before dereference")
}

@(test)
test_merge_selects_the_richer_duplicate_and_keeps_origin_indices :: proc(t: ^testing.T) {
	first := merge_test_document(1)
	second := merge_test_document(2)
	defer Document_Destroy(&first)
	defer Document_Destroy(&second)
	documents := [2]^Document{&first, &second}
	workspace, err := Merge(documents[:])
	defer Workspace_Destroy(&workspace)
	testing.expect(t, err.kind == .None && len(workspace.packages) == 1, "merge should choose one package per canonical path")
	testing.expect(t, workspace.packages[0].document_index == 1 && workspace.packages[0].package_index == 1, "the richer duplicate should retain its own local package index")
	testing.expect(t, len(workspace.diagnostics) == 1 && workspace.diagnostics[0].discarded_document_index == 0, "duplicate selection should be observable")
}

@(test)
test_merge_keeps_the_first_duplicate_on_equal_public_entry_counts :: proc(t: ^testing.T) {
	first := merge_test_document(1)
	second := merge_test_document(1)
	defer Document_Destroy(&first)
	defer Document_Destroy(&second)
	documents := [2]^Document{&first, &second}
	workspace, err := Merge(documents[:])
	defer Workspace_Destroy(&workspace)
	testing.expect(t, err.kind == .None && workspace.packages[0].document_index == 0, "equal duplicate packages should preserve stable input order")
}
