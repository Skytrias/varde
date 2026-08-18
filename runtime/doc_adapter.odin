package varde

import "core:mem"
import "core:strings"
import "core:testing"
import "core:fmt"
import "core:path/filepath"
import doc "../doc_format"

// Document_Model is the short-lived renderer adapter for one merged set of
// .odin-doc inputs. It borrows semantic strings from the source documents and
// owns only routes and generated signature strings.
Document_Model :: struct {
	model:          Model,
	_owned_strings: [dynamic]string,
}

Document_Model_Destroy :: proc(adapter: ^Document_Model, allocator: mem.Allocator = context.allocator) {
	if adapter == nil do return
	for &pkg in adapter.model.packages {
		for &file in pkg.files do delete(file.entries)
		delete(pkg.files)
	}
	delete(adapter.model.packages)
	for value in adapter._owned_strings do if len(value) > 0 do delete(value, allocator)
	delete(adapter._owned_strings)
	adapter^ = {}
}

document_model_own :: proc(adapter: ^Document_Model, value: string, allocator: mem.Allocator) -> string {
	if len(value) == 0 do return ""
	owned := strings.clone(value, allocator)
	append(&adapter._owned_strings, owned)
	return owned
}

document_route_path :: proc(adapter: ^Document_Model, fullpath, fallback: string, allocator: mem.Allocator) -> string {
	builder: strings.Builder
	defer strings.builder_destroy(&builder)
	started := false
	last_separator := false
	for ch in fullpath {
		if ch == '/' || ch == '\\' {
			if started && !last_separator {
				strings.write_rune(&builder, '/')
				last_separator = true
			}
			continue
		}
		if ('a' <= ch && ch <= 'z') || ('A' <= ch && ch <= 'Z') || ('0' <= ch && ch <= '9') || ch == '-' || ch == '_' {
			strings.write_rune(&builder, ch)
		} else {
			strings.write_rune(&builder, '_')
		}
		started = true
		last_separator = false
	}
	route := strings.to_string(builder)
	for len(route) > 0 && route[len(route)-1] == '/' do route = route[:len(route)-1]
	if len(route) == 0 do route = fallback
	if len(route) == 0 do route = "package"
	return document_model_own(adapter, route, allocator)
}

// Package identity in .odin-doc is an absolute canonical path. Display routes
// are instead relative to the selected workspace whenever that is safe; this
// keeps local machine folders out of navigation and generated URLs.
document_workspace_route_path :: proc(adapter: ^Document_Model, workspace_path, fullpath, fallback: string, allocator: mem.Allocator) -> string {
	if len(workspace_path) > 0 {
		workspace_base := workspace_path_relative_base(workspace_path, context.temp_allocator)
		relative, err := filepath.rel(workspace_base, fullpath, context.temp_allocator)
		if err == nil && relative != ".." && !strings.has_prefix(relative, "../") && !strings.has_prefix(relative, "..\\") {
			if relative == "." do return document_route_path(adapter, "", fallback, allocator)
			return document_route_path(adapter, relative, fallback, allocator)
		}
	}
	return document_route_path(adapter, fullpath, fallback, allocator)
}

document_entity_kind :: proc(kind: u32) -> string {
	switch kind {
	case 1: return "Constants"
	case 2: return "Variables"
	case 3: return "Types"
	case 4: return "Procedures"
	case 5: return "Procedure Groups"
	case 6: return "Imports"
	case 7: return "Libraries"
	case 8: return "Builtins"
	}
	return "Declarations"
}

document_type_at :: proc(document: ^doc.Document, typ: doc.Type, index: int) -> u32 {
	if document == nil || index < 0 || index >= len(typ.types) do return 0
	return typ.types[index]
}

// Keep one hostile declaration from amplifying an artifact indefinitely, but
// leave enough room for ordinary records with field documentation.
DOCUMENT_SIGNATURE_MAX_BYTES :: 16 * 1024

Document_Signature_Budget :: struct {
	remaining: int,
	truncated: bool,
}

// Signatures are display summaries, not a transport for arbitrarily large
// initializers or anonymous type graphs. Bound them while constructing the
// renderer model so the HTML page and search index cannot amplify one input.
document_signature_write :: proc(builder: ^strings.Builder, budget: ^Document_Signature_Budget, value: string) {
	if budget.truncated || len(value) == 0 do return
	if len(value) <= budget.remaining {
		strings.write_string(builder, value)
		budget.remaining -= len(value)
		return
	}
	if budget.remaining > len("…") {
		strings.write_string(builder, value[:budget.remaining-len("…")])
		strings.write_string(builder, "…")
	}
	budget.remaining = 0
	budget.truncated = true
}

document_signature_write_int :: proc(builder: ^strings.Builder, budget: ^Document_Signature_Budget, value: int) {
	document_signature_write(builder, budget, fmt.tprintf("%d", value))
}

@(test)
test_document_signature_budget_truncates_unbounded_input :: proc(t: ^testing.T) {
	builder: strings.Builder
	defer strings.builder_destroy(&builder)
	budget := Document_Signature_Budget{remaining = 4}
	document_signature_write(&builder, &budget, "abcdef")
	testing.expect(t, strings.to_string(builder) == "a…" && budget.truncated, "signature rendering should stop at its display budget")
}

document_signature_indent :: proc(builder: ^strings.Builder, budget: ^Document_Signature_Budget, indent: int) {
	for _ in 0..<indent do document_signature_write(builder, budget, "\t")
}

document_signature_write_docs :: proc(builder: ^strings.Builder, budget: ^Document_Signature_Budget, docs: string, indent: int) {
	remaining := strings.trim_right_space(docs)
	for len(remaining) > 0 && !budget.truncated {
		line, _, tail := strings.partition(remaining, "\n")
		document_signature_indent(builder, budget, indent)
		document_signature_write(builder, budget, "// ")
		document_signature_write(builder, budget, strings.trim_right_space(line))
		document_signature_write(builder, budget, "\n")
		remaining = tail
	}
}

document_entity_name_width :: proc(document: ^doc.Document, values: []u32) -> int {
	if document == nil do return 0
	width := 0
	for entity_index in values {
		if entity_index > 0 && int(entity_index) < len(document.entities) do width = max(width, len(document.entities[entity_index].name))
	}
	return width
}

document_append_entities_inline :: proc(builder: ^strings.Builder, budget: ^Document_Signature_Budget, document: ^doc.Document, values: []u32, depth, indent: int) {
	for entity_index, index in values {
		if budget.truncated do break
		if index > 0 do document_signature_write(builder, budget, ", ")
		if document == nil || entity_index == 0 || int(entity_index) >= len(document.entities) {
			document_signature_write(builder, budget, "_")
			continue
		}
		entity := document.entities[entity_index]
		if len(entity.name) > 0 do document_signature_write(builder, budget, entity.name)
		if entity.type != 0 {
			if len(entity.name) > 0 do document_signature_write(builder, budget, ": ")
			document_append_type(builder, budget, document, entity.type, depth + 1, indent)
		}
		if len(entity.init_string) > 0 {
			document_signature_write(builder, budget, " = ")
			document_signature_write(builder, budget, entity.init_string)
		}
	}
}

document_append_record_entities :: proc(builder: ^strings.Builder, budget: ^Document_Signature_Budget, document: ^doc.Document, typ: doc.Type, depth, indent: int) {
	name_width := document_entity_name_width(document, typ.entities[:])
	for entity_index, index in typ.entities {
		if budget.truncated do break
		if entity_index == 0 || int(entity_index) >= len(document.entities) do continue
		entity := document.entities[entity_index]
		document_signature_write_docs(builder, budget, entity.docs, indent + 1)
		document_signature_indent(builder, budget, indent + 1)
		if len(entity.name) > 0 {
			document_signature_write(builder, budget, entity.name)
			document_signature_write(builder, budget, ": ")
			for _ in 0..<max(name_width-len(entity.name), 0) do document_signature_write(builder, budget, " ")
		}
		document_append_type(builder, budget, document, entity.type, depth + 1, indent + 1)
		if len(entity.init_string) > 0 {
			document_signature_write(builder, budget, " = ")
			document_signature_write(builder, budget, entity.init_string)
		}
		if index < len(typ.tags) && len(typ.tags[index]) > 0 {
			document_signature_write(builder, budget, " `")
			document_signature_write(builder, budget, typ.tags[index])
			document_signature_write(builder, budget, "`")
		}
		document_signature_write(builder, budget, ",\n")
	}
}

document_append_type_child :: proc(builder: ^strings.Builder, budget: ^Document_Signature_Budget, document: ^doc.Document, typ: doc.Type, index, depth, indent: int) {
	document_append_type(builder, budget, document, document_type_at(document, typ, index), depth + 1, indent)
}

document_append_type :: proc(builder: ^strings.Builder, budget: ^Document_Signature_Budget, document: ^doc.Document, type_index: u32, depth, indent: int) {
	if budget.truncated do return
	if document == nil || type_index == 0 || int(type_index) >= len(document.types) { document_signature_write(builder, budget, "_"); return }
	// Anonymous structural types can recursively embed other anonymous types.
	// Keep signatures finite and fast for large public APIs while retaining the
	// first several semantic layers that a reader needs to understand a type.
	if depth > 3 { document_signature_write(builder, budget, "…"); return }
	typ := document.types[type_index]
	switch typ.kind {
	case 1, 2, 3:
		if len(typ.name) > 0 { document_signature_write(builder, budget, typ.name) } else { document_signature_write(builder, budget, "_") }
	case 4: document_signature_write(builder, budget, "^"); document_append_type_child(builder, budget, document, typ, 0, depth, indent)
	case 22: document_signature_write(builder, budget, "[^]"); document_append_type_child(builder, budget, document, typ, 0, depth, indent)
	case 24: document_signature_write(builder, budget, "#soa^"); document_append_type_child(builder, budget, document, typ, 0, depth, indent)
	case 5:
		document_signature_write(builder, budget, "[")
		if len(typ.types) > 1 { document_append_type_child(builder, budget, document, typ, 1, depth, indent) } else { document_signature_write_int(builder, budget, int(typ.elem_counts[0])) }
		document_signature_write(builder, budget, "]"); document_append_type_child(builder, budget, document, typ, 0, depth, indent)
	case 6: document_signature_write(builder, budget, "["); document_append_type_child(builder, budget, document, typ, 0, depth, indent); document_signature_write(builder, budget, "]"); document_append_type_child(builder, budget, document, typ, 1, depth, indent)
	case 7: document_signature_write(builder, budget, "[]"); document_append_type_child(builder, budget, document, typ, 0, depth, indent)
	case 8: document_signature_write(builder, budget, "[dynamic]"); document_append_type_child(builder, budget, document, typ, 0, depth, indent)
	case 26:
		document_signature_write(builder, budget, "[dynamic; ")
		if len(typ.types) > 1 { document_append_type_child(builder, budget, document, typ, 1, depth, indent) } else { document_signature_write_int(builder, budget, int(typ.elem_counts[0])) }
		document_signature_write(builder, budget, "]"); document_append_type_child(builder, budget, document, typ, 0, depth, indent)
	case 9: document_signature_write(builder, budget, "map["); document_append_type_child(builder, budget, document, typ, 0, depth, indent); document_signature_write(builder, budget, "]"); document_append_type_child(builder, budget, document, typ, 1, depth, indent)
	case 10:
		document_signature_write(builder, budget, "struct")
		if typ.flags & (1 << 1) != 0 do document_signature_write(builder, budget, " #packed")
		if typ.flags & (1 << 2) != 0 do document_signature_write(builder, budget, " #raw_union")
		if len(typ.custom_align) > 0 { document_signature_write(builder, budget, " #align "); document_signature_write(builder, budget, typ.custom_align) }
		document_signature_write(builder, budget, " {")
		if len(typ.entities) > 0 { document_signature_write(builder, budget, "\n"); document_append_record_entities(builder, budget, document, typ, depth + 1, indent); document_signature_indent(builder, budget, indent) }
		document_signature_write(builder, budget, "}")
	case 11:
		document_signature_write(builder, budget, "union {")
		if len(typ.types) > 0 {
			document_signature_write(builder, budget, "\n")
			for child_index in typ.types { if budget.truncated do break; document_signature_indent(builder, budget, indent + 1); document_append_type(builder, budget, document, child_index, depth + 1, indent + 1); document_signature_write(builder, budget, ",\n") }
			document_signature_indent(builder, budget, indent)
		}
		document_signature_write(builder, budget, "}")
	case 12:
		document_signature_write(builder, budget, "enum")
		if len(typ.types) > 0 { document_signature_write(builder, budget, " "); document_append_type_child(builder, budget, document, typ, 0, depth, indent) }
		document_signature_write(builder, budget, " {")
		if len(typ.entities) > 0 { document_signature_write(builder, budget, "\n"); document_append_record_entities(builder, budget, document, typ, depth + 1, indent); document_signature_indent(builder, budget, indent) }
		document_signature_write(builder, budget, "}")
	case 13:
		document_signature_write(builder, budget, "(")
		if len(typ.entities) > 0 {
			if len(typ.entities) >= 6 {
				document_signature_write(builder, budget, "\n")
				document_append_record_entities(builder, budget, document, typ, depth + 1, indent)
				document_signature_indent(builder, budget, indent)
			} else {
				document_append_entities_inline(builder, budget, document, typ.entities[:], depth + 1, indent)
			}
		} else {
			for type_index, index in typ.types {
				if budget.truncated do break
				if index > 0 do document_signature_write(builder, budget, ", ")
				document_append_type(builder, budget, document, type_index, depth + 1, indent)
			}
		}
		document_signature_write(builder, budget, ")")
	case 14:
		document_signature_write(builder, budget, "proc")
		document_append_type_child(builder, budget, document, typ, 0, depth, indent)
		if len(typ.types) > 1 && document_type_at(document, typ, 1) != 0 { document_signature_write(builder, budget, " -> "); document_append_type_child(builder, budget, document, typ, 1, depth, indent) }
	case 15:
		document_signature_write(builder, budget, "bit_set["); document_append_type_child(builder, budget, document, typ, 0, depth, indent)
		if typ.elem_count_len > 0 { document_signature_write(builder, budget, "; "); document_signature_write_int(builder, budget, int(typ.elem_counts[0])); if typ.elem_count_len > 1 { document_signature_write(builder, budget, ".."); document_signature_write_int(builder, budget, int(typ.elem_counts[1])) } }
		document_signature_write(builder, budget, "]")
	case 16: document_signature_write(builder, budget, "#simd["); document_signature_write_int(builder, budget, int(typ.elem_counts[0])); document_signature_write(builder, budget, "]"); document_append_type_child(builder, budget, document, typ, 0, depth, indent)
	case 17, 18, 19: document_signature_write(builder, budget, "#soa"); document_append_type_child(builder, budget, document, typ, 0, depth, indent)
	case 20, 21: document_signature_write(builder, budget, "#relative"); document_append_type_child(builder, budget, document, typ, 0, depth, indent)
	case 23: document_signature_write(builder, budget, "matrix["); document_signature_write_int(builder, budget, int(typ.elem_counts[0])); document_signature_write(builder, budget, ", "); document_signature_write_int(builder, budget, int(typ.elem_counts[1])); document_signature_write(builder, budget, "]"); document_append_type_child(builder, budget, document, typ, 0, depth, indent)
	case 25: document_signature_write(builder, budget, "bit_field "); document_append_type_child(builder, budget, document, typ, 0, depth, indent)
	case: document_signature_write(builder, budget, "_")
	}
}

document_signature :: proc(adapter: ^Document_Model, document: ^doc.Document, entity: doc.Entity, display_name: string, allocator: mem.Allocator) -> string {
	builder: strings.Builder
	defer strings.builder_destroy(&builder)
	budget := Document_Signature_Budget{remaining = DOCUMENT_SIGNATURE_MAX_BYTES}
	document_signature_write(&builder, &budget, display_name)
	switch entity.kind {
	case 1, 2, 3:
		document_signature_write(&builder, &budget, " :: ")
		if entity.kind == 3 && entity.type != 0 && int(entity.type) < len(document.types) && document.types[entity.type].kind == 2 && len(document.types[entity.type].types) > 0 {
			document_append_type(&builder, &budget, document, document.types[entity.type].types[0], 0, 0)
		} else {
			document_append_type(&builder, &budget, document, entity.type, 0, 0)
		}
		if len(entity.init_string) > 0 {
			document_signature_write(&builder, &budget, " = ")
			document_signature_write(&builder, &budget, entity.init_string)
		}
	case 4:
		document_signature_write(&builder, &budget, " :: ")
		document_append_type(&builder, &budget, document, entity.type, 0, 0)
	case 5:
		document_signature_write(&builder, &budget, " :: proc group")
	}
	return document_model_own(adapter, strings.to_string(builder), allocator)
}

document_file_index :: proc(pkg: ^Package, path: string) -> int {
	for file, index in pkg.files {
		if file.path == path do return index
	}
	return -1
}

// Model_From_Doc_Workspace adapts selected packages only. It does not invent
// import edges or SLOC because the public format cannot represent those facts.
// Structured signatures and semantic cross-links are deliberately added in M2.
Model_From_Doc_Workspace :: proc(workspace: ^doc.Workspace, workspace_path: string, allocator: mem.Allocator = context.allocator) -> Document_Model {
	adapter := Document_Model{model = {workspace_path = workspace_path}, _owned_strings = make([dynamic]string, 0, 64, allocator)}
	adapter.model.packages = make([dynamic]Package, 0, 16, allocator)
	if workspace == nil do return adapter
	for selected in workspace.packages {
		if selected.document_index < 0 || selected.document_index >= len(workspace.documents) do continue
		document := workspace.documents[selected.document_index]
		if document == nil || int(selected.package_index) >= len(document.packages) do continue
		source_pkg := document.packages[selected.package_index]
		pkg := Package{id = source_pkg.fullpath, name = source_pkg.name, path = source_pkg.fullpath, relative_path = document_workspace_route_path(&adapter, workspace_path, source_pkg.fullpath, source_pkg.name, allocator), overview = source_pkg.docs, summary = source_pkg.docs, files = make([dynamic]File, 0, len(source_pkg.files), allocator)}
		for file_index in source_pkg.files {
			if file_index == 0 || int(file_index) >= len(document.files) do continue
			source_file := document.files[file_index]
			append(&pkg.files, File{name = source_file.name, path = source_file.name, entries = make([dynamic]Entry, 0, 8, allocator)})
		}
		for scope_entry in source_pkg.entries {
			if scope_entry.entity == 0 || int(scope_entry.entity) >= len(document.entities) do continue
			entity := document.entities[scope_entry.entity]
			source_path := ""
			if entity.pos.file > 0 && int(entity.pos.file) < len(document.files) do source_path = document.files[entity.pos.file].name
			file_index := document_file_index(&pkg, source_path)
			if file_index < 0 {
				append(&pkg.files, File{name = source_path, path = source_path, entries = make([dynamic]Entry, 0, 8, allocator)})
				file_index = len(pkg.files) - 1
			}
			entry := Entry{id = scope_entry.name, name = scope_entry.name, anchor = scope_entry.name, kind = document_entity_kind(entity.kind), signature = document_signature(&adapter, document, entity, scope_entry.name, allocator), docs = entity.docs, comment = entity.comment, source_path = source_path, source_line = int(entity.pos.line)}
			append(&pkg.files[file_index].entries, entry)
			adapter.model.stats.entry_count += 1
		}
		adapter.model.stats.package_count += 1
		adapter.model.stats.file_count += len(pkg.files)
		append(&adapter.model.packages, pkg)
	}
	return adapter
}

@(test)
test_doc_workspace_adapter_preserves_package_docs_and_source_positions :: proc(t: ^testing.T) {
	document := doc.Document_Init()
	defer doc.Document_Destroy(&document)
	append(&document.files, doc.File{pkg = 1, name = "/work/demo/main.odin"})
	pkg := doc.Package{fullpath = "/work/demo", name = "demo", docs = "Demo package.", files = make([dynamic]u32, 0, 1), entries = make([dynamic]doc.Scope_Entry, 0, 2)}
	append(&pkg.files, 1)
	append(&pkg.entries, doc.Scope_Entry{name = "Answer", entity = 1})
	append(&pkg.entries, doc.Scope_Entry{name = "Record", entity = 2})
	append(&document.packages, pkg)
	append(&document.entities, doc.Entity{kind = 1, pos = {file = 1, line = 7}, name = "Answer", type = 1, init_string = "42", docs = "The answer.", attributes = make([dynamic]doc.Attribute, 0), grouped_entities = make([dynamic]u32, 0), where_clauses = make([dynamic]string, 0)})
	append(&document.entities, doc.Entity{kind = 3, pos = {file = 1, line = 9}, name = "Record", type = 2, attributes = make([dynamic]doc.Attribute, 0), grouped_entities = make([dynamic]u32, 0), where_clauses = make([dynamic]string, 0)})
	append(&document.entities, doc.Entity{kind = 2, pos = {file = 1, line = 10}, name = "value", type = 1, attributes = make([dynamic]doc.Attribute, 0), grouped_entities = make([dynamic]u32, 0), where_clauses = make([dynamic]string, 0)})
	append(&document.types, doc.Type{kind = 1, name = "int", types = make([dynamic]u32, 0), entities = make([dynamic]u32, 0), where_clauses = make([dynamic]string, 0), tags = make([dynamic]string, 0)})
	append(&document.entities, doc.Entity{kind = 2, pos = {file = 1, line = 11}, name = "height", type = 1, docs = "Vertical extent.", attributes = make([dynamic]doc.Attribute, 0), grouped_entities = make([dynamic]u32, 0), where_clauses = make([dynamic]string, 0)})
	struct_entities := make([dynamic]u32, 0, 2)
	append(&struct_entities, 3)
	append(&struct_entities, 4)
	append(&document.types, doc.Type{kind = 10, flags = 1 << 1, entities = struct_entities, types = make([dynamic]u32, 0), where_clauses = make([dynamic]string, 0), tags = make([dynamic]string, 0)})
	documents := [1]^doc.Document{&document}
	workspace, merge_err := doc.Merge(documents[:])
	defer doc.Workspace_Destroy(&workspace)
	testing.expect(t, merge_err.kind == .None, "adapter test input should merge")
	adapter := Model_From_Doc_Workspace(&workspace, "/work")
	defer Document_Model_Destroy(&adapter)
	testing.expect(t, len(adapter.model.packages) == 1 && adapter.model.packages[0].overview == "Demo package.", "package documentation should reach the renderer model")
	testing.expect(t, adapter.model.packages[0].relative_path == "demo", "package routes should be relative to the selected workspace")
	root_adapter := Model_From_Doc_Workspace(&workspace, "/work/demo")
	defer Document_Model_Destroy(&root_adapter)
	testing.expect(t, root_adapter.model.packages[0].relative_path == "demo", "a package at the workspace root should use its package name rather than a dot route")
	entry := adapter.model.packages[0].files[0].entries[0]
	testing.expect(t, entry.name == "Answer" && entry.signature == "Answer :: int = 42" && entry.source_line == 7, "entries should preserve a usable signature and source position")
	structured := adapter.model.packages[0].files[0].entries[1]
	testing.expect(t, structured.signature == "Record :: struct #packed {\n\tvalue:  int,\n\t// Vertical extent.\n\theight: int,\n}", "type declarations should render structured type graphs as readable code")
}
