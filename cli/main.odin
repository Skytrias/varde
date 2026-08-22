package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:time"
import doc "../doc_format"
import extractor "../extractor"
import varde "../runtime"

TIMING_PHASE_LABELS :: [varde.RUNTIME_TIMING_PHASE_COUNT]string{
	"source.discovery",
	"input.parse-read",
	"source.dependencies",
	"document.lower",
	"document.write",
	"document.merge",
	"site.render-model",
	"site.index-assets",
	"site.pages",
	"site.publish",
}

timing_record :: proc(timings: ^varde.Runtime_Timings, phase: varde.Runtime_Timing_Phase, duration_ms: f64) {
	index := int(phase)
	timings.duration_ms[index] = duration_ms
	timings.measured[index] = true
}

print_timings :: proc(timings: varde.Runtime_Timings, total_ms: f64) {
	for label, index in TIMING_PHASE_LABELS {
		if timings.measured[index] {
			fmt.eprintf("varde_timing phase=%s duration_ms=%.3f\n", label, timings.duration_ms[index])
		} else {
			fmt.eprintf("varde_timing phase=%s skipped=true\n", label)
		}
	}
	fmt.eprintf("varde_timing phase=total duration_ms=%.3f\n", total_ms)
}

print_lower_timings :: proc(timing: extractor.Lower_Timing) {
	if !timing.measured do return
	fmt.eprintf("varde_lower_timing phase=emit duration_ms=%.3f\n", timing.emit_ms)
	fmt.eprintf("varde_lower_timing phase=aliases duration_ms=%.3f\n", timing.aliases_ms)
	fmt.eprintf("varde_lower_timing phase=constants duration_ms=%.3f\n", timing.constants_ms)
	fmt.eprintf("varde_lower_timing phase=procedure-groups duration_ms=%.3f\n", timing.procedure_groups_ms)
	fmt.eprintf("varde_lower_timing phase=named-types duration_ms=%.3f\n", timing.named_types_ms)
	fmt.eprintf("varde_lower_timing phase=finalize duration_ms=%.3f\n", timing.finalize_ms)
	fmt.eprintf("varde_lower_workload packages=%d files=%d declarations=%d entities=%d types=%d pending_aliases=%d pending_constants=%d pending_groups=%d named_type_candidates=%d named_type_entity_scans=%d named_type_lookups=%d named_type_index_names=%d named_type_duplicates=%d diagnostics=%d\n", timing.package_count, timing.file_count, timing.declaration_count, timing.entity_count, timing.type_count, timing.pending_alias_count, timing.pending_constant_count, timing.pending_group_count, timing.named_type_candidates, timing.named_type_entity_scans, timing.named_type_lookups, timing.named_type_index_names, timing.named_type_duplicates, timing.diagnostic_count)
}

print_usage :: proc() {
	fmt.eprintln("Usage:")
	fmt.eprintln("  varde inspect <file.odin-doc> [...more.odin-doc]")
	fmt.eprintln("  varde scan --source <directory> [--target-os <os>] [--target-arch <arch>] [--include-tests]")
	fmt.eprintln("  varde extract --source <directory> --out <file.odin-doc> [--allow-incomplete] [--target-os <os>] [--target-arch <arch>] [--include-tests]")
	fmt.eprintln("  varde build --doc <file.odin-doc> [--doc <file.odin-doc> ...] [--workspace <path>] [--config <file>] [--sloc <count>] [--out <relative-output-dir>]")
	fmt.eprintln("  varde build --source <directory> [--config <file>] [--allow-incomplete] [--emit-doc <file.odin-doc>] [--target-os <os>] [--target-arch <arch>] [--include-tests] [--out <relative-output-dir>]")
}

scan_source :: proc(root_path, target_os, target_arch: string, include_tests: bool) {
	workspace := extractor.Extract(extractor.Config{
		root_path = root_path,
		target_os = target_os,
		target_arch = target_arch,
		include_test_files = include_tests,
	})
	defer extractor.Destroy(&workspace)
	file_count, import_count, declaration_count := 0, 0, 0
	for pkg in workspace.packages {
		fmt.printf("- %s (%s)\n", pkg.name, pkg.path)
		for file in pkg.files {
			file_count += 1
			import_count += len(file.imports)
			declaration_count += len(file.declarations)
		}
	}
	fmt.printf("Packages: %d\nFiles: %d\nSLOC: %d\nImports: %d\nDeclarations: %d\nDiagnostics: %d\n", len(workspace.packages), file_count, workspace.sloc, import_count, declaration_count, len(workspace.diagnostics))
	for diagnostic in workspace.diagnostics {
		fmt.eprintf("%s(%d:%d): %s\n", diagnostic.path, diagnostic.line, diagnostic.column, diagnostic.message)
	}
}

write_document_file :: proc(document: ^doc.Document, output_path: string) -> bool {
	data, write_err := doc.Write(document)
	defer delete(data)
	if write_err.kind != .None { fmt.eprintf("Could not serialize .odin-doc: %s\n", doc.error_string(write_err)); return false }
	if directory := filepath.dir(output_path); len(directory) > 0 {
		if directory_err := os.make_directory_all(directory); directory_err != nil && directory_err != .Exist { fmt.eprintf("Could not create output directory: %v\n", directory_err); return false }
	}
	if output_err := os.write_entire_file(output_path, data[:]); output_err != nil { fmt.eprintf("Could not write %q: %v\n", output_path, output_err); return false }
	return true
}

print_source_diagnostics :: proc(workspace: extractor.Workspace, result: extractor.Lower_Result) {
	for diagnostic in workspace.diagnostics do fmt.eprintf("%s(%d:%d): %s\n", diagnostic.path, diagnostic.line, diagnostic.column, diagnostic.message)
	for diagnostic in result.diagnostics do fmt.eprintf("%s(%d:%d): %s\n", diagnostic.path, diagnostic.line, diagnostic.column, diagnostic.message)
}

extract_source :: proc(root_path, output_path, target_os, target_arch: string, include_tests, allow_incomplete: bool) {
	total_started := time.tick_now()
	timings: varde.Runtime_Timings
	workspace := extractor.Extract(extractor.Config{root_path = root_path, target_os = target_os, target_arch = target_arch, include_test_files = include_tests})
	timing_record(&timings, .Source_Discovery, workspace.timing.discovery_ms)
	timing_record(&timings, .Input_Parse_Read, workspace.timing.parse_read_ms)
	timing_record(&timings, .Source_Dependencies, workspace.timing.dependency_ms)
	defer extractor.Destroy(&workspace)
	result := extractor.Lower(&workspace, {incomplete_policy = allow_incomplete ? .Emit : .Reject})
	timing_record(&timings, .Document_Lower, result.duration_ms)
	defer extractor.Lower_Result_Destroy(&result)
	print_source_diagnostics(workspace, result)
	if !result.complete && !allow_incomplete { fmt.eprintln("Refusing to emit an incomplete .odin-doc. Fix diagnostics or pass --allow-incomplete explicitly."); return }
	write_started := time.tick_now()
	if !write_document_file(&result.document, output_path) do return
	timing_record(&timings, .Document_Write, time.duration_milliseconds(time.tick_since(write_started)))
	print_timings(timings, time.duration_milliseconds(time.tick_since(total_started)))
	print_lower_timings(result.timing)
	status := "complete"
	if !result.complete do status = "incomplete (explicitly allowed)"
	fmt.printf("Wrote %s .odin-doc with %d packages, %d declarations, and %d SLOC to %s\n", status, len(result.document.packages)-1, len(result.document.entities)-1, workspace.sloc, output_path)
}

build_from_source :: proc(root_path, output_dir, emit_doc_path, target_os, target_arch, project_config_path: string, include_tests, allow_incomplete: bool) {
	total_started := time.tick_now()
	built := varde.Runtime_Build({
		source_path = root_path,
		project_config_path = project_config_path,
		output_dir = output_dir,
		emit_doc_path = emit_doc_path,
		target_os = target_os,
		target_arch = target_arch,
		include_test_files = include_tests,
		allow_incomplete = allow_incomplete,
		load_project_config = true,
	})
	total_ms := time.duration_milliseconds(time.tick_since(total_started))
	defer varde.Runtime_Build_Result_Destroy(&built)
	print_timings(built.timings, total_ms)
	print_lower_timings(built.lower_timing)
	print_runtime_diagnostics(built)
	if !built.ok { fmt.eprintf("Varde build failed: %s\n", built.error_message); return }
	status := "complete"
	if !built.complete do status = "incomplete (explicitly allowed)"
	fmt.printf("Built %s source site with %d packages and %d entries at %s\n", status, built.package_count, built.entry_count, built.output_path)
}

print_runtime_diagnostics :: proc(result: varde.Runtime_Build_Result) {
	for diagnostic in result.diagnostics {
		if len(diagnostic.path) > 0 && diagnostic.line > 0 {
			fmt.eprintf("%s(%d:%d): %s\n", diagnostic.path, diagnostic.line, diagnostic.column, diagnostic.message)
		} else if len(diagnostic.path) > 0 {
			fmt.eprintf("%s: %s\n", diagnostic.path, diagnostic.message)
		} else {
			fmt.eprintln(diagnostic.message)
		}
	}
}

load_workspace :: proc(paths: []string) -> ([dynamic]doc.Document, doc.Workspace, doc.Error) {
	documents := make([dynamic]doc.Document, 0, len(paths))
	for path in paths {
		data, read_err := os.read_entire_file(path, context.allocator)
		if read_err != nil {
			fmt.eprintf("Could not read %q: %v\n", path, read_err)
			for &document in documents do doc.Document_Destroy(&document)
			delete(documents)
			return nil, {}, {kind = .Invalid_Offset}
		}
		document, format_err := doc.Read(data)
		delete(data)
		if format_err.kind != .None {
			fmt.eprintf("Invalid .odin-doc %q: %s\n", path, doc.error_string(format_err))
			for &prior in documents do doc.Document_Destroy(&prior)
			delete(documents)
			return nil, {}, format_err
		}
		append(&documents, document)
	}
	document_refs := make([dynamic]^doc.Document, 0, len(documents))
	defer delete(document_refs)
	for &document in documents do append(&document_refs, &document)
	workspace, merge_err := doc.Merge(document_refs[:])
	if merge_err.kind != .None {
		for &document in documents do doc.Document_Destroy(&document)
		delete(documents)
		return nil, {}, merge_err
	}
	return documents, workspace, {}
}

destroy_loaded_workspace :: proc(documents: ^[dynamic]doc.Document, workspace: ^doc.Workspace) {
	if workspace != nil do doc.Workspace_Destroy(workspace)
	if documents != nil {
		for &document in documents^ do doc.Document_Destroy(&document)
		delete(documents^)
	}
}

inspect :: proc(paths: []string) {
	documents, workspace, merge_err := load_workspace(paths)
	if merge_err.kind != .None do return
	defer destroy_loaded_workspace(&documents, &workspace)
	fmt.printf("Valid Odin doc format %d.%d.%d\n", doc.VERSION_MAJOR, doc.VERSION_MINOR, doc.VERSION_PATCH)
	fmt.printf("Documents: %d\nSelected packages: %d\nDuplicate choices: %d\n", len(documents), len(workspace.packages), len(workspace.diagnostics))
	for item in workspace.packages {
		package_path := doc.Workspace_Package_Path(&workspace, item)
		fmt.printf("- %s (%d public entries; document %d)\n", package_path, item.public_entry_count, item.document_index + 1)
	}
}

build_from_documents :: proc(paths: []string, workspace_path, output_dir, project_config_path: string, sloc: int) {
	total_started := time.tick_now()
	result := varde.Runtime_Build({
		document_paths = paths,
		workspace_path = workspace_path,
		project_config_path = project_config_path,
		output_dir = output_dir,
		load_project_config = true,
		document_sloc = sloc,
	})
	total_ms := time.duration_milliseconds(time.tick_since(total_started))
	defer varde.Runtime_Build_Result_Destroy(&result)
	print_timings(result.timings, total_ms)
	print_runtime_diagnostics(result)
	if !result.ok {
		fmt.eprintf("Varde build failed: %s\n", result.error_message)
		return
	}
	fmt.printf("Built %d packages and %d entries at %s\n", result.package_count, result.entry_count, result.output_path)
}

main :: proc() {
	if len(os.args) < 2 {
		print_usage()
		return
	}
	args := os.args[1:]
	if args[0] == "inspect" {
		if len(args) < 2 { print_usage(); return }
		inspect(args[1:])
		return
	}
	if args[0] == "scan" {
		root_path, target_os, target_arch := "", "", ""
		include_tests := false
		for index := 1; index < len(args); index += 1 {
			switch args[index] {
			case "--source":
				if index + 1 >= len(args) { print_usage(); return }
				index += 1
				root_path = args[index]
			case "--target-os":
				if index + 1 >= len(args) { print_usage(); return }
				index += 1
				target_os = args[index]
			case "--target-arch":
				if index + 1 >= len(args) { print_usage(); return }
				index += 1
				target_arch = args[index]
			case "--include-tests": include_tests = true
			case:
				fmt.eprintf("Unknown scan option: %s\n", args[index])
				print_usage()
				return
			}
		}
		if len(root_path) == 0 { print_usage(); return }
		scan_source(root_path, target_os, target_arch, include_tests)
		return
	}
	if args[0] == "extract" {
		root_path, output_path, target_os, target_arch := "", "", "", ""
		include_tests, allow_incomplete := false, false
		for index := 1; index < len(args); index += 1 {
			switch args[index] {
			case "--source":
				if index + 1 >= len(args) { print_usage(); return }; index += 1; root_path = args[index]
			case "--out":
				if index + 1 >= len(args) { print_usage(); return }; index += 1; output_path = args[index]
			case "--target-os":
				if index + 1 >= len(args) { print_usage(); return }; index += 1; target_os = args[index]
			case "--target-arch":
				if index + 1 >= len(args) { print_usage(); return }; index += 1; target_arch = args[index]
			case "--include-tests": include_tests = true
			case "--allow-incomplete": allow_incomplete = true
			case:
				fmt.eprintf("Unknown extract option: %s\n", args[index]); print_usage(); return
			}
		}
		if len(root_path) == 0 || len(output_path) == 0 { print_usage(); return }
		extract_source(root_path, output_path, target_os, target_arch, include_tests, allow_incomplete)
		return
	}
	if args[0] != "build" {
		// Retain the first inspector prototype's concise invocation.
		inspect(args)
		return
	}
	doc_paths := make([dynamic]string, 0, 2)
	defer delete(doc_paths)
	workspace_path, source_path, emit_doc_path, target_os, target_arch, project_config_path := ".", "", "", "", "", ""
	output_dir := ""
	document_sloc := 0
	include_tests, allow_incomplete := false, false
	for index := 1; index < len(args); index += 1 {
		switch args[index] {
		case "--doc":
			if index + 1 >= len(args) { print_usage(); return }
			index += 1
			append(&doc_paths, args[index])
		case "--source":
			if index + 1 >= len(args) { print_usage(); return }
			index += 1
			source_path = args[index]
		case "--config":
			if index + 1 >= len(args) { print_usage(); return }
			index += 1
			project_config_path = args[index]
		case "--emit-doc":
			if index + 1 >= len(args) { print_usage(); return }
			index += 1
			emit_doc_path = args[index]
		case "--target-os":
			if index + 1 >= len(args) { print_usage(); return }
			index += 1
			target_os = args[index]
		case "--target-arch":
			if index + 1 >= len(args) { print_usage(); return }
			index += 1
			target_arch = args[index]
		case "--include-tests": include_tests = true
		case "--allow-incomplete": allow_incomplete = true
		case "--workspace":
			if index + 1 >= len(args) { print_usage(); return }
			index += 1
			workspace_path = args[index]
		case "--sloc":
			if index + 1 >= len(args) { print_usage(); return }
			index += 1
			parsed_sloc, ok := strconv.parse_int(args[index])
			if !ok || parsed_sloc < 0 { fmt.eprintln("--sloc must be a non-negative integer"); return }
			document_sloc = parsed_sloc
		case "--out":
			if index + 1 >= len(args) { print_usage(); return }
			index += 1
			output_dir = args[index]
		case:
			fmt.eprintf("Unknown build option: %s\n", args[index])
			print_usage()
			return
		}
	}
	if len(source_path) > 0 {
		if len(doc_paths) > 0 { fmt.eprintln("Choose exactly one input mode: --source or --doc."); return }
		build_from_source(source_path, output_dir, emit_doc_path, target_os, target_arch, project_config_path, include_tests, allow_incomplete)
		return
	}
	if len(doc_paths) == 0 { print_usage(); return }
	build_from_documents(doc_paths[:], workspace_path, output_dir, project_config_path, document_sloc)
}
