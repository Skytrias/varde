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
source_file_target_suffixes_follow_the_selected_platform :: proc(t: ^testing.T) {
	testing.expect(t, !source_file_matches_target("general_js.odin", "darwin", "arm64"))
	testing.expect(t, source_file_matches_target("general_js.odin", "js", "wasm32"))
	testing.expect(t, source_file_matches_target("platform_linux_amd64.odin", "linux", "amd64"))
	testing.expect(t, !source_file_matches_target("platform_linux_amd64.odin", "linux", "arm64"))
	testing.expect(t, source_file_matches_target("linux_helpers.odin", "darwin", "arm64"))
	testing.expect(t, source_file_matches_target("regular_helpers.odin", "darwin", "arm64"))
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
parse_source_file_does_not_promote_procedure_parameters_to_declarations :: proc(t: ^testing.T) {
	source := "package sample\nRun :: proc(value := Config{}, allocator := context.allocator) {}\nAfter :: 1\n"
	file, diagnostics := parse_source_file("params.odin", source, context.temp_allocator)
	defer delete(diagnostics)
	testing.expect(t, len(diagnostics) == 0)
	testing.expect(t, len(file.declarations) == 2, "procedure parameter names must remain inside the procedure declaration")
	testing.expect(t, file.declarations[0].name == "Run" && file.declarations[0].kind == .Procedure)
	testing.expect(t, file.declarations[1].name == "After")
}

@(test)
parse_source_file_recognizes_directed_procedures :: proc(t: ^testing.T) {
	file, diagnostics := parse_source_file("directed.odin", "package sample\nFast :: #force_inline proc() {}\nGroup :: proc{Fast}\n", context.temp_allocator)
	defer delete(diagnostics)
	testing.expect(t, len(diagnostics) == 0)
	testing.expect(t, len(file.declarations) == 2)
	testing.expect(t, file.declarations[0].name == "Fast" && file.declarations[0].kind == .Procedure, "procedure directives must not turn procedures into constants")
	testing.expect(t, file.declarations[1].name == "Group" && file.declarations[1].kind == .Procedure_Group)
}

@(test)
parse_source_file_marks_private_constants_and_variables :: proc(t: ^testing.T) {
	source := "package sample\n@(private)\nhidden_constant :: 1\n@(private)\nhidden_variable: int\n"
	file, diagnostics := parse_source_file("private.odin", source, context.temp_allocator)
	defer delete(diagnostics)
	testing.expect(t, len(diagnostics) == 0 && len(file.declarations) == 2)
	testing.expect(t, file.declarations[0].is_private, "private constants should retain their visibility")
	testing.expect(t, file.declarations[1].is_private, "private variables should retain their visibility")
}

@(test)
extract_discovers_tags_declarations_and_relative_imports :: proc(t: ^testing.T) {
	root := "extractor/fixtures/basic"
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
	testing.expect(t, main.declarations[3].line == 17)
	testing.expect(t, main.declarations[3].column == 1)
}

@(test)
extract_excludes_nonmatching_platform_and_test_files :: proc(t: ^testing.T) {
	workspace := Extract(Config{root_path = "extractor/fixtures/tags", target_os = "linux", target_arch = "amd64"})
	defer Destroy(&workspace)
	testing.expect(t, len(workspace.packages) == 1)
	testing.expect(t, len(workspace.packages[0].files) == 1)
	testing.expect(t, len(workspace.packages[0].files[0].path) > 0)
	testing.expect(t, len(workspace.packages[0].files[0].declarations) == 1)
}

@(test)
build_ignore_tag_excludes_a_file_before_package_validation :: proc(t: ^testing.T) {
	workspace := Extract(Config{root_path = "extractor/fixtures/tags", target_os = "linux", target_arch = "amd64"})
	defer Destroy(&workspace)
	testing.expect(t, len(workspace.packages) == 1)
	for diagnostic in workspace.diagnostics do testing.expect(t, diagnostic.kind != .Package_Mismatch, "#+build ignore must exclude the file before package validation")
}

@(test)
extract_reports_relative_import_cycle :: proc(t: ^testing.T) {
	workspace := Extract(Config{root_path = "extractor/fixtures/cycle", target_os = "linux", target_arch = "amd64"})
	defer Destroy(&workspace)
	found := false
	for diagnostic in workspace.diagnostics do if diagnostic.kind == .Import_Cycle do found = true
	testing.expect(t, found)
}

@(test)
lower_emits_valid_document_for_supported_source_subset :: proc(t: ^testing.T) {
	workspace := Extract(Config{root_path = "extractor/fixtures/basic", target_os = "linux", target_arch = "amd64"})
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
	testing.expect(t, len(parsed.entities) == 12)
	testing.expect(t, parsed.entities[3].name == "value" && parsed.entities[3].pos.file > 0 && parsed.entities[3].docs == "The stored record value.", "source member comments should survive lowering into the public document model")
	testing.expect(t, parsed.entities[4].name == "indices" && parsed.types[parsed.entities[4].type].kind == 5 && parsed.types[parsed.entities[4].type].elem_counts[0] == 2, "compound source member types should survive lowering into the public document model")
	testing.expect(t, parsed.types[parsed.entities[2].type].flags & (1 << 1) != 0, "source struct directives should survive lowering into the public document model")
	testing.expect(t, parsed.types[parsed.entities[2].type].name == "untyped integer" && parsed.types[parsed.entities[2].type].flags == 1<<1)
	testing.expect(t, parsed.entities[8].name == "Copy" && len(parsed.types[parsed.entities[8].type].entities) == 1)
	testing.expect(t, parsed.types[parsed.entities[9].type].kind == 7)
	testing.expect(t, parsed.entities[10].name == "input" && parsed.entities[10].type > 0)
	_, upstream_err := upstream.read_from_bytes(data[:])
	testing.expect(t, upstream_err == .None)
}

@(test)
lower_preserves_enum_cases_comments_and_values :: proc(t: ^testing.T) {
	workspace := Extract(Config{root_path = "extractor/fixtures/enums", target_os = "linux", target_arch = "amd64"})
	defer Destroy(&workspace)
	result := Lower(&workspace, {incomplete_policy = .Reject})
	defer Lower_Result_Destroy(&result)
	testing.expect(t, result.complete && len(result.diagnostics) == 0, "simple enum syntax should be complete source data")
	state := document_entity_by_name(&result.document, "State")
	testing.expect(t, state != nil && result.document.types[state.type].kind == 12, "enum declarations should retain their enum type")
	if state == nil do return
	enum_type := result.document.types[state.type]
	testing.expect(t, len(enum_type.types) == 1 && result.document.types[enum_type.types[0]].name == "u8", "the enum underlying type should be retained")
	testing.expect(t, len(enum_type.entities) == 3, "all enum cases should be emitted")
	if len(enum_type.entities) < 3 do return
	unknown := result.document.entities[enum_type.entities[0]]
	ready := result.document.entities[enum_type.entities[1]]
	failed := result.document.entities[enum_type.entities[2]]
	testing.expect(t, unknown.name == "Unknown" && unknown.docs == "No state has been selected." && unknown.init_string == "0" && unknown.comment == "The implicit default.", "enum documentation and inline comments should be preserved")
	testing.expect(t, ready.name == "Ready" && ready.init_string == "8" && ready.docs == "The system is ready.", "direct enum integer literals should render as their decimal value")
	testing.expect(t, failed.name == "Failed" && failed.init_string == "9", "implicit enum values should be written out")
	gamut := document_entity_by_name(&result.document, "BMP_Gamut_Mapping_Intent")
	testing.expect(t, gamut != nil && len(result.document.types[gamut.type].entities) == 5, "enum fixture matching the image package should retain every field")
	if gamut == nil do return
	gamut_fields := result.document.types[gamut.type].entities
	invalid := result.document.entities[gamut_fields[0]]
	abs_colorimetric := result.document.entities[gamut_fields[1]]
	testing.expect(t, invalid.name == "INVALID" && invalid.init_string == "0" && invalid.comment == "If not V5, this field will just be zero-initialized and not valid.", "inline enum field comments should survive source lowering")
	testing.expect(t, abs_colorimetric.name == "ABS_COLORIMETRIC" && abs_colorimetric.init_string == "8", "hexadecimal enum values should render as the documented decimal value")
	rgba := document_entity_by_name(&result.document, "RGBA_Pixel")
	little_endian_count := document_entity_by_name(&result.document, "Little_Endian_Count")
	union_entity := document_entity_by_name(&result.document, "Pixel_Union")
	flags := document_entity_by_name(&result.document, "Pixel_Flags")
	distinct_flags := document_entity_by_name(&result.document, "Distinct_Pixel_Flags")
	bits := document_entity_by_name(&result.document, "Pixel_Bits")
	load := document_entity_by_name(&result.document, "Load")
	testing.expect(t, rgba != nil && rgba.kind == 3 && rgba.init_string == "[4]u8" && result.document.types[rgba.type].kind == 5, "array declarations should follow the compiler's type-entity representation")
	testing.expect(t, little_endian_count != nil && little_endian_count.kind == 3 && result.document.types[little_endian_count.type].name == "u32le", "predeclared endian types should be type declarations, not unresolved aliases")
	testing.expect(t, union_entity != nil && result.document.types[union_entity.type].kind == 11 && len(result.document.types[union_entity.type].types) == 3, "union variants should survive source lowering")
	if union_entity != nil {
		union_type := result.document.types[union_entity.type]
		testing.expect(t, len(union_type.entities) == 3 && result.document.entities[union_type.entities[0]].docs == "A one-channel pixel.", "union variant comments should survive source lowering")
	}
	testing.expect(t, flags != nil && result.document.types[flags.type].kind == 15 && len(result.document.types[flags.type].types) == 2, "bit set element and backing types should survive source lowering")
	testing.expect(t, distinct_flags != nil && distinct_flags.init_string == "distinct bit_set[BMP_Gamut_Mapping_Intent; u32]", "distinct bit sets should keep their authored declaration")
	testing.expect(t, bits != nil && result.document.types[bits.type].kind == 25 && len(result.document.types[bits.type].entities) == 2 && result.document.entities[result.document.types[bits.type].entities[0]].docs == "The low channel.", "bit field backing types, widths, and comments should survive source lowering")
	testing.expect(t, load != nil && load.kind == 5 && len(load.grouped_entities) == 2 && result.document.entities[load.grouped_entities[0]].name == "Load_One", "procedure groups should retain their local procedure members")
	testing.expect(t, document_entity_by_name(&result.document, "hidden_value") == nil && document_entity_by_name(&result.document, "hidden_variable") == nil, "private declarations should not enter public source documentation")
}

@(test)
lower_recognizes_literal_conversion_and_qualified_type_syntax :: proc(t: ^testing.T) {
	workspace := Extract(Config{root_path = "extractor/fixtures/lowering", target_os = "linux", target_arch = "amd64"})
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
	workspace := Extract(Config{root_path = "extractor/fixtures/source_facts", target_os = "linux", target_arch = "amd64"})
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

@(test)
lower_resolves_aliases_from_discovered_imports :: proc(t: ^testing.T) {
	workspace := Extract(Config{root_path = "extractor/fixtures/aliases", target_os = "linux", target_arch = "amd64"})
	defer Destroy(&workspace)
	main_index := package_index_by_name(&workspace, "main")
	testing.expect(t, main_index >= 0 && len(workspace.packages[main_index].files) == 1 && len(workspace.packages[main_index].files[0].imports) == 1 && workspace.packages[main_index].files[0].imports[0].target_package >= 0, "relative aliases should resolve to their discovered import package")
	result := Lower(&workspace, {incomplete_policy = .Reject})
	defer Lower_Result_Destroy(&result)
	testing.expect(t, result.complete && len(result.diagnostics) == 0, "aliases to discovered imports should be established without the compiler")
	remote_record := document_entity_by_name(&result.document, "Remote_Record")
	remote_value := document_entity_by_name(&result.document, "Remote_Value")
	shared_record := document_entity_by_name(&result.document, "Record")
	shared_value := document_entity_by_name(&result.document, "Value")
	testing.expect(t, remote_record != nil && shared_record != nil && remote_record.kind == shared_record.kind && remote_record.type == shared_record.type, "imported type aliases should retain the target declaration graph")
	testing.expect(t, remote_value != nil && shared_value != nil && remote_value.kind == shared_value.kind && remote_value.type == shared_value.type, "imported value aliases should retain the target declaration graph")
}

@(test)
lower_resolves_collection_aliases_inside_the_selected_source_root :: proc(t: ^testing.T) {
	workspace := Extract(Config{root_path = "extractor/fixtures/collections", target_os = "linux", target_arch = "amd64"})
	defer Destroy(&workspace)
	result := Lower(&workspace, {incomplete_policy = .Reject})
	defer Lower_Result_Destroy(&result)
	testing.expect(t, result.complete && len(result.diagnostics) == 0, "a collection import should resolve when its package is inside the selected source root")
	alias := document_entity_by_name(&result.document, "Shared_Record")
	target := document_entity_by_name(&result.document, "Record")
	testing.expect(t, alias != nil && target != nil && alias.kind == target.kind && alias.type == target.type, "collection aliases should preserve their target declaration graph")
}
