package extractor

import "core:testing"
import "core:strings"
import doc "../doc_format"
import upstream "core:odin/doc-format"

package_index_by_name :: proc(workspace: ^Workspace, name: string) -> int {
	for pkg, index in workspace.packages do if pkg.name == name do return index
	return -1
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
