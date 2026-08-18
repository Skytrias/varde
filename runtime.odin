// Runtime publishing is the in-process consumer API. It deliberately
// composes the same compiler-free layers as the CLI rather than spawning it.
package varde

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import doc "./src/doc_format"
import extractor "./src/extractor"

Runtime_Diagnostic_Stage :: enum {
	Configuration,
	Extraction,
	Lowering,
	Merge,
	Build,
	Artifact,
}

Runtime_Diagnostic :: struct {
	stage:   Runtime_Diagnostic_Stage,
	path:    string,
	line:    int,
	column:  int,
	message: string,
}

// Runtime_Build_Request is borrowed for the duration of Runtime_Build. Source
// and document inputs are mutually exclusive. output_dir and emit_doc_path
// must be relative to the chosen workspace, preserving Varde's safe-output
// boundary. Set load_project_config to use varde.json; otherwise config is
// used directly (or defaults when its schema_version is zero).
Runtime_Build_Request :: struct {
	source_path:         string,
	document_paths:      []string,
	workspace_path:      string,
	output_dir:          string,
	emit_doc_path:       string,
	target_os:           string,
	target_arch:         string,
	include_test_files:  bool,
	allow_incomplete:    bool,
	load_project_config: bool,
	config:              Config,
	assets:              Assets,
	cancel_requested:    ^int,
	document_sloc:       int,
}

// Runtime_Build_Result owns all strings and diagnostics it returns. Call
// Runtime_Build_Result_Destroy when the consumer has rendered or stored it.
Runtime_Build_Result :: struct {
	ok:            bool,
	complete:      bool,
	canceled:      bool,
	output_path:   string,
	artifact_path: string,
	package_count: int,
	file_count:    int,
	entry_count:   int,
	sloc:          int,
	diagnostics:   [dynamic]Runtime_Diagnostic,
	error_message: string,
}

runtime_string_clone :: proc(value: string, allocator: mem.Allocator) -> string {
	if len(value) == 0 do return ""
	return strings.clone(value, allocator)
}

runtime_result_error :: proc(result: ^Runtime_Build_Result, message: string, allocator: mem.Allocator) {
	if result == nil do return
	if len(result.error_message) > 0 do delete(result.error_message, allocator)
	result.error_message = runtime_string_clone(message, allocator)
}

runtime_result_add_diagnostic :: proc(result: ^Runtime_Build_Result, stage: Runtime_Diagnostic_Stage, path: string, line, column: int, message: string, allocator: mem.Allocator) {
	if result == nil do return
	append(&result.diagnostics, Runtime_Diagnostic{
		stage = stage,
		path = runtime_string_clone(path, allocator),
		line = line,
		column = column,
		message = runtime_string_clone(message, allocator),
	})
}

Runtime_Build_Result_Destroy :: proc(result: ^Runtime_Build_Result, allocator: mem.Allocator = context.allocator) {
	if result == nil do return
	if len(result.output_path) > 0 do delete(result.output_path, allocator)
	if len(result.artifact_path) > 0 do delete(result.artifact_path, allocator)
	if len(result.error_message) > 0 do delete(result.error_message, allocator)
	for &diagnostic in result.diagnostics {
		if len(diagnostic.path) > 0 do delete(diagnostic.path, allocator)
		if len(diagnostic.message) > 0 do delete(diagnostic.message, allocator)
	}
	delete(result.diagnostics)
	result^ = {}
}

runtime_workspace_path :: proc(request: Runtime_Build_Request) -> string {
	if len(strings.trim_space(request.workspace_path)) > 0 do return request.workspace_path
	if len(strings.trim_space(request.source_path)) > 0 do return request.source_path
	return "."
}

runtime_config_resolve :: proc(request: Runtime_Build_Request, workspace_path: string, result: ^Runtime_Build_Result, allocator: mem.Allocator) -> (Config, bool) {
	if request.load_project_config {
		config, config_err := config_load(workspace_path, "", "", allocator)
		if len(config_err) > 0 do runtime_result_add_diagnostic(result, .Configuration, "", 0, 0, config_err, allocator)
		if len(request.output_dir) > 0 do config_set_output_dir(&config, request.output_dir, allocator)
		return config, true
	}
	config := request.config
	if config.schema_version == 0 do config = config_default(workspace_path, "", "")
	if len(config.output_dir) == 0 do config.output_dir = "dist/varde"
	if len(request.output_dir) > 0 do config.output_dir = request.output_dir
	return config, false
}

runtime_artifact_path_resolve :: proc(workspace_path, emit_doc_path: string) -> (string, string) {
	if len(emit_doc_path) == 0 do return "", ""
	return output_path_resolve(workspace_path, emit_doc_path)
}

runtime_write_document :: proc(document: ^doc.Document, output_path: string) -> string {
	data, write_err := doc.Write(document)
	defer delete(data)
	if write_err.kind != .None do return fmt.tprintf("Could not serialize .odin-doc: %s", doc.error_string(write_err))
	if directory := filepath.dir(output_path); len(directory) > 0 {
		if directory_err := os.make_directory_all(directory); directory_err != nil && directory_err != .Exist do return fmt.tprintf("Could not create artifact directory: %v", directory_err)
	}
	if output_err := os.write_entire_file(output_path, data[:]); output_err != nil do return fmt.tprintf("Could not write .odin-doc: %v", output_err)
	return ""
}

runtime_finish_site :: proc(result: ^Runtime_Build_Result, model: ^Model, config: Config, request: Runtime_Build_Request, allocator: mem.Allocator) -> bool {
	site := build(model, config, request.assets, request.cancel_requested)
	if !site.ok {
		result.canceled = build_canceled(request.cancel_requested) || site.error_message == "Build canceled"
		runtime_result_error(result, site.error_message, allocator)
		runtime_result_add_diagnostic(result, .Build, "", 0, 0, site.error_message, allocator)
		return false
	}
	result.output_path = runtime_string_clone(site.output_path, allocator)
	result.package_count = site.package_count
	result.file_count = model.stats.file_count
	result.entry_count = site.entry_count
	return true
}

runtime_append_extraction_diagnostics :: proc(result: ^Runtime_Build_Result, workspace: extractor.Workspace, allocator: mem.Allocator) {
	for diagnostic in workspace.diagnostics do runtime_result_add_diagnostic(result, .Extraction, diagnostic.path, diagnostic.line, diagnostic.column, diagnostic.message, allocator)
}

runtime_append_lowering_diagnostics :: proc(result: ^Runtime_Build_Result, lowered: extractor.Lower_Result, allocator: mem.Allocator) {
	for diagnostic in lowered.diagnostics do runtime_result_add_diagnostic(result, .Lowering, diagnostic.path, diagnostic.line, diagnostic.column, diagnostic.message, allocator)
}

runtime_append_merge_diagnostics :: proc(result: ^Runtime_Build_Result, workspace: doc.Workspace, allocator: mem.Allocator) {
	for diagnostic in workspace.diagnostics {
		message := fmt.tprintf("duplicate package kept from document %d; discarded document %d", diagnostic.kept_document_index + 1, diagnostic.discarded_document_index + 1)
		runtime_result_add_diagnostic(result, .Merge, diagnostic.package_path, 0, 0, message, allocator)
	}
}

// Runtime_Build builds a site without invoking the CLI. A successful source
// build can optionally emit a compatible `.odin-doc` sidecar. If source
// lowering is incomplete, allow_incomplete must be set explicitly.
Runtime_Build :: proc(request: Runtime_Build_Request, allocator: mem.Allocator = context.allocator) -> Runtime_Build_Result {
	result := Runtime_Build_Result{diagnostics = make([dynamic]Runtime_Diagnostic, 0, 8, allocator)}
	from_source := len(strings.trim_space(request.source_path)) > 0
	from_documents := len(request.document_paths) > 0
	if from_source == from_documents {
		runtime_result_error(&result, "Choose exactly one runtime input: source_path or document_paths", allocator)
		return result
	}
	workspace_path := runtime_workspace_path(request)
	config, owns_config := runtime_config_resolve(request, workspace_path, &result, allocator)
	defer if owns_config do config_destroy(&config, allocator)
	if len(request.output_dir) == 0 && len(config.output_dir) == 0 {
		runtime_result_error(&result, "Output directory is empty", allocator)
		return result
	}
	if from_source {
		source_workspace := extractor.Extract(extractor.Config{
			root_path = request.source_path,
			target_os = request.target_os,
			target_arch = request.target_arch,
			include_test_files = request.include_test_files,
		})
		defer extractor.Destroy(&source_workspace, allocator)
		runtime_append_extraction_diagnostics(&result, source_workspace, allocator)
		lowered := extractor.Lower(&source_workspace, {incomplete_policy = request.allow_incomplete ? .Emit : .Reject}, allocator)
		defer extractor.Lower_Result_Destroy(&lowered, allocator)
		runtime_append_lowering_diagnostics(&result, lowered, allocator)
		result.complete = lowered.complete
		result.sloc = source_workspace.sloc
		if !lowered.complete && !request.allow_incomplete {
			runtime_result_error(&result, "Refusing to build from incomplete source semantics; set allow_incomplete explicitly", allocator)
			return result
		}
		document_refs := [1]^doc.Document{&lowered.document}
		document_workspace, merge_err := doc.Merge(document_refs[:], allocator)
		defer doc.Workspace_Destroy(&document_workspace)
		if merge_err.kind != .None {
			runtime_result_error(&result, doc.error_string(merge_err), allocator)
			return result
		}
		runtime_append_merge_diagnostics(&result, document_workspace, allocator)
		adapter := Model_From_Doc_Workspace(&document_workspace, workspace_path, allocator)
		defer Document_Model_Destroy(&adapter, allocator)
		adapter.model.stats.sloc = source_workspace.sloc
		artifact_path, artifact_path_err := runtime_artifact_path_resolve(workspace_path, request.emit_doc_path)
		if len(artifact_path_err) > 0 {
			runtime_result_error(&result, artifact_path_err, allocator)
			runtime_result_add_diagnostic(&result, .Artifact, "", 0, 0, artifact_path_err, allocator)
			return result
		}
		if !runtime_finish_site(&result, &adapter.model, config, request, allocator) do return result
		if len(artifact_path) > 0 {
			if artifact_err := runtime_write_document(&lowered.document, artifact_path); len(artifact_err) > 0 {
				runtime_result_error(&result, artifact_err, allocator)
				runtime_result_add_diagnostic(&result, .Artifact, artifact_path, 0, 0, artifact_err, allocator)
				return result
			}
			result.artifact_path = runtime_string_clone(artifact_path, allocator)
		}
		result.ok = true
		return result
	}

	documents := make([dynamic]doc.Document, 0, len(request.document_paths), allocator)
	defer {
		for &document in documents do doc.Document_Destroy(&document, allocator)
		delete(documents)
	}
	for document_path in request.document_paths {
		data, read_err := os.read_entire_file(document_path, allocator)
		if read_err != nil {
			message := fmt.tprintf("Could not read .odin-doc: %v", read_err)
			runtime_result_error(&result, message, allocator)
			runtime_result_add_diagnostic(&result, .Build, document_path, 0, 0, message, allocator)
			return result
		}
		document, format_err := doc.Read(data, allocator)
		delete(data, allocator)
		if format_err.kind != .None {
			message := doc.error_string(format_err)
			runtime_result_error(&result, message, allocator)
			runtime_result_add_diagnostic(&result, .Build, document_path, 0, 0, message, allocator)
			return result
		}
		append(&documents, document)
	}
	document_refs := make([dynamic]^doc.Document, 0, len(documents), allocator)
	defer delete(document_refs)
	for &document in documents do append(&document_refs, &document)
	document_workspace, merge_err := doc.Merge(document_refs[:], allocator)
	defer doc.Workspace_Destroy(&document_workspace)
	if merge_err.kind != .None {
		runtime_result_error(&result, doc.error_string(merge_err), allocator)
		return result
	}
	runtime_append_merge_diagnostics(&result, document_workspace, allocator)
	adapter := Model_From_Doc_Workspace(&document_workspace, workspace_path, allocator)
	defer Document_Model_Destroy(&adapter, allocator)
	adapter.model.stats.sloc = request.document_sloc
	result.complete = true
	result.sloc = request.document_sloc
	if len(request.emit_doc_path) > 0 {
		runtime_result_error(&result, "emit_doc_path is only supported for source input", allocator)
		return result
	}
	if !runtime_finish_site(&result, &adapter.model, config, request, allocator) do return result
	result.ok = true
	return result
}

@(test)
test_runtime_build_publishes_site_and_sidecar :: proc(t: ^testing.T) {
	root, root_err := os.make_directory_temp("", "varde-runtime-*", context.temp_allocator)
	testing.expect(t, root_err == nil, "runtime test workspace should be created")
	defer _ = os.remove_all(root)
	source_path := path_join({root, "demo.odin"})
	testing.expect(t, os.write_entire_file(source_path, "package demo\n\nanswer :: 42\n") == nil, "runtime source fixture should be writable")
	request := Runtime_Build_Request{
		source_path = root,
		output_dir = "dist/docs",
		emit_doc_path = "dist/docs/demo.odin-doc",
	}
	result := Runtime_Build(request)
	defer Runtime_Build_Result_Destroy(&result)
	testing.expect(t, result.ok, result.error_message)
	testing.expect(t, os.exists(path_join({root, "dist", "docs", "index.html"})), "runtime build should publish a static site")
	artifact_path := path_join({root, "dist", "docs", "demo.odin-doc"})
	testing.expect(t, os.exists(artifact_path), "runtime build should publish its requested sidecar")
	testing.expect(t, result.package_count == 1 && result.entry_count == 1, "runtime result should report rendered counts")
	document_paths := [1]string{artifact_path}
	from_document := Runtime_Build({document_paths = document_paths[:], workspace_path = root, output_dir = "dist/from-doc"})
	defer Runtime_Build_Result_Destroy(&from_document)
	testing.expect(t, from_document.ok && from_document.complete, from_document.error_message)
	testing.expect(t, os.exists(path_join({root, "dist", "from-doc", "index.html"})), "runtime document input should publish a site without source extraction")
}
