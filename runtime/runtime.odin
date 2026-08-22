// Runtime publishing is the in-process consumer API. It deliberately
// composes the same compiler-free layers as the CLI rather than spawning it.
package varde

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import doc "../doc_format"
import extractor "../extractor"

Runtime_Diagnostic_Stage :: enum {
	Configuration,
	Extraction,
	Lowering,
	Merge,
	Build,
	Artifact,
}

// Runtime_Timing_Phase is intentionally coarse: these ten sections cover the
// source-to-document path and the document-to-static-site path without adding
// per-declaration instrumentation noise.
Runtime_Timing_Phase :: enum {
	Source_Discovery,
	Input_Parse_Read,
	Source_Dependencies,
	Document_Lower,
	Document_Write,
	Document_Merge,
	Render_Model,
	Site_Index_Assets,
	Site_Pages,
	Site_Publish,
}

RUNTIME_TIMING_PHASE_COUNT :: 10

Runtime_Timings :: struct {
	duration_ms: [RUNTIME_TIMING_PHASE_COUNT]f64,
	measured:    [RUNTIME_TIMING_PHASE_COUNT]bool,
}

runtime_timing_set :: proc(timings: ^Runtime_Timings, phase: Runtime_Timing_Phase, duration_ms: f64) {
	if timings == nil do return
	index := int(phase)
	timings.duration_ms[index] = duration_ms
	timings.measured[index] = true
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
// boundary. Set load_project_config to use varde.json, or pair it with
// project_config_path for an attached definition; otherwise config is used
// directly (or defaults when its schema_version is zero).
Runtime_Build_Request :: struct {
	source_path:         string,
	document_paths:      []string,
	workspace_path:      string,
	project_config_path: string,
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
	timings:       Runtime_Timings,
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

runtime_config_resolve :: proc(request: Runtime_Build_Request, workspace_path: string, result: ^Runtime_Build_Result, allocator: mem.Allocator) -> (Config, bool, string) {
	if request.load_project_config {
		config: Config
		config_err := ""
		if len(request.project_config_path) > 0 {
			config, config_err = config_load_file(request.project_config_path, workspace_path, "", "", allocator)
		} else {
			config, config_err = config_load(workspace_path, "", "", allocator)
		}
		if len(config_err) > 0 {
			diagnostic_path := len(request.project_config_path) > 0 ? request.project_config_path : ""
			runtime_result_add_diagnostic(result, .Configuration, diagnostic_path, 0, 0, config_err, allocator)
			if len(request.project_config_path) > 0 do return config, true, config_err
		}
		if len(request.output_dir) > 0 do config_set_output_dir(&config, request.output_dir, allocator)
		return config, true, ""
	}
	config := request.config
	if config.schema_version == 0 do config = config_default(workspace_path, "", "")
	if len(config.output_dir) == 0 do config.output_dir = "dist/varde"
	if len(request.output_dir) > 0 do config.output_dir = request.output_dir
	return config, false, ""
}

runtime_artifact_path_resolve :: proc(workspace_path, emit_doc_path: string) -> (string, string) {
	if len(emit_doc_path) == 0 do return "", ""
	return output_path_resolve(workspace_path, emit_doc_path)
}

CONFIG_HOMEPAGE_MAX_BYTES :: 256 * 1024
CONFIG_LOGO_MAX_BYTES :: 1024 * 1024

runtime_config_asset_root :: proc(request: Runtime_Build_Request, workspace_path: string) -> (string, string) {
	if len(strings.trim_space(request.project_config_path)) == 0 do return workspace_path, ""
	absolute_path, absolute_err := os.get_absolute_path(request.project_config_path, context.temp_allocator)
	if absolute_err != nil do return "", "Could not resolve project configuration path"
	root := filepath.dir(absolute_path)
	if len(root) == 0 do root = "."
	return root, ""
}

runtime_config_file_read :: proc(config_root, configured_path, label: string, maximum_size: int, allocator: mem.Allocator) -> ([]u8, string) {
	trimmed := strings.trim_space(configured_path)
	if len(trimmed) == 0 do return nil, ""
	if filepath.is_abs(trimmed) do return nil, fmt.tprintf("homepage.%s must be relative to the configuration file", label)
	clean, clean_err := filepath.clean(trimmed, context.temp_allocator)
	if clean_err != nil || clean == "." || clean == ".." || strings.has_prefix(clean, "../") do return nil, fmt.tprintf("homepage.%s must stay beside the configuration file", label)
	path, join_err := filepath.join({config_root, clean}, context.temp_allocator)
	if join_err != nil do return nil, fmt.tprintf("Could not resolve homepage.%s", label)
	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil do return nil, fmt.tprintf("Could not read homepage.%s %q", label, configured_path)
	if len(data) > maximum_size {
		delete(data, allocator)
		return nil, fmt.tprintf("homepage.%s exceeds its %d KiB limit", label, maximum_size / 1024)
	}
	return data, ""
}

runtime_png_valid :: proc(data: []u8) -> bool {
	return len(data) >= 8 && data[0] == 0x89 && data[1] == 'P' && data[2] == 'N' && data[3] == 'G' && data[4] == '\r' && data[5] == '\n' && data[6] == 0x1a && data[7] == '\n'
}

// Runtime loads portable project-definition files before publishing. The
// homepage content is rendered through Varde's safe markup parser; logos are
// intentionally limited to bounded local PNG files and copied as managed site
// assets, never linked from the network.
runtime_project_definition_load :: proc(config: ^Config, config_root: string, assets: ^Assets, allocator: mem.Allocator) -> (loaded_logo: bool, err: string) {
	if config == nil do return false, ""
	if len(strings.trim_space(config.homepage.content_file)) > 0 {
		content, content_err := runtime_config_file_read(config_root, config.homepage.content_file, "content_file", CONFIG_HOMEPAGE_MAX_BYTES, allocator)
		if len(content_err) > 0 do return false, content_err
		config._homepage_content = content
	}
	if len(strings.trim_space(config.homepage.logo)) == 0 do return false, ""
	if !strings.has_suffix(config.homepage.logo, ".png") do return false, "homepage.logo must name a PNG file"
	logo, logo_err := runtime_config_file_read(config_root, config.homepage.logo, "logo", CONFIG_LOGO_MAX_BYTES, allocator)
	if len(logo_err) > 0 do return false, logo_err
	if !runtime_png_valid(logo) {
		delete(logo, allocator)
		return false, "homepage.logo must contain a PNG image"
	}
	assets.brand_png = logo
	return true, ""
}

runtime_source_roots_validate :: proc(source_path: string, roots: []string) -> string {
	if roots_err := source_roots_validate(roots); len(roots_err) > 0 do return roots_err
	for root in roots {
		selected_path, join_err := filepath.join({source_path, root}, context.temp_allocator)
		if join_err != nil do return fmt.tprintf("Could not resolve source root %q", root)
		if !os.is_directory(selected_path) do return fmt.tprintf("source root %q is not a directory in --source", root)
	}
	return ""
}

// Attached definitions are portable data files, not a way to inject code into
// generated pages. Repository-local legacy configs retain their documented
// trusted extension hooks for compatibility.
runtime_attached_config_validate :: proc(config: Config) -> string {
	if len(strings.trim_space(config.head_html)) > 0 || len(strings.trim_space(config.before_content_html)) > 0 || len(strings.trim_space(config.after_content_html)) > 0 {
		return "Attached project definitions do not permit head_html, before_content_html, or after_content_html"
	}
	return ""
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

runtime_finish_site :: proc(result: ^Runtime_Build_Result, model: ^Model, config: Config, assets: Assets, request: Runtime_Build_Request, allocator: mem.Allocator) -> bool {
	site := build(model, config, assets, request.cancel_requested)
	for phase_index in 0..<RUNTIME_TIMING_PHASE_COUNT {
		if site.timings.measured[phase_index] {
			result.timings.duration_ms[phase_index] = site.timings.duration_ms[phase_index]
			result.timings.measured[phase_index] = true
		}
	}
	if !site.ok {
		result.canceled = build_canceled(request.cancel_requested) || site.error_message == "Build canceled"
		runtime_result_error(result, site.error_message, allocator)
		runtime_result_add_diagnostic(result, .Build, "", 0, 0, site.error_message, allocator)
		return false
	}
	result.output_path = runtime_string_clone(site.output_path, allocator)
	result.package_count = site.package_count
	result.file_count = site_render_stats(model).file_count
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
	config, owns_config, config_err := runtime_config_resolve(request, workspace_path, &result, allocator)
	defer if owns_config do config_destroy(&config, allocator)
	if len(config_err) > 0 {
		runtime_result_error(&result, config_err, allocator)
		return result
	}
	if len(request.project_config_path) > 0 {
		if attached_err := runtime_attached_config_validate(config); len(attached_err) > 0 {
			runtime_result_error(&result, attached_err, allocator)
			runtime_result_add_diagnostic(&result, .Configuration, request.project_config_path, 0, 0, attached_err, allocator)
			return result
		}
	}
	if len(request.output_dir) == 0 && len(config.output_dir) == 0 {
		runtime_result_error(&result, "Output directory is empty", allocator)
		return result
	}
	assets := request.assets
	project_logo_loaded := false
	if request.load_project_config {
		config_root, config_root_err := runtime_config_asset_root(request, workspace_path)
		if len(config_root_err) > 0 {
			runtime_result_error(&result, config_root_err, allocator)
			runtime_result_add_diagnostic(&result, .Configuration, request.project_config_path, 0, 0, config_root_err, allocator)
			return result
		}
		definition_err := ""
		project_logo_loaded, definition_err = runtime_project_definition_load(&config, config_root, &assets, allocator)
		if len(definition_err) > 0 {
			runtime_result_error(&result, definition_err, allocator)
			runtime_result_add_diagnostic(&result, .Configuration, request.project_config_path, 0, 0, definition_err, allocator)
			return result
		}
	}
	defer if project_logo_loaded do delete(assets.brand_png, allocator)
	if from_source {
		if roots_err := source_config_validate(config.source); len(roots_err) > 0 {
			runtime_result_error(&result, roots_err, allocator)
			runtime_result_add_diagnostic(&result, .Configuration, request.project_config_path, 0, 0, roots_err, allocator)
			return result
		}
		if roots_err := runtime_source_roots_validate(request.source_path, config.source.roots[:]); len(roots_err) > 0 {
			runtime_result_error(&result, roots_err, allocator)
			runtime_result_add_diagnostic(&result, .Configuration, request.project_config_path, 0, 0, roots_err, allocator)
			return result
		}
		source_workspace := extractor.Extract(extractor.Config{
			root_path = request.source_path,
			source_roots = config.source.roots[:],
			root_files_only = config.source.root_files_only,
			target_os = request.target_os,
			target_arch = request.target_arch,
			include_test_files = request.include_test_files,
		})
		runtime_timing_set(&result.timings, .Source_Discovery, source_workspace.timing.discovery_ms)
		runtime_timing_set(&result.timings, .Input_Parse_Read, source_workspace.timing.parse_read_ms)
		runtime_timing_set(&result.timings, .Source_Dependencies, source_workspace.timing.dependency_ms)
		defer extractor.Destroy(&source_workspace, allocator)
		runtime_append_extraction_diagnostics(&result, source_workspace, allocator)
		lowered := extractor.Lower(&source_workspace, {incomplete_policy = request.allow_incomplete ? .Emit : .Reject}, allocator)
		runtime_timing_set(&result.timings, .Document_Lower, lowered.duration_ms)
		defer extractor.Lower_Result_Destroy(&lowered, allocator)
		runtime_append_lowering_diagnostics(&result, lowered, allocator)
		result.complete = lowered.complete
		result.sloc = source_workspace.sloc
		if !lowered.complete && !request.allow_incomplete {
			runtime_result_error(&result, "Refusing to build from incomplete source semantics; set allow_incomplete explicitly", allocator)
			return result
		}
		document_refs := [1]^doc.Document{&lowered.document}
		merge_started := time.tick_now()
		document_workspace, merge_err := doc.Merge(document_refs[:], allocator)
		runtime_timing_set(&result.timings, .Document_Merge, time.duration_milliseconds(time.tick_since(merge_started)))
		defer doc.Workspace_Destroy(&document_workspace)
		if merge_err.kind != .None {
			runtime_result_error(&result, doc.error_string(merge_err), allocator)
			return result
		}
		runtime_append_merge_diagnostics(&result, document_workspace, allocator)
		model_started := time.tick_now()
		adapter := Model_From_Doc_Workspace(&document_workspace, workspace_path, allocator)
		runtime_timing_set(&result.timings, .Render_Model, time.duration_milliseconds(time.tick_since(model_started)))
		defer Document_Model_Destroy(&adapter, allocator)
		adapter.model.stats.sloc = source_workspace.sloc
		artifact_path, artifact_path_err := runtime_artifact_path_resolve(workspace_path, request.emit_doc_path)
		if len(artifact_path_err) > 0 {
			runtime_result_error(&result, artifact_path_err, allocator)
			runtime_result_add_diagnostic(&result, .Artifact, "", 0, 0, artifact_path_err, allocator)
			return result
		}
		if !runtime_finish_site(&result, &adapter.model, config, assets, request, allocator) do return result
		if len(artifact_path) > 0 {
			write_started := time.tick_now()
			if artifact_err := runtime_write_document(&lowered.document, artifact_path); len(artifact_err) > 0 {
				runtime_timing_set(&result.timings, .Document_Write, time.duration_milliseconds(time.tick_since(write_started)))
				runtime_result_error(&result, artifact_err, allocator)
				runtime_result_add_diagnostic(&result, .Artifact, artifact_path, 0, 0, artifact_err, allocator)
				return result
			}
			runtime_timing_set(&result.timings, .Document_Write, time.duration_milliseconds(time.tick_since(write_started)))
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
	input_started := time.tick_now()
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
	runtime_timing_set(&result.timings, .Input_Parse_Read, time.duration_milliseconds(time.tick_since(input_started)))
	document_refs := make([dynamic]^doc.Document, 0, len(documents), allocator)
	defer delete(document_refs)
	for &document in documents do append(&document_refs, &document)
	merge_started := time.tick_now()
	document_workspace, merge_err := doc.Merge(document_refs[:], allocator)
	runtime_timing_set(&result.timings, .Document_Merge, time.duration_milliseconds(time.tick_since(merge_started)))
	defer doc.Workspace_Destroy(&document_workspace)
	if merge_err.kind != .None {
		runtime_result_error(&result, doc.error_string(merge_err), allocator)
		return result
	}
	runtime_append_merge_diagnostics(&result, document_workspace, allocator)
	model_started := time.tick_now()
	adapter := Model_From_Doc_Workspace_Filtered(&document_workspace, workspace_path, config.workspace_packages_only, allocator)
	runtime_timing_set(&result.timings, .Render_Model, time.duration_milliseconds(time.tick_since(model_started)))
	defer Document_Model_Destroy(&adapter, allocator)
	adapter.model.stats.sloc = request.document_sloc
	result.complete = true
	result.sloc = request.document_sloc
	if len(request.emit_doc_path) > 0 {
		runtime_result_error(&result, "emit_doc_path is only supported for source input", allocator)
		return result
	}
	if !runtime_finish_site(&result, &adapter.model, config, assets, request, allocator) do return result
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
	for measured, phase_index in result.timings.measured {
		testing.expectf(t, measured, "source build with sidecar should measure timing phase %d", phase_index)
	}
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

@(test)
test_runtime_build_uses_external_configured_source_roots :: proc(t: ^testing.T) {
	repository_root, repository_err := os.make_directory_temp("", "varde-selected-roots-repository-*", context.temp_allocator)
	testing.expect(t, repository_err == nil, "source-root fixture repository should be created")
	defer _ = os.remove_all(repository_root)
	core_root := path_join({repository_root, "core"})
	example_root := path_join({repository_root, "examples"})
	testing.expect(t, os.make_directory_all(core_root) == nil && os.make_directory_all(example_root) == nil, "source-root fixture directories should be created")
	testing.expect(t, os.write_entire_file(path_join({core_root, "core.odin"}), "package core\n\nanswer :: 42\n") == nil, "selected source fixture should be writable")
	testing.expect(t, os.write_entire_file(path_join({example_root, "example.odin"}), "package examples\n\nhelper :: 7\n") == nil, "excluded source fixture should be writable")

	config_root, config_root_err := os.make_directory_temp("", "varde-selected-roots-config-*", context.temp_allocator)
	testing.expect(t, config_root_err == nil, "external configuration fixture should be created")
	defer _ = os.remove_all(config_root)
	testing.expect(t, os.write_entire_file(path_join({config_root, "overview.md"}), "# Getting started\n\nUse **core** for the public API.") == nil, "homepage content fixture should be writable")
	logo_png := []u8{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}
	testing.expect(t, os.write_entire_file(path_join({config_root, "mark.png"}), logo_png) == nil, "homepage logo fixture should be writable")
	config_file := path_join({config_root, "project.varde.json"})
	testing.expect(t, os.write_entire_file(config_file, `{"schema_version":8,"title":"Core API","description":"Only the library surface.","source":{"roots":["core"]},"homepage":{"content_file":"overview.md","logo":"mark.png","logo_alt":"Core mark"}}`) == nil, "external project definition should be writable")

	result := Runtime_Build({
		source_path = repository_root,
		project_config_path = config_file,
		output_dir = "dist/docs",
		allow_incomplete = true,
		load_project_config = true,
	})
	defer Runtime_Build_Result_Destroy(&result)
	testing.expect(t, result.ok, result.error_message)
	testing.expect(t, result.package_count == 1 && result.entry_count == 1, "external source configuration should include only the selected library root")
	index_path := path_join({repository_root, "dist", "docs", "index.html"})
	index_data, index_err := os.read_entire_file(index_path, context.temp_allocator)
	defer if index_err == nil do delete(index_data, context.temp_allocator)
	testing.expect(t, index_err == nil && strings.contains(string(index_data), "Core API"), "the external project definition should set the homepage title")
	testing.expect(t, index_err == nil && strings.contains(string(index_data), "Getting started"), "a configured homepage file should render its heading")
	testing.expect(t, index_err == nil && strings.contains(string(index_data), "<strong>core</strong>"), "homepage content should use safe documentation markup")
	testing.expect(t, index_err == nil && strings.contains(string(index_data), "alt=\"Core mark\""), "a configured logo should use its authored alternative text")
	testing.expect(t, index_err == nil && !strings.contains(string(index_data), "examples"), "excluded packages should not appear in the generated homepage")
	logo_path := path_join({repository_root, "dist", "docs", "assets", "brand-mark.png"})
	logo_data, logo_err := os.read_entire_file(logo_path, context.temp_allocator)
	defer if logo_err == nil do delete(logo_data, context.temp_allocator)
	testing.expect(t, logo_err == nil && len(logo_data) == len(logo_png) && logo_data[0] == 0x89, "a configured PNG logo should be copied into the generated site")
}

@(test)
test_source_roots_validate_only_allows_repository_children :: proc(t: ^testing.T) {
	testing.expect(t, len(source_roots_validate([]string{"core", "vendor"})) == 0, "direct repository children should be valid source roots")
	testing.expect(t, len(source_roots_validate([]string{"nested/core"})) > 0, "nested source roots should be rejected")
	testing.expect(t, len(source_roots_validate([]string{"../core"})) > 0, "upward source roots should be rejected")
	testing.expect(t, len(source_roots_validate([]string{".", "core"})) > 0, "the whole repository root must be selected by itself")
}

@(test)
test_source_config_validates_root_files_only_mode :: proc(t: ^testing.T) {
	root_only := Source_Config{roots = make([dynamic]string, 0, 1, context.temp_allocator), root_files_only = true}
	defer delete(root_only.roots)
	append(&root_only.roots, ".")
	testing.expect(t, len(source_config_validate(root_only)) == 0, "root-files-only mode should select the checkout root without recursing")
	wrong_root := Source_Config{roots = make([dynamic]string, 0, 1, context.temp_allocator), root_files_only = true}
	defer delete(wrong_root.roots)
	append(&wrong_root.roots, "core")
	testing.expect(t, len(source_config_validate(wrong_root)) > 0, "root-files-only mode should not be applied to a nested source root")
}

@(test)
test_runtime_source_roots_validate_requires_existing_directories :: proc(t: ^testing.T) {
	root, root_err := os.make_directory_temp("", "varde-source-root-validation-*", context.temp_allocator)
	testing.expect(t, root_err == nil, "source-root validation fixture should be created")
	defer _ = os.remove_all(root)
	testing.expect(t, os.make_directory_all(path_join({root, "core"})) == nil, "source-root validation directory should be created")
	testing.expect(t, len(runtime_source_roots_validate(root, []string{"core"})) == 0, "an existing direct child directory should be valid")
	testing.expect(t, len(runtime_source_roots_validate(root, []string{"missing"})) > 0, "a missing configured source root should fail before publishing an empty site")
}

@(test)
test_runtime_attached_config_rejects_html_extension_hooks :: proc(t: ^testing.T) {
	testing.expect(t, len(runtime_attached_config_validate(Config{head_html = "site/head.html"})) > 0, "attached project definitions should reject raw head HTML")
	testing.expect(t, len(runtime_attached_config_validate(Config{before_content_html = "site/banner.html"})) > 0, "attached project definitions should reject raw content HTML")
	testing.expect(t, len(runtime_attached_config_validate(Config{homepage = {content_file = "overview.md", logo = "mark.png"}})) == 0, "safe homepage content and logo fields should remain available to attached definitions")
}
