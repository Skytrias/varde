package extractor

import "core:testing"
import "core:strings"
import doc "../doc_format"
import upstream "core:odin/doc-format"

package_index_by_name :: proc(workspace: ^Workspace, name: string) -> int {
	for pkg, index in workspace.packages do if pkg.name == name do return index
	return -1
}

document_entity_by_name :: proc(document: ^doc.Document, name: string) -> ^doc.Entity {
	if document == nil do return nil
	for &entity in document.entities do if entity.name == name do return &entity
	return nil
}

@(test)
source_sloc_ignores_blank_and_comment_only_lines :: proc(t: ^testing.T) {
	source := "\n// heading\nvalue := 1 // trailing comment\n/* block\ncomment */\n/* inline */ value := 2\n"
	testing.expect(t, source_sloc(source) == 2)
}

@(test)
source_initializer_excerpt_bounds_large_constant_expressions :: proc(t: ^testing.T) {
	value := "abcdefghijklmnopqrstuvwxyz"
	excerpt := source_initializer_excerpt(value)
	testing.expect(t, len(excerpt) == len(value), "small initializers should be preserved")
	large := strings.repeat("x", SOURCE_INITIALIZER_DISPLAY_MAX_BYTES + 1, context.temp_allocator)
	testing.expect(t, len(source_initializer_excerpt(large)) == SOURCE_INITIALIZER_DISPLAY_MAX_BYTES, "large initializers should be capped in emitted artifacts")
}

@(test)
parse_source_file_keeps_adjacent_declaration_initializers_separate :: proc(t: ^testing.T) {
	file, diagnostics := parse_source_file("inline.odin", "package inline\nfirst :: \"one\"\nsecond :: u8(2)\n", context.temp_allocator)
	defer delete(diagnostics)
	testing.expect(t, len(diagnostics) == 0)
	testing.expect(t, len(file.declarations) == 2)
	testing.expect(t, file.declarations[0].source == "first :: \"one\"")
	testing.expect(t, file.declarations[1].source == "second :: u8(2)")
}

@(test)
extract_discovers_tags_declarations_and_relative_imports :: proc(t: ^testing.T) {
	root := "src/extractor/fixtures/basic"
	workspace := Extract(Config{root_path = root, target_os = "linux", target_arch = "amd64", include_test_files = false})
	defer Destroy(&workspace)
	testing.expect(t, len(workspace.packages) == 2)
	testing.expect(t, len(workspace.packages[0].files) == 1)
	main_index := package_index_by_name(&workspace, "main")
	testing.expect(t, main_index >= 0)
	main := workspace.packages[main_index].files[0]
	testing.expect(t, main.package_name == "main")
	testing.expect(t, len(main.imports) == 1)
	testing.expect(t, main.imports[0].target_package >= 0)
	testing.expect(t, len(main.declarations) == 7)
	testing.expect(t, workspace.sloc > 0)
	testing.expect(t, main.declarations[0].name == "Answer")
	testing.expect(t, main.declarations[0].kind == .Constant)
	testing.expect(t, main.declarations[0].docs == "The documented answer.")
	testing.expect(t, main.declarations[0].source == "Answer :: 42")
	testing.expect(t, main.declarations[1].kind == .Type)
	testing.expect(t, main.declarations[2].kind == .Procedure)
	testing.expect(t, main.declarations[3].kind == .Variable)
	testing.expect(t, main.declarations[3].line == 15)
	testing.expect(t, main.declarations[3].column == 1)
}

@(test)
extract_excludes_nonmatching_platform_and_test_files :: proc(t: ^testing.T) {
	workspace := Extract(Config{root_path = "src/extractor/fixtures/tags", target_os = "linux", target_arch = "amd64"})
	defer Destroy(&workspace)
	testing.expect(t, len(workspace.packages) == 1)
	testing.expect(t, len(workspace.packages[0].files) == 1)
	testing.expect(t, len(workspace.packages[0].files[0].path) > 0)
	testing.expect(t, len(workspace.packages[0].files[0].declarations) == 1)
}

@(test)
build_ignore_tag_excludes_a_file_before_package_validation :: proc(t: ^testing.T) {
	workspace := Extract(Config{root_path = "src/extractor/fixtures/tags", target_os = "linux", target_arch = "amd64"})
	defer Destroy(&workspace)
	testing.expect(t, len(workspace.packages) == 1)
	for diagnostic in workspace.diagnostics do testing.expect(t, diagnostic.kind != .Package_Mismatch, "#+build ignore must exclude the file before package validation")
}

@(test)
extract_reports_relative_import_cycle :: proc(t: ^testing.T) {
	workspace := Extract(Config{root_path = "src/extractor/fixtures/cycle", target_os = "linux", target_arch = "amd64"})
	defer Destroy(&workspace)
	found := false
	for diagnostic in workspace.diagnostics do if diagnostic.kind == .Import_Cycle do found = true
	testing.expect(t, found)
}

@(test)
lower_emits_valid_document_for_supported_source_subset :: proc(t: ^testing.T) {
	workspace := Extract(Config{root_path = "src/extractor/fixtures/basic", target_os = "linux", target_arch = "amd64"})
	defer Destroy(&workspace)
	result := Lower(&workspace, {incomplete_policy = .Emit})
	defer Lower_Result_Destroy(&result)
	testing.expect(t, result.complete)
	testing.expect(t, len(result.diagnostics) == 0)
	testing.expect(t, len(result.document.packages) == 3)
	data, write_err := doc.Write(&result.document)
	defer delete(data)
	testing.expect(t, write_err.kind == .None)
	parsed, read_err := doc.Read(data[:])
	defer doc.Document_Destroy(&parsed)
	testing.expect(t, read_err.kind == .None)
	testing.expect(t, len(parsed.entities) == 11)
	testing.expect(t, parsed.entities[3].name == "value" && parsed.entities[3].pos.file > 0)
	testing.expect(t, parsed.types[parsed.entities[2].type].name == "untyped integer" && parsed.types[parsed.entities[2].type].flags == 1<<1)
	testing.expect(t, parsed.entities[7].name == "Copy" && len(parsed.types[parsed.entities[7].type].entities) == 1)
	testing.expect(t, parsed.types[parsed.entities[8].type].kind == 7)
	testing.expect(t, parsed.entities[9].name == "input" && parsed.entities[9].type > 0)
	_, upstream_err := upstream.read_from_bytes(data[:])
	testing.expect(t, upstream_err == .None)
}

@(test)
lower_recognizes_literal_conversion_and_qualified_type_syntax :: proc(t: ^testing.T) {
	workspace := Extract(Config{root_path = "src/extractor/fixtures/lowering", target_os = "linux", target_arch = "amd64"})
	defer Destroy(&workspace)
	result := Lower(&workspace, {incomplete_policy = .Reject})
	defer Lower_Result_Destroy(&result)
	testing.expect(t, result.complete, "source facts with a literal, explicit conversion, or qualified type spelling should not require the checker")
	testing.expect(t, len(result.diagnostics) == 0)
	testing.expect(t, result.document.types[result.document.entities[1].type].name == "untyped string")
	testing.expect(t, result.document.types[result.document.entities[2].type].name == "untyped string")
	testing.expect(t, result.document.types[result.document.entities[3].type].name == "u8")
	testing.expect(t, result.document.types[result.document.entities[4].type].name == "remote.Value")
}

@(test)
lower_preserves_local_aliases_literal_variables_and_top_level_scope :: proc(t: ^testing.T) {
	workspace := Extract(Config{root_path = "src/extractor/fixtures/source_facts", target_os = "linux", target_arch = "amd64"})
	defer Destroy(&workspace)
	testing.expect(t, len(workspace.packages) == 1 && len(workspace.packages[0].files[0].declarations) == 10, "nested declarations must not escape a procedure body")
	result := Lower(&workspace, {incomplete_policy = .Reject})
	defer Lower_Result_Destroy(&result)
	testing.expect(t, result.complete)
	literal := document_entity_by_name(&result.document, "Literal")
	value_alias := document_entity_by_name(&result.document, "Value_Alias")
	record_alias := document_entity_by_name(&result.document, "Record_Alias")
	distinct_bytes := document_entity_by_name(&result.document, "Distinct_Bytes")
	predicate := document_entity_by_name(&result.document, "Predicate")
	run := document_entity_by_name(&result.document, "Run")
	run_alias := document_entity_by_name(&result.document, "Run_Alias")
	testing.expect(t, literal != nil && result.document.types[literal.type].name == "untyped string" && literal.init_string == "\"literal\"")
	testing.expect(t, value_alias != nil && value_alias.kind == 1 && value_alias.init_string == "Value")
	testing.expect(t, record_alias != nil && record_alias.kind == 3 && record_alias.flags & (1<<20) != 0 && record_alias.init_string == "Record")
	testing.expect(t, distinct_bytes != nil && result.document.types[distinct_bytes.type].kind == 5 && result.document.types[distinct_bytes.type].elem_counts[0] == 8 && distinct_bytes.init_string == "distinct [8]u32")
	testing.expect(t, predicate != nil && result.document.types[predicate.type].kind == 14 && predicate.init_string == "#type proc(value: int) -> bool")
	testing.expect(t, run != nil && run_alias != nil && run_alias.kind == 4 && run_alias.type == run.type)
}
