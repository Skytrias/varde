package extractor

import "core:mem"
import "core:strings"
import "core:fmt"
import "core:strconv"
import "core:time"
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
	duration_ms: f64,
}

Alias_Pending :: struct {
	package_index: u32,
	target_package: i32,
	entity_index:  u32,
	file:          Source_File,
	declaration:   Declaration,
	target:        string,
}

Procedure_Group_Pending :: struct {
	package_index: u32,
	entity_index:  u32,
	file:          Source_File,
	declaration:   Declaration,
}

Constant_Pending :: struct {
	package_index: u32,
	entity_index:  u32,
	file:          Source_File,
	declaration:   Declaration,
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
	case "bool", "b8", "b16", "b32", "b64", "int", "uint", "uintptr", "i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128", "i16le", "i16be", "i32le", "i32be", "i64le", "i64be", "u16le", "u16be", "u32le", "u32be", "u64le", "u64be", "f16", "f32", "f64", "complex32", "complex64", "complex128", "quaternion64", "quaternion128", "quaternion256", "rawptr", "cstring", "typeid", "any", "string", "rune": return true
	}
	return false
}

append_untyped_basic_type :: proc(document: ^doc.Document, value: string, allocator: mem.Allocator) -> u32 {
	text := strings.trim_space(value)
	name := ""
	if text == "true" || text == "false" {
		name = "untyped boolean"
	} else if len(text) >= 2 && ((text[0] == '"' && text[len(text)-1] == '"') || (text[0] == '`' && text[len(text)-1] == '`')) {
		name = "untyped string"
	} else if len(text) >= 3 && text[0] == '\'' && text[len(text)-1] == '\'' {
		name = "untyped rune"
	} else {
		numeric, floating, digits := len(text) > 0 && '0' <= text[0] && text[0] <= '9', false, 0
		base, start := 10, 0
		if len(text) >= 2 && text[0] == '0' {
			if text[1] == 'x' || text[1] == 'X' { base = 16; start = 2 }
			if text[1] == 'o' || text[1] == 'O' { base = 8; start = 2 }
			if text[1] == 'b' || text[1] == 'B' { base = 2; start = 2 }
		}
		for ch, index in text {
			if index < start do continue
			is_digit := ('0' <= ch && ch <= '9') || (base == 16 && (('a' <= ch && ch <= 'f') || ('A' <= ch && ch <= 'F')))
			if is_digit {
				if (base == 2 && ch > '1') || (base == 8 && ch > '7') { numeric = false; break }
				digits += 1; continue
			}
			if ch == '_' do continue
			if ch == '.' && (base == 10 || base == 16) { floating = true; continue }
			if (ch == 'e' || ch == 'E') && base == 10 { floating = true; continue }
			if (ch == 'p' || ch == 'P') && base == 16 { floating = true; continue }
			if (ch == '+' || ch == '-') && index > start && (text[index-1] == 'e' || text[index-1] == 'E' || text[index-1] == 'p' || text[index-1] == 'P') do continue
			numeric = false; break
		}
		if numeric && digits > 0 do name = "untyped float" if floating else "untyped integer"
	}
	if len(name) == 0 do return 0
	typ := new_type(1, name, allocator)
	typ.flags = 1<<1 // OdinDocTypeFlag_Basic_untyped
	append(&document.types, typ)
	return u32(len(document.types)-1)
}

append_untyped_integer_type :: proc(document: ^doc.Document, allocator: mem.Allocator) -> u32 {
	typ := new_type(1, "untyped integer", allocator)
	typ.flags = 1<<1 // OdinDocTypeFlag_Basic_untyped
	append(&document.types, typ)
	return u32(len(document.types)-1)
}

has_builtin_call :: proc(text, name: string) -> bool {
	return len(text) > len(name) && strings.has_prefix(text, name) && text[len(name)] == '('
}

// integer_literal_expression recognizes only arithmetic composed of integer
// literals, grouping, and integer operators. It deliberately rejects names,
// calls, selectors, and comparisons: those require checker semantics.
integer_literal_expression :: proc(value: string) -> bool {
	text := strings.trim_space(value)
	expecting_operand := true
	paren_depth := 0
	saw_literal := false
	for index := 0; index < len(text); {
		ch := text[index]
		if is_space(ch) { index += 1; continue }
		if ch == '/' && index+1 < len(text) && text[index+1] == '/' { break }
		if ch == '/' && index+1 < len(text) && text[index+1] == '*' {
			index += 2
			for index+1 < len(text) && !(text[index] == '*' && text[index+1] == '/') do index += 1
			if index+1 >= len(text) do return false
			index += 2
			continue
		}
		if expecting_operand {
			if ch == '+' || ch == '-' || ch == '~' { index += 1; continue }
			if ch == '(' { paren_depth += 1; index += 1; continue }
			if ch < '0' || ch > '9' do return false
			start := index
			index += 1
			for index < len(text) && (('0' <= text[index] && text[index] <= '9') || ('a' <= text[index] && text[index] <= 'f') || ('A' <= text[index] && text[index] <= 'F') || text[index] == 'x' || text[index] == 'X' || text[index] == 'o' || text[index] == 'O' || text[index] == 'b' || text[index] == 'B' || text[index] == '_') do index += 1
			if _, ok := strconv.parse_int(text[start:index]); !ok do return false
			saw_literal = true
			expecting_operand = false
			continue
		}
		if ch == ')' {
			if paren_depth == 0 do return false
			paren_depth -= 1
			index += 1
			continue
		}
		if ch == '<' || ch == '>' {
			if index+1 >= len(text) || text[index+1] != ch do return false
			index += 2
			expecting_operand = true
			continue
		}
		if ch == '+' || ch == '-' || ch == '*' || ch == '/' || ch == '%' || ch == '&' || ch == '|' || ch == '^' {
			index += 1
			expecting_operand = true
			continue
		}
		return false
	}
	return saw_literal && !expecting_operand && paren_depth == 0
}

// floating_literal_expression has the same deliberately narrow boundary as
// integer_literal_expression, but admits only arithmetic over float literals.
floating_literal_expression :: proc(value: string) -> bool {
	text := strings.trim_space(value)
	expecting_operand := true
	paren_depth := 0
	saw_float := false
	for index := 0; index < len(text); {
		ch := text[index]
		if is_space(ch) { index += 1; continue }
		if ch == '/' && index+1 < len(text) && text[index+1] == '/' { break }
		if ch == '/' && index+1 < len(text) && text[index+1] == '*' {
			index += 2
			for index+1 < len(text) && !(text[index] == '*' && text[index+1] == '/') do index += 1
			if index+1 >= len(text) do return false
			index += 2
			continue
		}
		if expecting_operand {
			if ch == '+' || ch == '-' { index += 1; continue }
			if ch == '(' { paren_depth += 1; index += 1; continue }
			if ch < '0' || ch > '9' do return false
			start := index
			_, width, ok := strconv.parse_f64_prefix(text[index:])
			if !ok || width == 0 do return false
			index += width
			literal := text[start:index]
			if !strings.contains(literal, ".") && !strings.contains(literal, "e") && !strings.contains(literal, "E") do return false
			saw_float = true
			expecting_operand = false
			continue
		}
		if ch == ')' {
			if paren_depth == 0 do return false
			paren_depth -= 1
			index += 1
			continue
		}
		if ch == '+' || ch == '-' || ch == '*' || ch == '/' || ch == '%' {
			index += 1
			expecting_operand = true
			continue
		}
		return false
	}
	return saw_float && !expecting_operand && paren_depth == 0
}

parse_decimal_count :: proc(value: string) -> (i64, bool) {
	text := strings.trim_space(value)
	if len(text) == 0 do return 0, false
	count := i64(0)
	digits := 0
	for ch in text {
		if ch == '_' do continue
		if ch < '0' || ch > '9' do return 0, false
		count = count * 10 + i64(ch - '0')
		digits += 1
	}
	return count, digits > 0
}

// Builtin conversions and compound literals establish their type from source
// syntax. This is intentionally narrower than expression evaluation: a call
// such as `factory()` still needs checker information and remains unresolved.
append_constant_type :: proc(document: ^doc.Document, value: string, allocator: mem.Allocator) -> u32 {
	text := strings.trim_space(value)
	if len(text) > 0 && (text[0] == '+' || text[0] == '-') do text = strings.trim_space(text[1:])
	if basic := append_untyped_basic_type(document, text, allocator); basic != 0 do return basic
	if has_builtin_call(text, "size_of") do return append_untyped_integer_type(document, allocator)
	if integer_literal_expression(text) do return append_untyped_integer_type(document, allocator)
	if floating_literal_expression(text) {
		typ := new_type(1, "untyped float", allocator)
		typ.flags = 1<<1 // OdinDocTypeFlag_Basic_untyped
		append(&document.types, typ)
		return u32(len(document.types)-1)
	}
	name := type_name_prefix(text)
	if len(name) == 0 do return 0
	remaining := strings.trim_space(text[len(name):])
	if len(remaining) > 0 && (remaining[0] == '{' || (remaining[0] == '(' && is_builtin_type(name))) {
		kind := u32(2)
		if is_builtin_type(name) do kind = 1
		append(&document.types, new_type(kind, name, allocator))
		return u32(len(document.types)-1)
	}
	return 0
}

// type_name_prefix preserves the authored spelling of qualified type names
// (for example `json.Raw_Value`) instead of reducing it to the import alias.
// Binding that name to a declaration is a separate semantic question.
type_name_prefix :: proc(text: string) -> string {
	end := 0
	expect_identifier_start := true
	for ch, index in text {
		if expect_identifier_start {
			if !is_ident_start(byte(ch)) do break
			expect_identifier_start = false
			end = index + 1
			continue
		}
		if is_ident_continue(byte(ch)) { end = index + 1; continue }
		if ch == '.' { expect_identifier_start = true; end = index + 1; continue }
		break
	}
	if end == 0 || expect_identifier_start do return ""
	return text[:end]
}

source_after :: proc(source, marker: string) -> string {
	index := strings.index(source, marker)
	if index < 0 do return ""
	return strings.trim_space(source[index+len(marker):])
}

source_initializer :: proc(source: string) -> string {
	index := strings.index(source, "=")
	if index < 0 do return ""
	return strings.trim_space(source[index+1:])
}

direct_alias_target :: proc(initializer: string) -> string {
	text := strings.trim_space(initializer)
	if comment := strings.index(text, "//"); comment >= 0 do text = strings.trim_space(text[:comment])
	target := type_name_prefix(text)
	if len(target) == 0 || len(strings.trim_space(text[len(target):])) > 0 do return ""
	return target
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

add_bit_set_type :: proc(document: ^doc.Document, text: string, allocator: mem.Allocator) -> (type_index: u32, proven: bool) {
	if !strings.has_prefix(text, "bit_set[") do return 0, false
	close := strings.index(text, "]")
	if close <= len("bit_set[") do return 0, false
	body := strings.trim_space(text[len("bit_set["):close])
	element_text, backing_text := body, ""
	if separator := strings.index(body, ";"); separator >= 0 {
		element_text = strings.trim_space(body[:separator])
		backing_text = strings.trim_space(body[separator+1:])
	}
	element, element_proven := add_annotation_type(document, element_text, allocator)
	if element == 0 do return 0, false
	set_type := new_type(15, "", allocator)
	append(&set_type.types, element)
	proven = element_proven
	if len(backing_text) > 0 {
		backing, backing_proven := add_annotation_type(document, backing_text, allocator)
		if backing == 0 do return 0, false
		append(&set_type.types, backing)
		proven &&= backing_proven
	}
	append(&document.types, set_type)
	return u32(len(document.types)-1), proven
}

add_annotation_type :: proc(document: ^doc.Document, annotation: string, allocator: mem.Allocator) -> (type_index: u32, proven: bool) {
	text := strings.trim_space(annotation)
	if strings.has_prefix(text, "bit_set[") do return add_bit_set_type(document, text, allocator)
	if strings.has_prefix(text, "proc") {
		// A procedure annotation is a first-class field type, not an unresolved
		// named `proc`. Its parameter entity names borrow this source string, so
		// retain it with the lowered document.
		source := strings.clone(strings.concatenate({"_ :: ", text}, context.temp_allocator), allocator)
		append(&document._owned_strings, source)
		return append_procedure_type(document, 0, Declaration{source = source}, allocator)
	}
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
	if strings.has_prefix(text, "[") {
		close := strings.index(text, "]")
		if close <= 1 do return 0, false
		count_text := strings.trim_space(text[1:close])
		count, count_is_decimal := parse_decimal_count(count_text)
		element, element_proven := add_annotation_type(document, text[close+1:], allocator)
		if element == 0 || len(count_text) == 0 do return 0, false
		array := new_type(5, "", allocator)
		append(&array.types, element)
		if count_is_decimal {
			array.elem_count_len = 1
			array.elem_counts[0] = count
		} else {
			// The public format represents a non-literal array bound as the
			// second type child. Keep the source expression verbatim: evaluating
			// a named constant (or an expression such as `SIZE * 2`) would require
			// checker information, but its authored spelling is already known.
			bound := new_type(2, count_text, allocator)
			append(&document.types, bound)
			append(&array.types, u32(len(document.types)-1))
		}
		append(&document.types, array)
		return u32(len(document.types)-1), element_proven
	}
	name := type_name_prefix(text)
	if len(name) == 0 do return 0, false
	// These are type constructors, not named types. Keep the explicit
	// incomplete result until their full child syntax can be represented.
	if name == "map" do return 0, false
	kind := u32(2) // named syntax; entity binding is deferred to resolution.
	if is_builtin_type(name) do kind = 1
	append(&document.types, new_type(kind, name, allocator))
	// A name is a complete syntactic type fact even when the checker would be
	// needed to bind it to an imported declaration. The artifact keeps the
	// spelling and only adds a definition edge when local resolution is unique.
	return u32(len(document.types)-1), true
}

append_member :: proc(document: ^doc.Document, owner_index, file_index: u32, declaration: Declaration, token: Token, annotation, docs: string, allocator: mem.Allocator) -> bool {
	type_index, proven := add_annotation_type(document, annotation, allocator)
	if len(docs) > 0 do append(&document._owned_strings, docs)
	entity := doc.Entity{
		kind = 2,
		pos = {file = file_index, line = u32(declaration.line + token.line - 1), column = u32(token.column), offset = u32(declaration.offset + token.offset)},
		name = token.text,
		type = type_index,
		docs = docs,
		attributes = make([dynamic]doc.Attribute, 0, allocator),
		grouped_entities = make([dynamic]u32, 0, allocator),
		where_clauses = make([dynamic]string, 0, allocator),
	}
	append(&document.entities, entity)
	append(&document.types[owner_index].entities, u32(len(document.entities)-1))
	return proven
}

// Enum cases are entities in the public doc format too, but unlike record
// fields they have no annotation. Keep their authored values and leading
// comments so renderers can present an enum as a sequence of cases instead of
// an empty record-like shell.
append_enum_member :: proc(document: ^doc.Document, owner_index, file_index: u32, declaration: Declaration, token: Token, initializer, comment, docs: string, allocator: mem.Allocator) {
	if len(docs) > 0 do append(&document._owned_strings, docs)
	if len(comment) > 0 do append(&document._owned_strings, comment)
	entity := doc.Entity{
		kind = 1,
		pos = {file = file_index, line = u32(declaration.line + token.line - 1), column = u32(token.column), offset = u32(declaration.offset + token.offset)},
		name = token.text,
		init_string = initializer,
		comment = comment,
		docs = docs,
		attributes = make([dynamic]doc.Attribute, 0, allocator),
		grouped_entities = make([dynamic]u32, 0, allocator),
		where_clauses = make([dynamic]string, 0, allocator),
	}
	append(&document.entities, entity)
	append(&document.types[owner_index].entities, u32(len(document.entities)-1))
}

append_union_variant :: proc(document: ^doc.Document, owner_index, file_index: u32, declaration: Declaration, token: Token, type_index: u32, comment, docs: string, allocator: mem.Allocator) {
	if len(docs) > 0 do append(&document._owned_strings, docs)
	if len(comment) > 0 do append(&document._owned_strings, comment)
	entity := doc.Entity{
		kind = 2,
		pos = {file = file_index, line = u32(declaration.line + token.line - 1), column = u32(token.column), offset = u32(declaration.offset + token.offset)},
		type = type_index,
		comment = comment,
		docs = docs,
		attributes = make([dynamic]doc.Attribute, 0, allocator),
		grouped_entities = make([dynamic]u32, 0, allocator),
		where_clauses = make([dynamic]string, 0, allocator),
	}
	append(&document.entities, entity)
	append(&document.types[owner_index].entities, u32(len(document.entities)-1))
}

append_bit_field_member :: proc(document: ^doc.Document, owner_index, file_index: u32, declaration: Declaration, token: Token, width, comment, docs: string, allocator: mem.Allocator) {
	if len(docs) > 0 do append(&document._owned_strings, docs)
	if len(comment) > 0 do append(&document._owned_strings, comment)
	entity := doc.Entity{
		kind = 2,
		pos = {file = file_index, line = u32(declaration.line + token.line - 1), column = u32(token.column), offset = u32(declaration.offset + token.offset)},
		name = token.text,
		init_string = width,
		comment = comment,
		docs = docs,
		attributes = make([dynamic]doc.Attribute, 0, allocator),
		grouped_entities = make([dynamic]u32, 0, allocator),
		where_clauses = make([dynamic]string, 0, allocator),
	}
	append(&document.entities, entity)
	append(&document.types[owner_index].entities, u32(len(document.entities)-1))
}

member_annotation :: proc(tokens: []Token, start_index: int, source: string) -> string {
	if start_index < 0 || start_index >= len(tokens) do return ""
	start := tokens[start_index].offset
	end := len(source)
	nesting := 0
	for index := start_index; index < len(tokens); index += 1 {
		token := tokens[index]
		if token.kind == .End { end = token.offset; break }
		if token.text == "(" || token.text == "[" || token.text == "{" { nesting += 1; continue }
		if token.text == ")" || token.text == "]" || token.text == "}" { if nesting > 0 { nesting -= 1; continue }; end = token.offset; break }
		if nesting == 0 && (token.text == "," || token.text == ";" || token.kind == .Comment) { end = token.offset; break }
	}
	return strings.trim_space(source[start:end])
}

enum_member_initializer :: proc(tokens: []Token, member_index: int, source: string) -> string {
	if member_index+2 >= len(tokens) || tokens[member_index+1].text != "=" do return ""
	start := tokens[member_index+2].offset
	end := len(source)
	nesting := 0
	for index := member_index+2; index < len(tokens); index += 1 {
		token := tokens[index]
		if token.kind == .End { end = token.offset; break }
		if token.text == "(" || token.text == "[" || token.text == "{" { nesting += 1; continue }
		if token.text == ")" || token.text == "]" || token.text == "}" {
			if nesting > 0 { nesting -= 1; continue }
			end = token.offset
			break
		}
		if nesting == 0 && (token.text == "," || token.text == ";" || token.kind == .Comment) { end = token.offset; break }
	}
	return strings.trim_space(source[start:end])
}

// A comment after the enum separator belongs to that case, whereas a comment
// on the next line before a case becomes its documentation. This mirrors the
// parser distinction that the public .odin-doc format exposes as `comment`
// and `docs` respectively.
enum_member_comment :: proc(tokens: []Token, member_index: int, allocator: mem.Allocator) -> string {
	nesting := 0
	for index := member_index + 1; index < len(tokens); index += 1 {
		token := tokens[index]
		if token.kind == .End do break
		if token.text == "(" || token.text == "[" || token.text == "{" { nesting += 1; continue }
		if token.text == ")" || token.text == "]" || token.text == "}" {
			if nesting > 0 { nesting -= 1; continue }
			break
		}
		if nesting != 0 do continue
		if token.kind == .Comment do return comment_docs(tokens[index:index+1], allocator)
		if token.text == "," || token.text == ";" {
			if index+1 < len(tokens) && tokens[index+1].kind == .Comment && tokens[index+1].line == token.line do return comment_docs(tokens[index+1:index+2], allocator)
			break
		}
	}
	return ""
}

// Source mode is not a compiler, but direct integer literals and implicit
// enum increments are complete syntactic facts. Canonicalizing those values
// gives source-generated sites the same useful decimal values as .odin-doc
// input without pretending to evaluate arbitrary expressions.
enum_member_display_initializer :: proc(initializer: string, next_value: i64, has_next_value: bool) -> (value: string, next: i64, known: bool) {
	text := strings.trim_space(initializer)
	if len(text) == 0 {
		if !has_next_value do return "", 0, false
		return fmt.tprintf("%d", next_value), next_value + 1, true
	}
	if integer, ok := strconv.parse_int(text); ok do return fmt.tprintf("%d", integer), i64(integer) + 1, true
	return text, 0, false
}

// parse_members recognizes direct `name: Type` members, including compound
// annotations such as `[4]u32`. It intentionally leaves grouped names and
// polymorphic forms for the semantic parser; callers receive `false` when the
// member syntax cannot be represented by the source lowerer.
parse_members :: proc(document: ^doc.Document, owner_index, file_index: u32, declaration: Declaration, allocator: mem.Allocator) -> bool {
	lexer := lexer_init(declaration.source)
	tokens := make([dynamic]Token, 0, 16, context.temp_allocator)
	defer delete(tokens)
	for { token := lexer_next(&lexer); append(&tokens, token); if token.kind == .End do break }
	pending_comments := make([dynamic]Token, 0, 2, context.temp_allocator)
	defer delete(pending_comments)
	open_index := -1
	for token, index in tokens do if token.text == "{" { open_index = index; break }
	if open_index < 0 do return true
	depth := 0
	previous_non_comment_line := 0
	proven := true
	for index := open_index; index < len(tokens); index += 1 {
		token := tokens[index]
		if token.text == "{" { depth += 1; continue }
		if token.text == "}" { depth -= 1; if depth == 0 do break; if depth != 1 do clear(&pending_comments); previous_non_comment_line = token.line; continue }
		if token.kind == .Comment {
			// A same-line comment belongs to the preceding field. Only comments
			// starting a fresh line are documentation for the following field.
			if depth == 1 && token.line != previous_non_comment_line do append(&pending_comments, token)
			continue
		}
		if depth != 1 { clear(&pending_comments); previous_non_comment_line = token.line; continue }
		if index+2 < len(tokens) && tokens[index+1].text == ":" {
			member_docs := comment_docs(pending_comments[:], allocator)
			annotation := member_annotation(tokens[:], index+2, declaration.source)
			proven &&= append_member(document, owner_index, file_index, declaration, token, annotation, member_docs, allocator)
			clear(&pending_comments)
		}
		previous_non_comment_line = token.line
	}
	return proven
}

// Unions carry a list of variant types rather than record fields. Parse each
// direct comma-separated body item so source-generated documents retain the
// same shape as compiler-produced union data.
parse_union_members :: proc(document: ^doc.Document, owner_index, file_index: u32, declaration: Declaration, allocator: mem.Allocator) -> bool {
	lexer := lexer_init(declaration.source)
	tokens := make([dynamic]Token, 0, 16, context.temp_allocator)
	defer delete(tokens)
	for { token := lexer_next(&lexer); append(&tokens, token); if token.kind == .End do break }
	open_index := -1
	for token, index in tokens do if token.text == "{" { open_index = index; break }
	if open_index < 0 do return true
	depth := 0
	expecting_variant := false
	proven := true
	pending_comments := make([dynamic]Token, 0, 2, context.temp_allocator)
	defer delete(pending_comments)
	previous_non_comment_line := 0
	for index := open_index; index < len(tokens); index += 1 {
		token := tokens[index]
		if token.text == "{" { depth += 1; if depth == 1 do expecting_variant = true; continue }
		if token.text == "}" { depth -= 1; if depth == 0 do break; previous_non_comment_line = token.line; continue }
		if token.kind == .Comment {
			if depth == 1 && expecting_variant && token.line != previous_non_comment_line do append(&pending_comments, token)
			continue
		}
		if depth != 1 { clear(&pending_comments); previous_non_comment_line = token.line; continue }
		if token.text == "," || token.text == ";" { expecting_variant = true; previous_non_comment_line = token.line; continue }
		if !expecting_variant do continue
		annotation := member_annotation(tokens[:], index, declaration.source)
		variant, variant_proven := add_annotation_type(document, annotation, allocator)
		if variant == 0 { proven = false } else {
			append(&document.types[owner_index].types, variant)
			append_union_variant(document, owner_index, file_index, declaration, token, variant, enum_member_comment(tokens[:], index, allocator), comment_docs(pending_comments[:], allocator), allocator)
			proven &&= variant_proven
		}
		clear(&pending_comments)
		expecting_variant = false
		previous_non_comment_line = token.line
	}
	return proven
}

parse_bit_field_members :: proc(document: ^doc.Document, owner_index, file_index: u32, declaration: Declaration, allocator: mem.Allocator) -> bool {
	lexer := lexer_init(declaration.source)
	tokens := make([dynamic]Token, 0, 16, context.temp_allocator)
	defer delete(tokens)
	for { token := lexer_next(&lexer); append(&tokens, token); if token.kind == .End do break }
	pending_comments := make([dynamic]Token, 0, 2, context.temp_allocator)
	defer delete(pending_comments)
	open_index := -1
	for token, index in tokens do if token.text == "{" { open_index = index; break }
	if open_index < 0 do return true
	depth := 0
	previous_non_comment_line := 0
	for index := open_index; index < len(tokens); index += 1 {
		token := tokens[index]
		if token.text == "{" { depth += 1; continue }
		if token.text == "}" { depth -= 1; if depth == 0 do break; previous_non_comment_line = token.line; continue }
		if token.kind == .Comment {
			if depth == 1 && token.line != previous_non_comment_line do append(&pending_comments, token)
			continue
		}
		if depth != 1 { clear(&pending_comments); previous_non_comment_line = token.line; continue }
		if index+2 < len(tokens) && tokens[index+1].text == ":" {
			append_bit_field_member(document, owner_index, file_index, declaration, token, member_annotation(tokens[:], index+2, declaration.source), enum_member_comment(tokens[:], index, allocator), comment_docs(pending_comments[:], allocator), allocator)
			clear(&pending_comments)
		}
		previous_non_comment_line = token.line
	}
	return true
}

// parse_enum_members recognizes one direct enum case per comma-separated
// item. Case values deliberately remain authored source text: evaluating an
// arbitrary constant expression would require compiler semantics, while the
// documentation format only needs the displayed initializer.
parse_enum_members :: proc(document: ^doc.Document, owner_index, file_index: u32, declaration: Declaration, allocator: mem.Allocator) -> bool {
	lexer := lexer_init(declaration.source)
	tokens := make([dynamic]Token, 0, 16, context.temp_allocator)
	defer delete(tokens)
	for { token := lexer_next(&lexer); append(&tokens, token); if token.kind == .End do break }
	pending_comments := make([dynamic]Token, 0, 2, context.temp_allocator)
	defer delete(pending_comments)
	open_index := -1
	for token, index in tokens do if token.text == "{" { open_index = index; break }
	if open_index < 0 do return true
	depth := 0
	previous_non_comment_line := 0
	expecting_member := false
	next_value := i64(0)
	has_next_value := true // Odin assigns the first omitted enum value zero.
	for index := open_index; index < len(tokens); index += 1 {
		token := tokens[index]
		if token.text == "{" { depth += 1; if depth == 1 do expecting_member = true; continue }
		if token.text == "}" {
			depth -= 1
			if depth == 0 do break
			if depth != 1 do clear(&pending_comments)
			previous_non_comment_line = token.line
			continue
		}
		if token.kind == .Comment {
			// Trailing comments describe the prior case; only comments before an
			// expected case become documentation for that following case.
			if depth == 1 && expecting_member && token.line != previous_non_comment_line do append(&pending_comments, token)
			continue
		}
		if depth != 1 { clear(&pending_comments); previous_non_comment_line = token.line; continue }
		if token.text == "," || token.text == ";" {
			expecting_member = true
			previous_non_comment_line = token.line
			continue
		}
		if expecting_member && token.kind == .Ident {
			member_docs := comment_docs(pending_comments[:], allocator)
			initializer, next, known := enum_member_display_initializer(enum_member_initializer(tokens[:], index, declaration.source), next_value, has_next_value)
			if known {
				initializer = strings.clone(initializer, allocator)
				append(&document._owned_strings, initializer)
			}
			append_enum_member(document, owner_index, file_index, declaration, token, initializer, enum_member_comment(tokens[:], index, allocator), member_docs, allocator)
			next_value, has_next_value = next, known
			clear(&pending_comments)
			expecting_member = false
		}
		previous_non_comment_line = token.line
	}
	return true
}

enum_underlying_annotation :: proc(source: string) -> string {
	underlying := source_after(source, ":: enum")
	if open := strings.index(underlying, "{"); open >= 0 do underlying = underlying[:open]
	return strings.trim_space(underlying)
}

bit_field_underlying_annotation :: proc(source: string) -> string {
	underlying := source_after(source, ":: bit_field")
	if open := strings.index(underlying, "{"); open >= 0 do underlying = underlying[:open]
	return strings.trim_space(underlying)
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
			proven &&= append_member(document, parameters_index, file_index, declaration, token, tokens[index+2].text, "", allocator)
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

procedure_group_members :: proc(declaration: Declaration) -> [dynamic]string {
	lexer := lexer_init(declaration.source)
	members := make([dynamic]string, 0, 4, context.temp_allocator)
	depth := 0
	expecting_member := false
	for {
		token := lexer_next(&lexer)
		if token.kind == .End do break
		if token.text == "{" { depth += 1; if depth == 1 do expecting_member = true; continue }
		if token.text == "}" { depth -= 1; if depth == 0 do break; continue }
		if depth != 1 { continue }
		if token.text == "," { expecting_member = true; continue }
		if expecting_member && token.kind == .Ident { append(&members, token.text); expecting_member = false }
	}
	return members
}

append_procedure_type :: proc(document: ^doc.Document, file_index: u32, declaration: Declaration, allocator: mem.Allocator) -> (type_index: u32, proven: bool) {
	parameters := new_type(13, "", allocator)
	append(&document.types, parameters)
	parameters_index := u32(len(document.types)-1)
	procedure := new_type(14, "", allocator)
	append(&procedure.types, parameters_index)
	append(&document.types, procedure)
	procedure_index := u32(len(document.types)-1)
	return procedure_index, parse_procedure(document, parameters_index, procedure_index, file_index, declaration, allocator)
}

add_syntactic_type :: proc(document: ^doc.Document, file_index: u32, declaration: Declaration, allocator: mem.Allocator) -> (type_index: u32, proven: bool) {
	source := declaration.source
	#partial switch declaration.kind {
	case .Type:
		initializer := source_after(source, "::")
		if strings.contains(source, ":: distinct") {
			underlying := source_after(source, "distinct")
			return add_annotation_type(document, underlying, allocator)
		}
		if strings.contains(source, ":: #type proc") do return append_procedure_type(document, file_index, declaration, allocator)
		if !strings.has_prefix(initializer, "struct") && !strings.has_prefix(initializer, "union") && !strings.has_prefix(initializer, "enum") && !strings.has_prefix(initializer, "bit_set") && !strings.has_prefix(initializer, "bit_field") do return add_annotation_type(document, initializer, allocator)
		kind := u32(10) // struct
		if strings.contains(source, ":: union") do kind = 11
		if strings.contains(source, ":: enum") do kind = 12
		if strings.contains(source, ":: bit_set") do kind = 15
		if strings.contains(source, ":: bit_field") do kind = 25
		typ := new_type(kind, declaration.name, allocator)
		if kind == 10 {
			if strings.contains(source, "#packed") do typ.flags |= 1 << 1
			if strings.contains(source, "#raw_union") do typ.flags |= 1 << 2
		}
		append(&document.types, typ)
		index := u32(len(document.types)-1)
		if kind == 12 {
			proven := true
			if underlying := enum_underlying_annotation(source); len(underlying) > 0 {
				underlying_index, underlying_proven := add_annotation_type(document, underlying, allocator)
				append(&document.types[index].types, underlying_index)
				proven = underlying_proven
			}
			return index, parse_enum_members(document, index, file_index, declaration, allocator) && proven
		}
		if kind == 11 do return index, parse_union_members(document, index, file_index, declaration, allocator)
		if kind == 15 {
			// A bit set has an element and optional backing integer type; do not
			// leave it as an empty structural shell.
			return add_bit_set_type(document, source_after(source, "::"), allocator)
		}
		if kind == 25 {
			proven := true
			if underlying := bit_field_underlying_annotation(source); len(underlying) > 0 {
				underlying_index, underlying_proven := add_annotation_type(document, underlying, allocator)
				append(&document.types[index].types, underlying_index)
				proven = underlying_proven
			}
			return index, parse_bit_field_members(document, index, file_index, declaration, allocator) && proven
		}
		return index, parse_members(document, index, file_index, declaration, allocator)
	case .Procedure:
		return append_procedure_type(document, file_index, declaration, allocator)
	case .Procedure_Group:
		return 0, true
	case .Variable:
		annotation := source_after(source, ":")
		if strings.has_prefix(annotation, "=") do return append_constant_type(document, source_initializer(annotation), allocator), true
		if equals := strings.index(annotation, "="); equals >= 0 do annotation = strings.trim_space(annotation[:equals])
		return add_annotation_type(document, annotation, allocator)
	case:
		return 0, false
	}
}

find_package_entity :: proc(document: ^doc.Document, package_index: u32, name: string) -> u32 {
	if document == nil || int(package_index) >= len(document.packages) do return 0
	for entry in document.packages[package_index].entries do if entry.name == name do return entry.entity
	return 0
}

type_is_untyped_integer :: proc(document: ^doc.Document, type_index: u32) -> bool {
	return type_index > 0 && int(type_index) < len(document.types) && document.types[type_index].kind == 1 && document.types[type_index].name == "untyped integer"
}

// local_integer_constant_expression extends integer_literal_expression with
// names whose already-lowered local declarations are untyped integers. This
// is a type-only fixed point: it never evaluates a value or follows imports.
local_integer_constant_expression :: proc(document: ^doc.Document, package_index: u32, value: string) -> bool {
	text := strings.trim_space(value)
	expecting_operand := true
	paren_depth := 0
	saw_operand := false
	for index := 0; index < len(text); {
		ch := text[index]
		if is_space(ch) { index += 1; continue }
		if ch == '/' && index+1 < len(text) && text[index+1] == '/' { break }
		if ch == '/' && index+1 < len(text) && text[index+1] == '*' {
			index += 2
			for index+1 < len(text) && !(text[index] == '*' && text[index+1] == '/') do index += 1
			if index+1 >= len(text) do return false
			index += 2
			continue
		}
		if expecting_operand {
			if ch == '+' || ch == '-' || ch == '~' { index += 1; continue }
			if ch == '(' { paren_depth += 1; index += 1; continue }
			if '0' <= ch && ch <= '9' {
				start := index
				index += 1
				for index < len(text) && (('0' <= text[index] && text[index] <= '9') || ('a' <= text[index] && text[index] <= 'f') || ('A' <= text[index] && text[index] <= 'F') || text[index] == 'x' || text[index] == 'X' || text[index] == 'o' || text[index] == 'O' || text[index] == 'b' || text[index] == 'B' || text[index] == '_') do index += 1
				if _, ok := strconv.parse_int(text[start:index]); !ok do return false
				saw_operand = true
				expecting_operand = false
				continue
			}
			if !is_ident_start(ch) do return false
			if has_builtin_call(text[index:], "size_of") {
				index += len("size_of")
				depth := 0
				for index < len(text) {
					if text[index] == '(' { depth += 1 }
					if text[index] == ')' { depth -= 1; if depth == 0 { index += 1; break } }
					index += 1
				}
				if depth != 0 do return false
				saw_operand = true
				expecting_operand = false
				continue
			}
			start := index
			index += 1
			for index < len(text) && is_ident_continue(text[index]) do index += 1
			entity_index := find_package_entity(document, package_index, text[start:index])
			if entity_index == 0 || int(entity_index) >= len(document.entities) || document.entities[entity_index].kind != 1 || !type_is_untyped_integer(document, document.entities[entity_index].type) do return false
			saw_operand = true
			expecting_operand = false
			continue
		}
		if ch == ')' {
			if paren_depth == 0 do return false
			paren_depth -= 1
			index += 1
			continue
		}
		if ch == '<' || ch == '>' {
			if index+1 >= len(text) || text[index+1] != ch do return false
			index += 2
			expecting_operand = true
			continue
		}
		if ch == '+' || ch == '-' || ch == '*' || ch == '/' || ch == '%' || ch == '&' || ch == '|' || ch == '^' {
			index += 1
			expecting_operand = true
			continue
		}
		return false
	}
	return saw_operand && !expecting_operand && paren_depth == 0
}

two_call_arguments :: proc(value, name: string) -> (first, second: string, ok: bool) {
	text := strings.trim_space(value)
	if !strings.has_prefix(text, name) || len(text) <= len(name) || text[len(name)] != '(' do return
	depth := 1
	comma := -1
	for index := len(name)+1; index < len(text); index += 1 {
		if text[index] == '(' { depth += 1; continue }
		if text[index] == ')' {
			depth -= 1
			if depth != 0 do continue
			if comma < 0 || len(strings.trim_space(text[index+1:])) > 0 do return
			return strings.trim_space(text[len(name)+1:comma]), strings.trim_space(text[comma+1:index]), true
		}
		if text[index] == ',' && depth == 1 {
			if comma >= 0 do return
			comma = index
		}
	}
	return
}

// configuration_integer_expression accepts only #config fallback values and
// min/max calls whose operands independently establish untyped integer type.
// It intentionally does not read configuration state or evaluate values.
configuration_integer_expression :: proc(document: ^doc.Document, package_index: u32, value: string) -> bool {
	if local_integer_constant_expression(document, package_index, value) do return true
	first, second, ok := two_call_arguments(value, "#config")
	if ok {
		_ = first
		return configuration_integer_expression(document, package_index, second)
	}
	first, second, ok = two_call_arguments(value, "min")
	if ok do return configuration_integer_expression(document, package_index, first) && configuration_integer_expression(document, package_index, second)
	first, second, ok = two_call_arguments(value, "max")
	if ok do return configuration_integer_expression(document, package_index, first) && configuration_integer_expression(document, package_index, second)
	return false
}

// local_same_type_sum_expression handles a value-level `A + B + C` only when
// every operand is a known local constant with the same named type. This is
// enough for bit-set composition while avoiding a general operator resolver.
local_same_type_sum_expression :: proc(document: ^doc.Document, package_index: u32, value: string) -> u32 {
	text := strings.trim_space(value)
	expected_type := u32(0)
	expecting_operand := true
	for index := 0; index < len(text); {
		if is_space(text[index]) { index += 1; continue }
		if expecting_operand {
			if !is_ident_start(text[index]) do return 0
			start := index
			index += 1
			for index < len(text) && is_ident_continue(text[index]) do index += 1
			entity_index := find_package_entity(document, package_index, text[start:index])
			if entity_index == 0 || int(entity_index) >= len(document.entities) do return 0
			typ := document.entities[entity_index].type
			if typ == 0 || int(typ) >= len(document.types) || document.types[typ].kind != 2 || len(document.types[typ].name) == 0 do return 0
			if expected_type == 0 {
				expected_type = typ
			} else if document.types[expected_type].name != document.types[typ].name {
				return 0
			}
			expecting_operand = false
			continue
		}
		if text[index] != '+' do return 0
		index += 1
		expecting_operand = true
	}
	if expecting_operand do return 0
	return expected_type
}

// An imported alias is semantically established only when its qualifier maps
// to a discovered package. Qualified names from dependencies outside the
// selected source root deliberately remain unresolved.
alias_target_package :: proc(workspace: ^Workspace, file: Source_File, target: string) -> (package_index: i32, name: string) {
	separator := strings.index(target, ".")
	if separator <= 0 || separator+1 >= len(target) do return -1, target
	qualifier := target[:separator]
	name = target[separator+1:]
	if strings.contains(name, ".") do return -1, target
	for imp in file.imports {
		if imp.target_package < 0 || int(imp.target_package) >= len(workspace.packages) do continue
		import_name := imp.alias
		if len(import_name) == 0 do import_name = workspace.packages[imp.target_package].name
		if import_name == qualifier do return i32(imp.target_package), name
	}
	return -1, target
}

resolve_direct_aliases :: proc(document: ^doc.Document, pending: []Alias_Pending, result: ^Lower_Result, allocator: mem.Allocator) {
	if document == nil do return
	resolved := make([]bool, len(pending), context.temp_allocator)
	for pass := 0; pass < len(pending); pass += 1 {
		progress := false
		for item, index in pending {
			if resolved[index] do continue
			target_package := item.package_index if item.target_package < 0 else u32(item.target_package)
			target_index := find_package_entity(document, target_package, item.target)
			if target_index == 0 || int(target_index) >= len(document.entities) do continue
			target := document.entities[target_index]
			if target.type == 0 do continue
			alias := &document.entities[item.entity_index]
			alias.kind = target.kind
			alias.type = target.type
			if target.kind == 3 {
				alias.flags |= 1<<20 // OdinDocEntityFlag_Type_Alias
				alias.init_string = item.target
			} else if target.kind == 1 {
				alias.init_string = item.target
			}
			resolved[index] = true
			progress = true
		}
		if !progress do break
	}
	for item, index in pending {
		if !resolved[index] do lower_diagnostic(result, item.file, item.declaration, "alias target was not resolved from the local package; emitted as incomplete source syntax", allocator)
	}
}

resolve_local_constant_expressions :: proc(document: ^doc.Document, pending: []Constant_Pending, result: ^Lower_Result, allocator: mem.Allocator) {
	if document == nil do return
	resolved := make([]bool, len(pending), context.temp_allocator)
	for pass := 0; pass < len(pending); pass += 1 {
		progress := false
		for item, index in pending {
			if resolved[index] do continue
			if int(item.entity_index) >= len(document.entities) { resolved[index] = true; continue }
			entity := &document.entities[item.entity_index]
			if entity.type != 0 { resolved[index] = true; progress = true; continue }
			initializer := source_after(item.declaration.source, "::")
			if local_integer_constant_expression(document, item.package_index, initializer) {
				entity.type = append_untyped_integer_type(document, allocator)
				resolved[index] = true
				progress = true
			} else if configuration_integer_expression(document, item.package_index, initializer) {
				entity.type = append_untyped_integer_type(document, allocator)
				resolved[index] = true
				progress = true
			} else if typ := local_same_type_sum_expression(document, item.package_index, initializer); typ != 0 {
				entity.type = typ
				resolved[index] = true
				progress = true
			}
		}
		if !progress do break
	}
	for item, index in pending do if !resolved[index] do lower_diagnostic(result, item.file, item.declaration, "constant type was not resolved; emitted as incomplete source syntax", allocator)
}

resolve_procedure_groups :: proc(document: ^doc.Document, pending: []Procedure_Group_Pending, result: ^Lower_Result, allocator: mem.Allocator) {
	for item in pending {
		if int(item.entity_index) >= len(document.entities) do continue
		group := &document.entities[item.entity_index]
		members := procedure_group_members(item.declaration)
		for member in members {
			member_index := find_package_entity(document, item.package_index, member)
			if member_index == 0 || int(member_index) >= len(document.entities) || document.entities[member_index].kind != 4 {
				lower_diagnostic(result, item.file, item.declaration, "procedure group member was not resolved as a local procedure; emitted as incomplete source syntax", allocator)
				continue
			}
			append(&group.grouped_entities, member_index)
		}
		delete(members)
	}
}

entity_kind :: proc(kind: Declaration_Kind) -> u32 {
	#partial switch kind {
	case .Constant: return 1
	case .Variable: return 2
	case .Type: return 3
	case .Procedure: return 4
	case .Procedure_Group: return 5
	case: return 0
	}
}

// Marks an alias-like constant whose initializer is an authored type
// expression. The renderer writes `Name :: Type` directly rather than
// inventing a value initializer such as `_ = Type`.
SOURCE_ENTITY_FLAG_TYPE_EXPRESSION :: u64(1 << 21)

constant_initializer_is_structural_type :: proc(initializer: string) -> bool {
	text := strings.trim_space(initializer)
	return strings.has_prefix(text, "^") || strings.has_prefix(text, "[") || strings.has_prefix(text, "map[") || strings.has_prefix(text, "proc") || strings.has_prefix(text, "bit_set[") || strings.has_prefix(text, "bit_field ") || strings.has_prefix(text, "struct ") || strings.has_prefix(text, "union ") || strings.has_prefix(text, "enum ")
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
// kind, procedure shape, source type spelling, docs, positions, and
// declaration ordering are represented structurally. Unsupported type syntax
// and expressions whose type cannot be established record a diagnostic and
// mark the result incomplete.
Lower :: proc(workspace: ^Workspace, options: Lower_Options, allocator: mem.Allocator = context.allocator) -> Lower_Result {
	started := time.tick_now()
	result := Lower_Result{document = doc.Document_Init(allocator), diagnostics = make([dynamic]Lower_Diagnostic, 0, 8, allocator), complete = true}
	if workspace == nil {
		result.duration_ms = time.duration_milliseconds(time.tick_since(started))
		return result
	}
	pending_aliases := make([dynamic]Alias_Pending, 0, 8, allocator)
	defer delete(pending_aliases)
	pending_groups := make([dynamic]Procedure_Group_Pending, 0, 8, allocator)
	defer delete(pending_groups)
	pending_constants := make([dynamic]Constant_Pending, 0, 16, allocator)
	defer delete(pending_constants)
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
				if declaration.is_private do continue
				kind := entity_kind(declaration.kind)
				if kind == 0 do continue
				entity := new_entity(kind, declaration.name, declaration.docs, file_index, declaration, allocator)
				type_index, proven := add_syntactic_type(&result.document, file_index, declaration, allocator)
				entity.type = type_index
				if declaration.kind == .Constant {
					initializer := source_after(declaration.source, "::")
					if target := direct_alias_target(initializer); len(target) > 0 {
						if is_builtin_type(target) {
							// The lightweight declaration parser cannot distinguish a
							// named type from a value alias by punctuation alone. A
							// predeclared type is unambiguous source evidence.
							entity.kind = 3
							entity.type, _ = add_annotation_type(&result.document, target, allocator)
							entity.init_string = target
						} else {
							entity.flags |= SOURCE_ENTITY_FLAG_TYPE_EXPRESSION
							entity.init_string = target
							entity.type, _ = add_annotation_type(&result.document, target, allocator)
							append(&result.document.entities, entity)
							entity_index := u32(len(result.document.entities)-1)
							append(&out_package.entries, doc.Scope_Entry{name = declaration.name, entity = entity_index})
							target_package, target_name := alias_target_package(workspace, file, target)
							// Source packages are zero-based while the public document
							// reserves index zero as its null package.
							if target_package >= 0 do target_package += 1
							append(&pending_aliases, Alias_Pending{package_index = package_index, target_package = target_package, entity_index = entity_index, file = file, declaration = declaration, target = target_name})
							continue
						}
					} else if constant_initializer_is_structural_type(initializer) {
						entity.type, proven = add_annotation_type(&result.document, initializer, allocator)
					} else {
						entity.type = append_constant_type(&result.document, initializer, allocator)
						entity.init_string = source_initializer_excerpt(initializer)
					}
				} else if declaration.kind == .Variable {
					if initializer := source_initializer(declaration.source); len(initializer) > 0 do entity.init_string = source_initializer_excerpt(initializer)
				} else if declaration.kind == .Type {
					initializer := source_after(declaration.source, "::")
					if len(initializer) > 0 do entity.init_string = source_initializer_excerpt(initializer)
				} else if !proven {
					lower_diagnostic(&result, file, declaration, "declaration type was not semantically resolved; emitted as incomplete source syntax", allocator, entity.type)
				}
				append(&result.document.entities, entity)
				entity_index := u32(len(result.document.entities)-1)
				append(&out_package.entries, doc.Scope_Entry{name = declaration.name, entity = entity_index})
				if declaration.kind == .Constant && entity.type == 0 do append(&pending_constants, Constant_Pending{package_index = package_index, entity_index = entity_index, file = file, declaration = declaration})
				if declaration.kind == .Procedure_Group do append(&pending_groups, Procedure_Group_Pending{package_index = package_index, entity_index = entity_index, file = file, declaration = declaration})
			}
		}
		append(&result.document.packages, out_package)
	}
	resolve_direct_aliases(&result.document, pending_aliases[:], &result, allocator)
	resolve_local_constant_expressions(&result.document, pending_constants[:], &result, allocator)
	resolve_procedure_groups(&result.document, pending_groups[:], &result, allocator)
	resolve_unique_named_types(&result.document)
	discard_resolved_named_diagnostics(&result, allocator)
	if !result.complete && options.incomplete_policy == .Reject {
		doc.Document_Destroy(&result.document, allocator)
		result.document = doc.Document_Init(allocator)
	}
	result.duration_ms = time.duration_milliseconds(time.tick_since(started))
	return result
}
