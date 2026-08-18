package extractor

import "core:mem"
import "core:strings"
import doc "../doc_format"

// Incomplete_Policy makes the source-mode contract explicit. A full semantic
// checker is still being grown; callers must opt into emitting an artifact
// that contains only facts Varde has actually established from source.
Incomplete_Policy :: enum {
	Reject,
	Emit,
}

Lower_Options :: struct {
	incomplete_policy: Incomplete_Policy,
}

Lower_Diagnostic :: struct {
	path:    string,
	line:    int,
	column: int,
	message: string,
	_type_index: u32, // internal: a named type which may resolve in the second pass
}

Lower_Result :: struct {
	document:    doc.Document,
	diagnostics: [dynamic]Lower_Diagnostic,
	complete:    bool,
}

Lower_Result_Destroy :: proc(result: ^Lower_Result, allocator: mem.Allocator = context.allocator) {
	if result == nil do return
	doc.Document_Destroy(&result.document, allocator)
	for &diagnostic in result.diagnostics {
		delete(diagnostic.path, allocator)
		delete(diagnostic.message, allocator)
	}
	delete(result.diagnostics)
	result^ = {}
}

lower_diagnostic :: proc(result: ^Lower_Result, file: Source_File, declaration: Declaration, message: string, allocator: mem.Allocator, type_index: u32 = 0) {
	append(&result.diagnostics, Lower_Diagnostic{
		path = strings.clone(file.path, allocator),
		line = declaration.line,
		column = declaration.column,
		message = strings.clone(message, allocator),
		_type_index = type_index,
	})
	result.complete = false
}

new_type :: proc(kind: u32, name: string, allocator: mem.Allocator) -> doc.Type {
	return doc.Type{
		kind = kind,
		name = name,
		types = make([dynamic]u32, 0, 2, allocator),
		entities = make([dynamic]u32, 0, 2, allocator),
		where_clauses = make([dynamic]string, 0, allocator),
		tags = make([dynamic]string, 0, allocator),
	}
}

new_entity :: proc(kind: u32, name, docs: string, file_index: u32, declaration: Declaration, allocator: mem.Allocator) -> doc.Entity {
	return doc.Entity{
		kind = kind,
		pos = {file = file_index, line = u32(declaration.line), column = u32(declaration.column), offset = u32(declaration.offset)},
		name = name,
		docs = docs,
		attributes = make([dynamic]doc.Attribute, 0, allocator),
		grouped_entities = make([dynamic]u32, 0, allocator),
		where_clauses = make([dynamic]string, 0, allocator),
	}
}

is_builtin_type :: proc(name: string) -> bool {
	switch name {
	case "bool", "b8", "b16", "b32", "b64", "int", "uint", "uintptr", "i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128", "f16", "f32", "f64", "complex32", "complex64", "complex128", "quaternion64", "quaternion128", "quaternion256", "rawptr", "cstring", "typeid", "any", "string", "rune": return true
	}
	return false
}

append_untyped_basic_type :: proc(document: ^doc.Document, value: string, allocator: mem.Allocator) -> u32 {
	text := strings.trim_space(value)
	name := ""
	if text == "true" || text == "false" {
		name = "untyped boolean"
	} else if len(text) >= 2 && text[0] == '"' && text[len(text)-1] == '"' {
		name = "untyped string"
	} else if len(text) >= 3 && text[0] == '\'' && text[len(text)-1] == '\'' {
		name = "untyped rune"
	} else {
		integer := len(text) > 0
		for ch in text do if !('0' <= ch && ch <= '9') && ch != '_' { integer = false; break }
		if integer do name = "untyped integer"
	}
	if len(name) == 0 do return 0
	typ := new_type(1, name, allocator)
	typ.flags = 1<<1 // OdinDocTypeFlag_Basic_untyped
	append(&document.types, typ)
	return u32(len(document.types)-1)
}

first_identifier :: proc(text: string) -> string {
	start := -1
	for ch, index in text {
		if is_ident_start(byte(ch)) {
			if start < 0 do start = index
		} else if start >= 0 {
			return text[start:index]
		}
	}
	if start >= 0 do return text[start:]
	return ""
}

source_after :: proc(source, marker: string) -> string {
	index := strings.index(source, marker)
	if index < 0 do return ""
	return strings.trim_space(source[index+len(marker):])
}

// The public artifact preserves initializers for presentation, but an
// incomplete source extractor must never turn a generated table or lookup
// blob into a multi-gigabyte documentation artifact. Type inference still
// receives the complete expression before this display-only excerpt is used.
SOURCE_INITIALIZER_DISPLAY_MAX_BYTES :: 256

source_initializer_excerpt :: proc(value: string) -> string {
	if len(value) <= SOURCE_INITIALIZER_DISPLAY_MAX_BYTES do return value
	return value[:SOURCE_INITIALIZER_DISPLAY_MAX_BYTES]
}

add_annotation_type :: proc(document: ^doc.Document, annotation: string, allocator: mem.Allocator) -> (type_index: u32, proven: bool) {
	text := strings.trim_space(annotation)
	if strings.has_prefix(text, "^") {
		element, element_proven := add_annotation_type(document, text[1:], allocator)
		if element == 0 do return 0, false
		pointer := new_type(4, "", allocator)
		append(&pointer.types, element)
		append(&document.types, pointer)
		return u32(len(document.types)-1), element_proven
	}
	if strings.has_prefix(text, "[^]") {
		element, element_proven := add_annotation_type(document, text[3:], allocator)
		if element == 0 do return 0, false
		pointer := new_type(22, "", allocator)
		append(&pointer.types, element)
		append(&document.types, pointer)
		return u32(len(document.types)-1), element_proven
	}
	if strings.has_prefix(text, "[]") {
		element, element_proven := add_annotation_type(document, text[2:], allocator)
		if element == 0 do return 0, false
		slice := new_type(7, "", allocator)
		append(&slice.types, element)
		append(&document.types, slice)
		return u32(len(document.types)-1), element_proven
	}
	if strings.has_prefix(text, "[dynamic]") {
		element, element_proven := add_annotation_type(document, text[len("[dynamic]"):], allocator)
		if element == 0 do return 0, false
		dynamic_array := new_type(8, "", allocator)
		append(&dynamic_array.types, element)
		append(&document.types, dynamic_array)
		return u32(len(document.types)-1), element_proven
	}
	name := first_identifier(text)
	if len(name) == 0 do return 0, false
	kind := u32(2) // named syntax; entity binding is deferred to resolution.
	if is_builtin_type(name) do kind = 1
	append(&document.types, new_type(kind, name, allocator))
	return u32(len(document.types)-1), is_builtin_type(name)
}

append_member :: proc(document: ^doc.Document, owner_index, file_index: u32, declaration: Declaration, token: Token, annotation: string, allocator: mem.Allocator) -> bool {
	type_index, proven := add_annotation_type(document, annotation, allocator)
	entity := doc.Entity{
		kind = 2,
		pos = {file = file_index, line = u32(declaration.line + token.line - 1), column = u32(token.column), offset = u32(declaration.offset + token.offset)},
		name = token.text,
		type = type_index,
		attributes = make([dynamic]doc.Attribute, 0, allocator),
		grouped_entities = make([dynamic]u32, 0, allocator),
		where_clauses = make([dynamic]string, 0, allocator),
	}
	append(&document.entities, entity)
	append(&document.types[owner_index].entities, u32(len(document.entities)-1))
	return proven
}

// parse_members recognizes direct `name: Type` members. It intentionally
// leaves grouped names, defaults, directives, and polymorphic forms for the
// semantic parser; callers receive `false` when a member is not a builtin.
parse_members :: proc(document: ^doc.Document, owner_index, file_index: u32, declaration: Declaration, allocator: mem.Allocator) -> bool {
	lexer := lexer_init(declaration.source)
	tokens := make([dynamic]Token, 0, 16, context.temp_allocator)
	defer delete(tokens)
	for { token := lexer_next(&lexer); append(&tokens, token); if token.kind == .End do break }
	open_index := -1
	for token, index in tokens do if token.text == "{" { open_index = index; break }
	if open_index < 0 do return true
	depth := 0
	proven := true
	for index := open_index; index < len(tokens); index += 1 {
		token := tokens[index]
		if token.text == "{" { depth += 1; continue }
		if token.text == "}" { depth -= 1; if depth == 0 do break; continue }
		if depth != 1 || token.kind != .Ident do continue
		if index+2 < len(tokens) && tokens[index+1].text == ":" && tokens[index+2].kind == .Ident {
			proven &&= append_member(document, owner_index, file_index, declaration, token, tokens[index+2].text, allocator)
		}
	}
	return proven
}

parse_procedure :: proc(document: ^doc.Document, parameters_index, procedure_index, file_index: u32, declaration: Declaration, allocator: mem.Allocator) -> bool {
	lexer := lexer_init(declaration.source)
	tokens := make([dynamic]Token, 0, 16, context.temp_allocator)
	defer delete(tokens)
	for { token := lexer_next(&lexer); append(&tokens, token); if token.kind == .End do break }
	open_index, close_index := -1, -1
	for token, index in tokens {
		if token.text == "(" && open_index < 0 { open_index = index; continue }
		if token.text == ")" && open_index >= 0 { close_index = index; break }
	}
	if open_index < 0 || close_index < 0 do return false
	proven := true
	for index := open_index+1; index+2 < close_index; index += 1 {
		token := tokens[index]
		if token.kind == .Ident && tokens[index+1].text == ":" && tokens[index+2].kind == .Ident {
			proven &&= append_member(document, parameters_index, file_index, declaration, token, tokens[index+2].text, allocator)
		}
	}
	if close_index+3 < len(tokens) && tokens[close_index+1].text == "-" && tokens[close_index+2].text == ">" && tokens[close_index+3].kind == .Ident {
		results := new_type(13, "", allocator)
		result_name := tokens[close_index+3].text
		result_index, result_proven := add_annotation_type(document, result_name, allocator)
		append(&results.types, result_index)
		append(&document.types, results)
		append(&document.types[procedure_index].types, u32(len(document.types)-1))
		proven &&= result_proven
	}
	return proven
}

add_syntactic_type :: proc(document: ^doc.Document, file_index: u32, declaration: Declaration, allocator: mem.Allocator) -> (type_index: u32, proven: bool) {
	source := declaration.source
	#partial switch declaration.kind {
	case .Type:
		kind := u32(10) // struct
		if strings.contains(source, ":: union") do kind = 11
		if strings.contains(source, ":: enum") do kind = 12
		if strings.contains(source, ":: bit_set") do kind = 15
		if strings.contains(source, ":: bit_field") do kind = 25
		append(&document.types, new_type(kind, declaration.name, allocator))
		index := u32(len(document.types)-1)
		return index, parse_members(document, index, file_index, declaration, allocator)
	case .Procedure:
		parameters := new_type(13, "", allocator)
		append(&document.types, parameters)
		parameters_index := u32(len(document.types)-1)
		procedure := new_type(14, "", allocator)
		append(&procedure.types, parameters_index)
		append(&document.types, procedure)
		procedure_index := u32(len(document.types)-1)
		return procedure_index, parse_procedure(document, parameters_index, procedure_index, file_index, declaration, allocator)
	case .Variable:
		annotation := source_after(source, ":")
		if strings.has_prefix(annotation, "=") do return 0, false
		return add_annotation_type(document, annotation, allocator)
	case:
		return 0, false
	}
}

entity_kind :: proc(kind: Declaration_Kind) -> u32 {
	#partial switch kind {
	case .Constant: return 1
	case .Variable: return 2
	case .Type: return 3
	case .Procedure: return 4
	case: return 0
	}
}

// resolve_unique_named_types adds the doc-format definition edge only when a
// name has exactly one public type definition in this extracted document.
// This deliberately leaves duplicate and import-qualified names unresolved:
// choosing one by iteration order would fabricate semantic information.
resolve_unique_named_types :: proc(document: ^doc.Document) {
	for type_index := 1; type_index < len(document.types); type_index += 1 {
		typ := &document.types[type_index]
		if typ.kind != 2 || len(typ.name) == 0 || len(typ.entities) > 0 do continue
		match_index := u32(0)
		match_count := 0
		for entity, entity_index in document.entities[1:] {
			if entity.kind == 3 && entity.name == typ.name {
				match_index = u32(entity_index + 1)
				match_count += 1
			}
		}
		if match_count == 1 {
			append(&typ.entities, match_index)
			append(&typ.types, document.entities[match_index].type)
		}
	}
}

type_is_resolved :: proc(document: ^doc.Document, type_index: u32, depth := 0) -> bool {
	if type_index == 0 || int(type_index) >= len(document.types) || depth > 16 do return false
	typ := document.types[type_index]
	if typ.kind == 2 do return len(typ.entities) == 1 && len(typ.types) == 1
	for child in typ.types do if child > 0 && !type_is_resolved(document, child, depth+1) do return false
	return true
}

discard_resolved_named_diagnostics :: proc(result: ^Lower_Result, allocator: mem.Allocator) {
	keep := 0
	for diagnostic in result.diagnostics {
		resolved := diagnostic._type_index > 0 && type_is_resolved(&result.document, diagnostic._type_index)
		if resolved {
			delete(diagnostic.path, allocator)
			delete(diagnostic.message, allocator)
			continue
		}
		result.diagnostics[keep] = diagnostic
		keep += 1
	}
	resize(&result.diagnostics, keep)
	result.complete = len(result.diagnostics) == 0
}

// Lower converts the source facts collected by Extract into the public
// doc-format model. It does not call the Odin compiler. Struct/union/enum
// kind, procedure shape, primitive variable annotations, docs, positions, and
// declaration ordering are represented structurally. Any unresolved type or
// constant expression records a diagnostic and marks the result incomplete.
Lower :: proc(workspace: ^Workspace, options: Lower_Options, allocator: mem.Allocator = context.allocator) -> Lower_Result {
	result := Lower_Result{document = doc.Document_Init(allocator), diagnostics = make([dynamic]Lower_Diagnostic, 0, 8, allocator), complete = true}
	if workspace == nil do return result
	for source_package in workspace.packages {
		package_index := u32(len(result.document.packages))
		out_package := doc.Package{
			fullpath = source_package.path,
			name = source_package.name,
			files = make([dynamic]u32, 0, len(source_package.files), allocator),
			entries = make([dynamic]doc.Scope_Entry, 0, 16, allocator),
		}
		for file in source_package.files {
			file_index := u32(len(result.document.files))
			append(&result.document.files, doc.File{pkg = package_index, name = file.path})
			append(&out_package.files, file_index)
			for declaration in file.declarations {
				kind := entity_kind(declaration.kind)
				if kind == 0 do continue
				entity := new_entity(kind, declaration.name, declaration.docs, file_index, declaration, allocator)
				type_index, proven := add_syntactic_type(&result.document, file_index, declaration, allocator)
				entity.type = type_index
				if declaration.kind == .Constant {
					initializer := source_after(declaration.source, "::")
					entity.type = append_untyped_basic_type(&result.document, initializer, allocator)
					entity.init_string = source_initializer_excerpt(initializer)
					if entity.type == 0 do lower_diagnostic(&result, file, declaration, "constant type was not resolved; emitted as incomplete source syntax", allocator)
				} else if !proven {
					lower_diagnostic(&result, file, declaration, "declaration type was not semantically resolved; emitted as incomplete source syntax", allocator, entity.type)
				}
				append(&result.document.entities, entity)
				entity_index := u32(len(result.document.entities)-1)
				append(&out_package.entries, doc.Scope_Entry{name = declaration.name, entity = entity_index})
			}
		}
		append(&result.document.packages, out_package)
	}
	resolve_unique_named_types(&result.document)
	discard_resolved_named_diagnostics(&result, allocator)
	if !result.complete && options.incomplete_policy == .Reject {
		doc.Document_Destroy(&result.document, allocator)
		result.document = doc.Document_Init(allocator)
	}
	return result
}
