// Package extractor discovers and parses Odin source without invoking an Odin
// executable. It deliberately owns a small source-facing model instead of
// emitting a guessed .odin-doc graph: semantic lowering belongs to M4.
package extractor

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// Config selects a deterministic source view. Empty target fields use the
// host defaults; callers building releases should set both explicitly.
Config :: struct {
	root_path:       string,
	target_os:       string,
	target_arch:     string,
	include_test_files: bool,
}

Diagnostic_Kind :: enum {
	Discovery,
	Syntax,
	Package_Mismatch,
	Unresolved_Import,
	Import_Cycle,
}

Diagnostic :: struct {
	kind:    Diagnostic_Kind,
	path:    string,
	line:    int,
	column: int,
	message: string,
}

Import :: struct {
	alias:          string,
	path:           string,
	line:           int,
	column:         int,
	target_package: int, // -1 means external or unresolved
}

Declaration_Kind :: enum {
	Unknown,
	Constant,
	Variable,
	Type,
	Procedure,
	Procedure_Group,
}

Declaration :: struct {
	name:       string,
	kind:       Declaration_Kind,
	docs:       string,
	line:       int,
	column:     int,
	offset:     int,
	is_private: bool,
	source:     string, // borrowed slice of Source_File.source
}

Source_File :: struct {
	path:         string,
	package_name: string,
	source:       string,
	imports:      [dynamic]Import,
	declarations: [dynamic]Declaration,
}

Package :: struct {
	name:  string,
	path:  string,
	files: [dynamic]Source_File,
}

Workspace :: struct {
	root_path:   string,
	packages:    [dynamic]Package,
	diagnostics: [dynamic]Diagnostic,
	sloc:        int,
}

// Destroy releases all data owned by Extract. Slices stored in declarations
// borrow their source file and must not be released individually.
Destroy :: proc(workspace: ^Workspace, allocator: mem.Allocator = context.allocator) {
	if workspace == nil do return
	for &pkg in workspace.packages {
		delete(pkg.name, allocator)
		delete(pkg.path, allocator)
		for &file in pkg.files {
			delete(file.path, allocator)
			delete(file.package_name, allocator)
			delete(file.source, allocator)
			for &imp in file.imports {
				if len(imp.alias) > 0 do delete(imp.alias, allocator)
				delete(imp.path, allocator)
			}
			for &decl in file.declarations {
				delete(decl.name, allocator)
				if len(decl.docs) > 0 do delete(decl.docs, allocator)
			}
			delete(file.imports)
			delete(file.declarations)
		}
		delete(pkg.files)
	}
	for &diagnostic in workspace.diagnostics {
		delete(diagnostic.path, allocator)
		delete(diagnostic.message, allocator)
	}
	delete(workspace.root_path, allocator)
	delete(workspace.packages)
	delete(workspace.diagnostics)
	workspace^ = {}
}

add_diagnostic :: proc(workspace: ^Workspace, kind: Diagnostic_Kind, path: string, line, column: int, message: string, allocator: mem.Allocator) {
	append(&workspace.diagnostics, Diagnostic{
		kind = kind,
		path = strings.clone(path, allocator),
		line = line,
		column = column,
		message = strings.clone(message, allocator),
	})
}

host_os :: proc() -> string {
	when ODIN_OS == .Darwin do return "darwin"
	when ODIN_OS == .Linux do return "linux"
	when ODIN_OS == .Windows do return "windows"
	return "unknown"
}

host_arch :: proc() -> string {
	when ODIN_ARCH == .amd64 do return "amd64"
	when ODIN_ARCH == .arm64 do return "arm64"
	when ODIN_ARCH == .arm32 do return "arm32"
	return "unknown"
}

is_space :: proc(ch: byte) -> bool { return ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' }
is_ident_start :: proc(ch: byte) -> bool { return ch == '_' || ('a' <= ch && ch <= 'z') || ('A' <= ch && ch <= 'Z') }
is_ident_continue :: proc(ch: byte) -> bool { return is_ident_start(ch) || ('0' <= ch && ch <= '9') }

Token_Kind :: enum { End, Ident, String, Comment, Symbol }
Token :: struct { kind: Token_Kind, text: string, offset, end, line, column: int }

Lexer :: struct {
	source: string,
	offset: int,
	line: int,
	column: int,
}

lexer_init :: proc(source: string) -> Lexer { return Lexer{source = source, line = 1, column = 1} }

lexer_advance :: proc(lexer: ^Lexer) -> byte {
	if lexer.offset >= len(lexer.source) do return 0
	ch := lexer.source[lexer.offset]
	lexer.offset += 1
	if ch == '\n' { lexer.line += 1; lexer.column = 1 } else { lexer.column += 1 }
	return ch
}

lexer_peek :: proc(lexer: ^Lexer, offset := 0) -> byte {
	i := lexer.offset + offset
	if i >= len(lexer.source) do return 0
	return lexer.source[i]
}

lexer_next :: proc(lexer: ^Lexer) -> Token {
	for is_space(lexer_peek(lexer)) do lexer_advance(lexer)
	start, line, column := lexer.offset, lexer.line, lexer.column
	ch := lexer_peek(lexer)
	if ch == 0 do return Token{kind = .End, offset = start, end = start, line = line, column = column}
	if is_ident_start(ch) {
		for is_ident_continue(lexer_peek(lexer)) do lexer_advance(lexer)
		return Token{kind = .Ident, text = lexer.source[start:lexer.offset], offset = start, end = lexer.offset, line = line, column = column}
	}
	if ch == '"' || ch == '`' {
		quote := lexer_advance(lexer)
		for lexer_peek(lexer) != 0 {
			current := lexer_advance(lexer)
			if quote == '"' && current == '\\' && lexer_peek(lexer) != 0 { lexer_advance(lexer); continue }
			if current == quote do break
		}
		return Token{kind = .String, text = lexer.source[start:lexer.offset], offset = start, end = lexer.offset, line = line, column = column}
	}
	if ch == '/' && (lexer_peek(lexer, 1) == '/' || lexer_peek(lexer, 1) == '*') {
		block := lexer_peek(lexer, 1) == '*'
		lexer_advance(lexer); lexer_advance(lexer)
		depth := 1
		for lexer_peek(lexer) != 0 {
			if block && lexer_peek(lexer) == '/' && lexer_peek(lexer, 1) == '*' { lexer_advance(lexer); lexer_advance(lexer); depth += 1; continue }
			if block && lexer_peek(lexer) == '*' && lexer_peek(lexer, 1) == '/' { lexer_advance(lexer); lexer_advance(lexer); depth -= 1; if depth == 0 do break; continue }
			if !block && lexer_peek(lexer) == '\n' do break
			lexer_advance(lexer)
		}
		return Token{kind = .Comment, text = lexer.source[start:lexer.offset], offset = start, end = lexer.offset, line = line, column = column}
	}
	lexer_advance(lexer)
	if (ch == ':' && lexer_peek(lexer) == ':') || (ch == '.' && lexer_peek(lexer) == '.') {
		lexer_advance(lexer)
	}
	return Token{kind = .Symbol, text = lexer.source[start:lexer.offset], offset = start, end = lexer.offset, line = line, column = column}
}

string_literal_contents :: proc(text: string) -> string {
	if len(text) < 2 do return ""
	return text[1:len(text)-1]
}

comment_docs :: proc(comments: []Token, allocator: mem.Allocator) -> string {
	if len(comments) == 0 do return ""
	builder: strings.Builder
	defer strings.builder_destroy(&builder)
	for comment, index in comments {
		text := comment.text
		if strings.has_prefix(text, "//") {
			text = text[2:]
			if len(text) > 0 && text[0] == '/' do text = text[1:]
			text = strings.trim_space(text)
		} else if len(text) >= 4 {
			text = strings.trim_space(text[2:len(text)-2])
		}
		if index > 0 do strings.write_rune(&builder, '\n')
		strings.write_string(&builder, text)
	}
	return strings.clone(strings.to_string(builder), allocator)
}

declaration_end_offset :: proc(tokens: []Token, start_index, source_len: int) -> int {
	end := source_len
	declaration_line := tokens[start_index-2].line
	expression_depth := 0
	composite_depth := 0
	for index := start_index; index < len(tokens); index += 1 {
		token := tokens[index]
		// A semicolon inside a type constructor (for example
		// `bit_set[Flag; u32]`) is syntax, not a declaration boundary.
		if token.kind == .End || (token.text == ";" && expression_depth == 0 && composite_depth == 0) { end = token.offset; break }
		// Attributes belong to the following declaration. Treating their
		// parentheses as part of the current declaration would swallow a
		// following `@(private)` and lose its visibility annotation.
		if expression_depth == 0 && composite_depth == 0 && token.text == "@" && index > start_index && index+1 < len(tokens) && tokens[index+1].text == "(" { end = token.offset; break }
		if token.text == "(" || token.text == "[" { expression_depth += 1; continue }
		if token.text == ")" || token.text == "]" { if expression_depth > 0 do expression_depth -= 1; continue }
		if token.text == "{" {
			// Composite literals in procedure parameters/default values are not a
			// declaration body. In particular, stopping at `Alpha_Key{}` would
			// make later procedure parameters look like package declarations.
			if expression_depth > 0 || composite_depth > 0 { composite_depth += 1; continue }
			depth := 1
			for body_index := index+1; body_index < len(tokens); body_index += 1 {
				if tokens[body_index].text == "{" do depth += 1
				if tokens[body_index].text == "}" do depth -= 1
				if depth == 0 do return tokens[body_index].end
			}
			return source_len
		}
		if token.text == "}" && composite_depth > 0 { composite_depth -= 1; continue }
		if token.kind == .Comment && token.line > declaration_line { end = token.offset; break }
		// The lightweight lexer intentionally leaves newline insertion to this
		// source parser. A following top-level declaration is therefore also a
		// reliable boundary for declarations that omit an explicit semicolon.
		if expression_depth == 0 && composite_depth == 0 && index > start_index && token.kind == .Ident && index+1 < len(tokens) && (tokens[index+1].text == ":" || tokens[index+1].text == "::") { end = token.offset; break }
	}
	return end
}

message_with_path :: proc(prefix, path: string, allocator: mem.Allocator) -> string {
	builder := strings.builder_make_none(allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, prefix)
	strings.write_string(&builder, path)
	return strings.clone(strings.to_string(builder), allocator)
}

// file_matches_tags recognizes Odin #+ignore and #+build tags. Multiple build
// lines are ANDed; comma-separated alternatives on a single line are ORed,
// matching the upstream parser's public semantics. Unknown values are ignored
// just as the upstream tag parser ignores non-platform build values.
file_matches_tags :: proc(source, target_os, target_arch: string) -> (include, is_test: bool) {
	include = true
	line_source := source
	for line in strings.split_lines_iterator(&line_source) {
		text := strings.trim_space(line)
		if !strings.has_prefix(text, "#+") do continue
		text = strings.trim_space(text[2:])
		if text == "ignore" do return false, is_test
		if text == "test" { is_test = true; continue }
		if !strings.has_prefix(text, "build") do continue
		values := strings.trim_space(text[len("build"):])
		// Odin uses `#+build ignore` for files such as examples that live next
		// to a package but are deliberately excluded from that package build.
		if values == "ignore" do return false, is_test
		line_matches := false
		for group in strings.split(values, ",", context.temp_allocator) {
			positive_os, positive_arch := false, false
			allowed := true
			for raw in strings.fields(group, context.temp_allocator) {
				negated := len(raw) > 0 && raw[0] == '!'
				value := raw[1:] if negated else raw
				is_os := value == "darwin" || value == "linux" || value == "windows" || value == "freebsd" || value == "openbsd" || value == "netbsd" || value == "haiku" || value == "wasi" || value == "js" || value == "essence"
				is_arch := value == "amd64" || value == "arm64" || value == "arm32" || value == "wasm32" || value == "wasm64" || value == "i386" || value == "riscv64p32" || value == "riscv64"
				if is_os {
					if negated { if value == target_os do allowed = false } else { positive_os = true; if value != target_os do allowed = false }
				} else if is_arch {
					if negated { if value == target_arch do allowed = false } else { positive_arch = true; if value != target_arch do allowed = false }
				}
			}
			_ = positive_os; _ = positive_arch
			line_matches ||= allowed
		}
		include &&= line_matches
	}
	return include, is_test
}

// Odin's source selection also recognizes trailing target components in a
// file name, such as `general_js.odin` or `platform_linux_amd64.odin`.
// Ordinary filename words remain neutral, even when they happen to spell a
// target (for example, `linux_helpers.odin`).
source_file_matches_target :: proc(name, target_os, target_arch: string) -> bool {
	base := name
	if strings.has_suffix(base, ".odin") do base = base[:len(base)-len(".odin")]
	end := len(base)
	for end > 0 {
		start := end
		for start > 0 && base[start-1] != '_' do start -= 1
		component := base[start:end]
		switch component {
		case "darwin", "linux", "windows", "freebsd", "openbsd", "netbsd", "haiku", "wasi", "js", "essence":
			if component != target_os do return false
		case "amd64", "arm64", "arm32", "wasm32", "wasm64", "i386", "riscv64p32", "riscv64":
			if component != target_arch do return false
		case:
			return true
		}
		if start == 0 do break
		end = start - 1
	}
	return true
}

// declaration_token_skip returns the last token belonging to a declaration
// whose source slice ends at end_offset. Skipping a recognized top-level
// declaration body prevents nested procedures and local `:=` statements from
// being rediscovered as package declarations.
declaration_token_skip :: proc(tokens: []Token, declaration_index, end_offset: int) -> int {
	for index := declaration_index + 1; index < len(tokens); index += 1 {
		if tokens[index].offset >= end_offset do return index - 1
	}
	return len(tokens) - 1
}

parse_source_file :: proc(path, source: string, allocator: mem.Allocator) -> (file: Source_File, diagnostics: [dynamic]Diagnostic) {
	file.path = strings.clone(path, allocator)
	file.source = strings.clone(source, allocator)
	file.imports = make([dynamic]Import, 0, 4, allocator)
	file.declarations = make([dynamic]Declaration, 0, 8, allocator)
	diagnostics = make([dynamic]Diagnostic, 0, 2, allocator)
	lexer := lexer_init(file.source)
	tokens := make([dynamic]Token, 0, 32, context.temp_allocator)
	defer delete(tokens)
	for {
		token := lexer_next(&lexer)
		append(&tokens, token)
		if token.kind == .End do break
	}

	package_found := false
	depth := 0
	pending_private := false
	pending_comments := make([dynamic]Token, 0, 2, context.temp_allocator)
	defer delete(pending_comments)
	for i := 0; i < len(tokens); i += 1 {
		token := tokens[i]
		if token.kind == .End do break
		if token.kind == .Comment {
			if depth == 0 do append(&pending_comments, token)
			continue
		}
		if token.text == "{" || token.text == "(" || token.text == "[" { depth += 1; continue }
		if token.text == "}" || token.text == ")" || token.text == "]" { if depth > 0 do depth -= 1; continue }
		if !package_found && token.kind == .Ident && token.text == "package" {
			if i+1 < len(tokens) && tokens[i+1].kind == .Ident {
				file.package_name = strings.clone(tokens[i+1].text, allocator)
				package_found = true
				i += 1
				clear(&pending_comments)
				continue
			}
		}
		if !package_found do continue
		if depth == 0 && token.text == "@" && i+2 < len(tokens) && tokens[i+1].text == "(" {
			for attribute_index := i+2; attribute_index < len(tokens) && tokens[attribute_index].text != ")"; attribute_index += 1 {
				if tokens[attribute_index].kind == .Ident && tokens[attribute_index].text == "private" do pending_private = true
			}
			continue
		}
		if depth != 0 { clear(&pending_comments); continue }
		if token.kind == .Ident && token.text == "import" {
			alias, value: Token
			if i+1 < len(tokens) && tokens[i+1].kind == .String { value = tokens[i+1]; i += 1
			} else if i+2 < len(tokens) && tokens[i+1].kind == .Ident && tokens[i+2].kind == .String { alias = tokens[i+1]; value = tokens[i+2]; i += 2 }
			if value.kind == .String {
				entry := Import{path = strings.clone(string_literal_contents(value.text), allocator), line = token.line, column = token.column, target_package = -1}
				if alias.kind == .Ident do entry.alias = strings.clone(alias.text, allocator)
				append(&file.imports, entry)
			} else {
				append(&diagnostics, Diagnostic{kind = .Syntax, path = strings.clone(path, allocator), line = token.line, column = token.column, message = strings.clone("expected an import path string", allocator)})
			}
			clear(&pending_comments)
			continue
		}
		if token.kind == .Ident && i+2 < len(tokens) && tokens[i+1].text == "::" {
			kind := Declaration_Kind.Constant
			next := tokens[i+2]
			procedure_index := i + 2
			// Procedure directives such as `#force_inline` sit between `::`
			// and `proc`, but do not change the declaration category.
			if next.text == "#" && i+4 < len(tokens) && tokens[i+3].kind == .Ident { procedure_index = i + 4 }
			if procedure_index < len(tokens) && tokens[procedure_index].text == "proc" do kind = .Procedure
			if procedure_index < len(tokens) && tokens[procedure_index].text == "proc" && procedure_index+1 < len(tokens) && tokens[procedure_index+1].text == "{" do kind = .Procedure_Group
			if next.text == "struct" || next.text == "union" || next.text == "enum" || next.text == "bit_set" || next.text == "bit_field" || next.text == "distinct" do kind = .Type
			if next.text == "[" || next.text == "^" do kind = .Type
			if next.text == "#" && i+4 < len(tokens) && tokens[i+3].text == "type" && tokens[i+4].text == "proc" do kind = .Type
			end := declaration_end_offset(tokens[:], i+2, len(file.source))
			append(&file.declarations, Declaration{name = strings.clone(token.text, allocator), kind = kind, docs = comment_docs(pending_comments[:], allocator), line = token.line, column = token.column, offset = token.offset, is_private = pending_private, source = strings.trim_right_space(file.source[token.offset:end])})
			clear(&pending_comments)
			pending_private = false
			i = declaration_token_skip(tokens[:], i, end)
			continue
		}
		// `name: Type = value` and `name := value` are ordinary top-level
		// variables. A following colon has already been handled as `::` above.
		if token.kind == .Ident && i+1 < len(tokens) && tokens[i+1].text == ":" {
			end := declaration_end_offset(tokens[:], i+2, len(file.source))
			append(&file.declarations, Declaration{name = strings.clone(token.text, allocator), kind = .Variable, docs = comment_docs(pending_comments[:], allocator), line = token.line, column = token.column, offset = token.offset, is_private = pending_private, source = strings.trim_right_space(file.source[token.offset:end])})
			clear(&pending_comments)
			pending_private = false
			i = declaration_token_skip(tokens[:], i, end)
			continue
		}
		if token.text != ";" && token.text != "@" && token.text != "(" && token.text != ")" do clear(&pending_comments)
	}
	if !package_found {
		append(&diagnostics, Diagnostic{kind = .Syntax, path = strings.clone(path, allocator), line = 1, column = 1, message = strings.clone("expected a package declaration", allocator)})
	}
	return
}

source_file_less :: proc(a, b: string) -> bool { return a < b }

is_skipped_directory :: proc(name: string) -> bool { return name == ".git" || name == "dist" || name == ".varde" }

// source_sloc counts non-blank, non-comment-only source lines. It deliberately
// stays separate from declaration parsing so the metric remains useful when a
// file contains syntax that Varde does not yet lower semantically.
source_sloc :: proc(source: string) -> int {
	sloc := 0
	in_block_comment := false
	line_start := 0
	for index := 0; index <= len(source); index += 1 {
		if index != len(source) && source[index] != '\n' do continue
		line := strings.trim_space(source[line_start:index])
		for len(line) > 0 {
			if in_block_comment {
				comment_end := strings.index(line, "*/")
				if comment_end < 0 do break
				in_block_comment = false
				line = strings.trim_space(line[comment_end + 2:])
				continue
			}
			if strings.has_prefix(line, "//") do break
			if strings.has_prefix(line, "/*") {
				comment_end := strings.index(line, "*/")
				if comment_end < 0 { in_block_comment = true; break }
				line = strings.trim_space(line[comment_end + 2:])
				continue
			}
			sloc += 1
			break
		}
		line_start = index + 1
	}
	return sloc
}

find_package :: proc(workspace: ^Workspace, path: string) -> int {
	for pkg, index in workspace.packages do if pkg.path == path do return index
	return -1
}

resolve_imports :: proc(workspace: ^Workspace, allocator: mem.Allocator) {
	for package_index := 0; package_index < len(workspace.packages); package_index += 1 {
		for file_index := 0; file_index < len(workspace.packages[package_index].files); file_index += 1 {
			file := &workspace.packages[package_index].files[file_index]
			for import_index := 0; import_index < len(file.imports); import_index += 1 {
				imp := &file.imports[import_index]
				if !strings.has_prefix(imp.path, ".") do continue // collection/import-name path
				candidate, err := filepath.join({filepath.dir(file.path), imp.path}, context.temp_allocator)
				if err != nil do continue
				clean, clean_err := filepath.clean(candidate, context.temp_allocator)
				if clean_err != nil do continue
				imp.target_package = find_package(workspace, clean)
				if imp.target_package < 0 {
					message := message_with_path("relative import does not resolve to a discovered package: ", imp.path, allocator)
					add_diagnostic(workspace, .Unresolved_Import, file.path, imp.line, imp.column, message, allocator)
					delete(message, allocator)
				}
			}
		}
	}
}

visit_cycles :: proc(workspace: ^Workspace, package_index: int, state: []u8, allocator: mem.Allocator) {
	state[package_index] = 1
	for &file in workspace.packages[package_index].files {
		for imp in file.imports {
			if imp.target_package < 0 do continue
			if state[imp.target_package] == 1 {
				message := message_with_path("relative import cycle reaches package: ", workspace.packages[imp.target_package].path, allocator)
				add_diagnostic(workspace, .Import_Cycle, file.path, imp.line, imp.column, message, allocator)
				delete(message, allocator)
			} else if state[imp.target_package] == 0 {
				visit_cycles(workspace, imp.target_package, state, allocator)
			}
		}
	}
	state[package_index] = 2
}

detect_cycles :: proc(workspace: ^Workspace, allocator: mem.Allocator) {
	state := make([]u8, len(workspace.packages), context.temp_allocator)
	for package_index := 0; package_index < len(workspace.packages); package_index += 1 do if state[package_index] == 0 do visit_cycles(workspace, package_index, state, allocator)
}

// Extract discovers .odin files, applies file tags, parses source-facing
// declarations and imports, and resolves relative package edges. It never
// invokes an external compiler or accepts an Odin executable path.
Extract :: proc(config: Config, allocator: mem.Allocator = context.allocator) -> Workspace {
	workspace := Workspace{packages = make([dynamic]Package, 0, 8, allocator), diagnostics = make([dynamic]Diagnostic, 0, 8, allocator)}
	root, root_err := os.get_absolute_path(config.root_path, context.temp_allocator)
	if root_err != nil {
		workspace.root_path = strings.clone(config.root_path, allocator)
		add_diagnostic(&workspace, .Discovery, config.root_path, 0, 0, "could not resolve source root", allocator)
		return workspace
	}
	workspace.root_path = strings.clone(root, allocator)
	target_os := config.target_os; if len(target_os) == 0 do target_os = host_os()
	target_arch := config.target_arch; if len(target_arch) == 0 do target_arch = host_arch()
	paths := make([dynamic]string, 0, 32, allocator)
	defer { for path in paths do delete(path, allocator); delete(paths) }
	w := os.walker_create(root)
	defer os.walker_destroy(&w)
	for info in os.walker_walk(&w) {
		if path, err := os.walker_error(&w); err != nil { add_diagnostic(&workspace, .Discovery, path, 0, 0, "could not traverse source path", allocator); continue }
		if info.type == .Directory && is_skipped_directory(info.name) { os.walker_skip_dir(&w); continue }
		if info.type == .Regular && strings.has_suffix(info.name, ".odin") && source_file_matches_target(info.name, target_os, target_arch) do append(&paths, strings.clone(info.fullpath, allocator))
	}
	slice.sort_by(paths[:], source_file_less)
	for path in paths {
		data, read_err := os.read_entire_file(path, context.temp_allocator)
		if read_err != nil { add_diagnostic(&workspace, .Discovery, path, 0, 0, "could not read source file", allocator); continue }
		source := string(data)
		include, is_test := file_matches_tags(source, target_os, target_arch)
		if !include || (is_test && !config.include_test_files) do continue
		workspace.sloc += source_sloc(source)
		file, parse_diagnostics := parse_source_file(path, source, allocator)
		for diagnostic in parse_diagnostics do append(&workspace.diagnostics, diagnostic)
		delete(parse_diagnostics)
		package_path := filepath.dir(path)
		package_index := find_package(&workspace, package_path)
		if package_index < 0 {
			package_index = len(workspace.packages)
			append(&workspace.packages, Package{name = strings.clone(file.package_name, allocator), path = strings.clone(package_path, allocator), files = make([dynamic]Source_File, 0, 4, allocator)})
		} else if workspace.packages[package_index].name != file.package_name {
			add_diagnostic(&workspace, .Package_Mismatch, path, 1, 1, "files in one directory must declare the same package", allocator)
		}
		append(&workspace.packages[package_index].files, file)
	}
	resolve_imports(&workspace, allocator)
	detect_cycles(&workspace, allocator)
	return workspace
}
