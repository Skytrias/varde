// Portions of this file are modified/adapted from Odin's public
// core:odin/doc-format/doc_format.odin (Odin revision 4b95e8a040447a2ab939e0faf6ed094701d0a10e).
// Odin copyright and zlib license notice: THIRD_PARTY_NOTICES.md.
//
// Package doc_format implements the public, versioned Odin `.odin-doc` wire
// format. It has no dependency on the Odin compiler executable or internals.
//
// The in-memory Document mirrors the wire format deliberately: every top-level
// table reserves element zero as its null/sentinel index, and all references
// are local to one Document.
package doc_format

import "core:mem"
import "core:strings"

VERSION_MAJOR :: u8(0)
VERSION_MINOR :: u8(3)
VERSION_PATCH :: u8(2)

HEADER_SIZE :: 60
FILE_SIZE :: 12
PACKAGE_SIZE :: 44
SCOPE_ENTRY_SIZE :: 12
ATTRIBUTE_SIZE :: 16
ENTITY_SIZE :: 112
TYPE_SIZE :: 112

Error_Kind :: enum {
	None,
	Header_Too_Small,
	Invalid_Magic,
	Invalid_Version,
	Invalid_Total_Size,
	Invalid_Header_Size,
	Invalid_Hash,
	Invalid_Offset,
	Invalid_Array,
	Invalid_Index,
	Invalid_Type,
}

Error :: struct {
	kind:   Error_Kind,
	offset: int,
}

File :: struct {
	pkg:  u32,
	name: string,
}

Position :: struct {
	file:   u32,
	line:   u32,
	column: u32,
	offset: u32,
}

Scope_Entry :: struct {
	name:   string,
	entity: u32,
}

Package :: struct {
	fullpath: string,
	name:     string,
	flags:    u32,
	docs:     string,
	files:    [dynamic]u32,
	entries:  [dynamic]Scope_Entry,
}

Attribute :: struct {
	name:  string,
	value: string,
}

Entity :: struct {
	kind:             u32,
	flags:            u64,
	pos:              Position,
	name:             string,
	type:             u32,
	init_string:      string,
	comment:          string,
	docs:             string,
	field_group_index: i32,
	foreign_library:  u32,
	link_name:        string,
	attributes:       [dynamic]Attribute,
	grouped_entities: [dynamic]u32,
	where_clauses:    [dynamic]string,
}

Type :: struct {
	kind:               u32,
	flags:              u32,
	name:               string,
	custom_align:       string,
	elem_count_len:     u32,
	elem_counts:        [4]i64,
	calling_convention: string,
	types:              [dynamic]u32,
	entities:           [dynamic]u32,
	polymorphic_params: u32,
	where_clauses:      [dynamic]string,
	tags:               [dynamic]string,
}

// Document owns its parsed table strings after Read. Source lowering may also
// register separately allocated strings in _owned_strings; other manually
// constructed fields may still borrow their source workspace.
Document :: struct {
	files:      [dynamic]File,
	packages:   [dynamic]Package,
	entities:   [dynamic]Entity,
	types:      [dynamic]Type,
	_owned_strings: [dynamic]string,
	_owns_data: bool,
}

// A Workspace intentionally retains document-local indices. A type, entity,
// or file index from one .odin-doc must never be interpreted in another one.
// Consumers resolve a package through document_index/package_index first.
Workspace_Package :: struct {
	document_index:      int,
	package_index:       u32,
	public_entry_count:  int,
}

Merge_Diagnostic_Kind :: enum {
	Duplicate_Package,
}

Merge_Diagnostic :: struct {
	kind:                    Merge_Diagnostic_Kind,
	package_path:            string,
	kept_document_index:     int,
	kept_package_index:      u32,
	discarded_document_index: int,
	discarded_package_index: u32,
}

// Workspace owns its pointer list but borrows the source documents themselves.
// Destroying it never destroys a source document; callers remain responsible
// for Document_Destroy.
Workspace :: struct {
	documents:   [dynamic]^Document,
	packages:    [dynamic]Workspace_Package,
	diagnostics: [dynamic]Merge_Diagnostic,
}

Document_Init :: proc(allocator: mem.Allocator = context.allocator) -> Document {
	doc := Document{
		files = make([dynamic]File, 0, 8, allocator),
		packages = make([dynamic]Package, 0, 8, allocator),
		entities = make([dynamic]Entity, 0, 16, allocator),
		types = make([dynamic]Type, 0, 16, allocator),
		_owned_strings = make([dynamic]string, 0, 8, allocator),
	}
	append(&doc.files, File{})
	append(&doc.packages, Package{})
	append(&doc.entities, Entity{})
	append(&doc.types, Type{})
	return doc
}

free_string :: proc(value: string, allocator: mem.Allocator) {
	if len(value) > 0 do delete(value, allocator)
}

Document_Destroy :: proc(doc: ^Document, allocator: mem.Allocator = context.allocator) {
	if doc == nil do return
	for value in doc._owned_strings do free_string(value, allocator)
	delete(doc._owned_strings)
	for &file in doc.files {
		if doc._owns_data do free_string(file.name, allocator)
	}
	for &pkg in doc.packages {
		if doc._owns_data {
			free_string(pkg.fullpath, allocator)
			free_string(pkg.name, allocator)
			free_string(pkg.docs, allocator)
		}
		if doc._owns_data {
			for &entry in pkg.entries do free_string(entry.name, allocator)
		}
		delete(pkg.files)
		delete(pkg.entries)
	}
	for &entity in doc.entities {
		if doc._owns_data {
			free_string(entity.name, allocator)
			free_string(entity.init_string, allocator)
			free_string(entity.comment, allocator)
			free_string(entity.docs, allocator)
			free_string(entity.link_name, allocator)
		}
		if doc._owns_data {
			for &attribute in entity.attributes {
				free_string(attribute.name, allocator)
				free_string(attribute.value, allocator)
			}
		}
		if doc._owns_data {
			for clause in entity.where_clauses do free_string(clause, allocator)
		}
		delete(entity.attributes)
		delete(entity.grouped_entities)
		delete(entity.where_clauses)
	}
	for &typ in doc.types {
		if doc._owns_data {
			free_string(typ.name, allocator)
			free_string(typ.custom_align, allocator)
			free_string(typ.calling_convention, allocator)
		}
		if doc._owns_data {
			for clause in typ.where_clauses do free_string(clause, allocator)
			for tag in typ.tags do free_string(tag, allocator)
		}
		delete(typ.types)
		delete(typ.entities)
		delete(typ.where_clauses)
		delete(typ.tags)
	}
	delete(doc.files)
	delete(doc.packages)
	delete(doc.entities)
	delete(doc.types)
	doc^ = {}
}

Workspace_Destroy :: proc(workspace: ^Workspace) {
	if workspace == nil do return
	delete(workspace.documents)
	delete(workspace.packages)
	delete(workspace.diagnostics)
	workspace^ = {}
}

error_string :: proc(err: Error) -> string {
	switch err.kind {
	case .None: return ""
	case .Header_Too_Small: return "document is smaller than the .odin-doc header"
	case .Invalid_Magic: return "document does not have the odindoc magic"
	case .Invalid_Version: return "document uses an unsupported .odin-doc version"
	case .Invalid_Total_Size: return "document has an invalid declared size"
	case .Invalid_Header_Size: return "document has an invalid header size"
	case .Invalid_Hash: return "document data hash does not match its header"
	case .Invalid_Offset: return "document contains an out-of-bounds offset"
	case .Invalid_Array: return "document contains an out-of-bounds array"
	case .Invalid_Index: return "document contains an invalid local index"
	case .Invalid_Type: return "document contains an invalid type record"
	}
	return "unknown .odin-doc error"
}

align_up :: proc(value, alignment: int) -> int {
	if alignment <= 1 do return value
	return (value + alignment - 1) & ~(alignment - 1)
}

append_align :: proc(data: ^[dynamic]u8, alignment: int) {
	for len(data^) < align_up(len(data^), alignment) do append(data, u8(0))
}

append_zeros :: proc(data: ^[dynamic]u8, count: int) {
	for _ in 0 ..< count do append(data, u8(0))
}

append_u32 :: proc(data: ^[dynamic]u8, value: u32) {
	append(data, u8(value & 0xff))
	append(data, u8((value >> 8) & 0xff))
	append(data, u8((value >> 16) & 0xff))
	append(data, u8((value >> 24) & 0xff))
}

append_u64 :: proc(data: ^[dynamic]u8, value: u64) {
	for shift in 0 ..< 8 do append(data, u8((value >> u32(8 * shift)) & 0xff))
}

put_u32 :: proc(data: ^[dynamic]u8, offset: int, value: u32) {
	data[offset + 0] = u8(value & 0xff)
	data[offset + 1] = u8((value >> 8) & 0xff)
	data[offset + 2] = u8((value >> 16) & 0xff)
	data[offset + 3] = u8((value >> 24) & 0xff)
}

put_u64 :: proc(data: ^[dynamic]u8, offset: int, value: u64) {
	for shift in 0 ..< 8 do data[offset + shift] = u8((value >> u32(8 * shift)) & 0xff)
}

read_u32 :: proc(data: []u8, offset: int) -> (u32, bool) {
	if offset < 0 || offset > len(data) - 4 do return 0, false
	value := u32(data[offset]) | u32(data[offset + 1]) << 8 | u32(data[offset + 2]) << 16 | u32(data[offset + 3]) << 24
	return value, true
}

read_u64 :: proc(data: []u8, offset: int) -> (u64, bool) {
	if offset < 0 || offset > len(data) - 8 do return 0, false
	value := u64(0)
	for shift in 0 ..< 8 do value |= u64(data[offset + shift]) << u32(8 * shift)
	return value, true
}

read_range :: proc(data: []u8, offset, count, item_size: int) -> (int, bool) {
	if offset < 0 || offset > len(data) || count < 0 || item_size <= 0 do return 0, false
	if count > (len(data) - offset) / item_size do return 0, false
	return count * item_size, true
}

read_descriptor :: proc(data: []u8, offset, item_size: int) -> (int, int, bool) {
	start, ok := read_u32(data, offset)
	if !ok do return 0, 0, false
	count, count_ok := read_u32(data, offset + 4)
	if !count_ok do return 0, 0, false
	_, valid := read_range(data, int(start), int(count), item_size)
	return int(start), int(count), valid
}

read_string :: proc(data: []u8, descriptor_offset: int, allocator: mem.Allocator) -> (string, bool) {
	offset, length, ok := read_descriptor(data, descriptor_offset, 1)
	if !ok do return "", false
	if length == 0 do return "", true
	return strings.clone(string(data[offset:offset + length]), allocator), true
}

write_string :: proc(data: ^[dynamic]u8, descriptor_offset: int, value: string) {
	if len(value) == 0 {
		put_u32(data, descriptor_offset, 0)
		put_u32(data, descriptor_offset + 4, 0)
		return
	}
	offset := len(data^)
	for index in 0 ..< len(value) do append(data, value[index])
	append(data, 0)
	put_u32(data, descriptor_offset, u32(offset))
	put_u32(data, descriptor_offset + 4, u32(len(value)))
}

write_u32_array :: proc(data: ^[dynamic]u8, descriptor_offset: int, values: []u32) {
	if len(values) == 0 {
		put_u32(data, descriptor_offset, 0)
		put_u32(data, descriptor_offset + 4, 0)
		return
	}
	append_align(data, 4)
	offset := len(data^)
	for value in values do append_u32(data, value)
	put_u32(data, descriptor_offset, u32(offset))
	put_u32(data, descriptor_offset + 4, u32(len(values)))
}

write_string_array :: proc(data: ^[dynamic]u8, descriptor_offset: int, values: []string) {
	if len(values) == 0 {
		put_u32(data, descriptor_offset, 0)
		put_u32(data, descriptor_offset + 4, 0)
		return
	}
	append_align(data, 4)
	offset := len(data^)
	append_zeros(data, len(values) * 8)
	for value, index in values do write_string(data, offset + index * 8, value)
	put_u32(data, descriptor_offset, u32(offset))
	put_u32(data, descriptor_offset + 4, u32(len(values)))
}

valid_index :: proc(index: u32, count: int) -> bool { return index == 0 || int(index) < count }

validate_references :: proc(doc: ^Document) -> Error {
	for file in doc.files[1:] {
		if !valid_index(file.pkg, len(doc.packages)) do return {kind = .Invalid_Index}
	}
	for pkg in doc.packages[1:] {
		for file in pkg.files {
			if !valid_index(file, len(doc.files)) do return {kind = .Invalid_Index}
		}
		for entry in pkg.entries {
			if !valid_index(entry.entity, len(doc.entities)) do return {kind = .Invalid_Index}
		}
	}
	for entity in doc.entities[1:] {
		if !valid_index(entity.pos.file, len(doc.files)) || !valid_index(entity.type, len(doc.types)) || !valid_index(entity.foreign_library, len(doc.entities)) do return {kind = .Invalid_Index}
		for grouped in entity.grouped_entities {
			if !valid_index(grouped, len(doc.entities)) do return {kind = .Invalid_Index}
		}
	}
	for typ in doc.types[1:] {
		if typ.elem_count_len > 4 do return {kind = .Invalid_Type}
		if !valid_index(typ.polymorphic_params, len(doc.types)) do return {kind = .Invalid_Index}
		for child in typ.types {
			if !valid_index(child, len(doc.types)) do return {kind = .Invalid_Index}
		}
		for entity in typ.entities {
			if !valid_index(entity, len(doc.entities)) do return {kind = .Invalid_Index}
		}
	}
	return {}
}

Validate :: proc(doc: ^Document) -> Error {
	if doc == nil do return {kind = .Invalid_Array}
	if len(doc.files) == 0 || len(doc.packages) == 0 || len(doc.entities) == 0 || len(doc.types) == 0 do return {kind = .Invalid_Array}
	return validate_references(doc)
}

Workspace_Package_Path :: proc(workspace: ^Workspace, item: Workspace_Package) -> string {
	if workspace == nil || item.document_index < 0 || item.document_index >= len(workspace.documents) do return ""
	document := workspace.documents[item.document_index]
	if document == nil || int(item.package_index) >= len(document.packages) do return ""
	return document.packages[item.package_index].fullpath
}

// Merge selects one package for each canonical full path. Input order is
// observable: a later duplicate replaces an earlier package only when it has
// strictly more public entries. Equal counts keep the earlier input.
Merge :: proc(documents: []^Document, allocator: mem.Allocator = context.allocator) -> (Workspace, Error) {
	workspace := Workspace{documents = make([dynamic]^Document, 0, len(documents), allocator), packages = make([dynamic]Workspace_Package, 0, 16, allocator), diagnostics = make([dynamic]Merge_Diagnostic, 0, 4, allocator)}
	for document in documents do append(&workspace.documents, document)
	for document, document_index in documents {
		if err := Validate(document); err.kind != .None { Workspace_Destroy(&workspace); return {}, err }
		for package_index in 1 ..< len(document.packages) {
			pkg := document.packages[package_index]
			candidate := Workspace_Package{document_index = document_index, package_index = u32(package_index), public_entry_count = len(pkg.entries)}
			prior_index := -1
			for existing, existing_index in workspace.packages {
				if Workspace_Package_Path(&workspace, existing) == pkg.fullpath { prior_index = existing_index; break }
			}
			if prior_index < 0 {
				append(&workspace.packages, candidate)
				continue
			}
			prior := workspace.packages[prior_index]
			if candidate.public_entry_count > prior.public_entry_count {
				workspace.packages[prior_index] = candidate
				append(&workspace.diagnostics, Merge_Diagnostic{kind = .Duplicate_Package, package_path = pkg.fullpath, kept_document_index = document_index, kept_package_index = u32(package_index), discarded_document_index = prior.document_index, discarded_package_index = prior.package_index})
			} else {
				append(&workspace.diagnostics, Merge_Diagnostic{kind = .Duplicate_Package, package_path = pkg.fullpath, kept_document_index = prior.document_index, kept_package_index = prior.package_index, discarded_document_index = document_index, discarded_package_index = u32(package_index)})
			}
		}
	}
	return workspace, {}
}

fnv1a_32 :: proc(data: []u8, start: int) -> u32 {
	hash := u32(0x811c9dc5)
	for value in data[start:] do hash = (hash ~ u32(value)) * u32(0x01000193)
	return hash
}

Read :: proc(input: []u8, allocator: mem.Allocator = context.allocator) -> (Document, Error) {
	if len(input) < HEADER_SIZE do return {}, {kind = .Header_Too_Small}
	if string(input[:8]) != "odindoc\x00" do return {}, {kind = .Invalid_Magic}
	if input[12] != VERSION_MAJOR || input[13] != VERSION_MINOR || input[14] != VERSION_PATCH do return {}, {kind = .Invalid_Version}
	total_size, total_size_ok := read_u32(input, 16)
	if !total_size_ok || total_size < HEADER_SIZE || int(total_size) > len(input) do return {}, {kind = .Invalid_Total_Size}
	data := input[:int(total_size)]
	header_size, header_size_ok := read_u32(data, 20)
	if !header_size_ok || header_size < HEADER_SIZE || int(header_size) > len(data) do return {}, {kind = .Invalid_Header_Size}
	expected_hash, hash_ok := read_u32(data, 24)
	if !hash_ok || expected_hash != fnv1a_32(data, int(header_size)) do return {}, {kind = .Invalid_Hash}
	files_offset, files_count, files_ok := read_descriptor(data, 28, FILE_SIZE)
	if !files_ok || files_count == 0 do return {}, {kind = .Invalid_Array, offset = 28}
	packages_offset, packages_count, packages_ok := read_descriptor(data, 36, PACKAGE_SIZE)
	if !packages_ok || packages_count == 0 do return {}, {kind = .Invalid_Array, offset = 36}
	entities_offset, entities_count, entities_ok := read_descriptor(data, 44, ENTITY_SIZE)
	if !entities_ok || entities_count == 0 do return {}, {kind = .Invalid_Array, offset = 44}
	types_offset, types_count, types_ok := read_descriptor(data, 52, TYPE_SIZE)
	if !types_ok || types_count == 0 do return {}, {kind = .Invalid_Array, offset = 52}

	doc := Document_Init(allocator)
	doc._owns_data = true
	defer if err := validate_references(&doc); err.kind != .None { Document_Destroy(&doc, allocator) }

	for index in 1 ..< files_count {
		base := files_offset + index * FILE_SIZE
		pkg, valid := read_u32(data, base)
		name, name_valid := read_string(data, base + 4, allocator)
		if !valid || !name_valid do return {}, {kind = .Invalid_Offset, offset = base}
		append(&doc.files, File{pkg = pkg, name = name})
	}
	for index in 1 ..< packages_count {
		base := packages_offset + index * PACKAGE_SIZE
		fullpath, a := read_string(data, base, allocator)
		name, b := read_string(data, base + 8, allocator)
		flags, c := read_u32(data, base + 16)
		docs, d := read_string(data, base + 20, allocator)
		file_offset, file_count, e := read_descriptor(data, base + 28, 4)
		entry_offset, entry_count, f := read_descriptor(data, base + 36, SCOPE_ENTRY_SIZE)
		if !a || !b || !c || !d || !e || !f do return {}, {kind = .Invalid_Offset, offset = base}
		pkg := Package{fullpath = fullpath, name = name, flags = flags, docs = docs, files = make([dynamic]u32, 0, file_count, allocator), entries = make([dynamic]Scope_Entry, 0, entry_count, allocator)}
		for item in 0 ..< file_count {
			value, valid := read_u32(data, file_offset + item * 4)
			if !valid do return {}, {kind = .Invalid_Offset, offset = file_offset + item * 4}
			append(&pkg.files, value)
		}
		for item in 0 ..< entry_count {
			entry_base := entry_offset + item * SCOPE_ENTRY_SIZE
			entry_name, name_valid := read_string(data, entry_base, allocator)
			entity, entity_valid := read_u32(data, entry_base + 8)
			if !name_valid || !entity_valid do return {}, {kind = .Invalid_Offset, offset = entry_base}
			append(&pkg.entries, Scope_Entry{name = entry_name, entity = entity})
		}
		append(&doc.packages, pkg)
	}
	for index in 1 ..< entities_count {
		base := entities_offset + index * ENTITY_SIZE
		kind, a := read_u32(data, base)
		flags, b := read_u64(data, base + 8)
		file, c := read_u32(data, base + 16)
		line, d := read_u32(data, base + 20)
		column, e := read_u32(data, base + 24)
		offset, f := read_u32(data, base + 28)
		name, g := read_string(data, base + 32, allocator)
		type_index, h := read_u32(data, base + 40)
		init_string, i := read_string(data, base + 44, allocator)
		comment, j := read_string(data, base + 56, allocator)
		docs, k := read_string(data, base + 64, allocator)
		field_group_index_raw, l := read_u32(data, base + 72)
		foreign_library, m := read_u32(data, base + 76)
		link_name, n := read_string(data, base + 80, allocator)
		attrs_offset, attrs_count, o := read_descriptor(data, base + 88, ATTRIBUTE_SIZE)
		grouped_offset, grouped_count, p := read_descriptor(data, base + 96, 4)
		where_offset, where_count, q := read_descriptor(data, base + 104, 8)
		if !a || !b || !c || !d || !e || !f || !g || !h || !i || !j || !k || !l || !m || !n || !o || !p || !q do return {}, {kind = .Invalid_Offset, offset = base}
		entity := Entity{kind = kind, flags = flags, pos = {file = file, line = line, column = column, offset = offset}, name = name, type = type_index, init_string = init_string, comment = comment, docs = docs, field_group_index = transmute(i32)field_group_index_raw, foreign_library = foreign_library, link_name = link_name, attributes = make([dynamic]Attribute, 0, attrs_count, allocator), grouped_entities = make([dynamic]u32, 0, grouped_count, allocator), where_clauses = make([dynamic]string, 0, where_count, allocator)}
		for item in 0 ..< attrs_count {
			attribute_base := attrs_offset + item * ATTRIBUTE_SIZE
			attribute_name, name_valid := read_string(data, attribute_base, allocator)
			attribute_value, value_valid := read_string(data, attribute_base + 8, allocator)
			if !name_valid || !value_valid do return {}, {kind = .Invalid_Offset, offset = attribute_base}
			append(&entity.attributes, Attribute{name = attribute_name, value = attribute_value})
		}
		for item in 0 ..< grouped_count {
			value, valid := read_u32(data, grouped_offset + item * 4)
			if !valid do return {}, {kind = .Invalid_Offset, offset = grouped_offset + item * 4}
			append(&entity.grouped_entities, value)
		}
		for item in 0 ..< where_count {
			value, valid := read_string(data, where_offset + item * 8, allocator)
			if !valid do return {}, {kind = .Invalid_Offset, offset = where_offset + item * 8}
			append(&entity.where_clauses, value)
		}
		append(&doc.entities, entity)
	}
	for index in 1 ..< types_count {
		base := types_offset + index * TYPE_SIZE
		kind, a := read_u32(data, base)
		flags, b := read_u32(data, base + 4)
		name, c := read_string(data, base + 8, allocator)
		custom_align, d := read_string(data, base + 16, allocator)
		elem_count_len, e := read_u32(data, base + 24)
		calling_convention, f := read_string(data, base + 64, allocator)
		types_array_offset, types_count_inner, g := read_descriptor(data, base + 72, 4)
		entities_array_offset, entities_count_inner, h := read_descriptor(data, base + 80, 4)
		polymorphic_params, i := read_u32(data, base + 88)
		where_offset, where_count, j := read_descriptor(data, base + 92, 8)
		tags_offset, tags_count, k := read_descriptor(data, base + 100, 8)
		if !a || !b || !c || !d || !e || !f || !g || !h || !i || !j || !k || elem_count_len > 4 do return {}, {kind = .Invalid_Type, offset = base}
		typ := Type{kind = kind, flags = flags, name = name, custom_align = custom_align, elem_count_len = elem_count_len, calling_convention = calling_convention, types = make([dynamic]u32, 0, types_count_inner, allocator), entities = make([dynamic]u32, 0, entities_count_inner, allocator), polymorphic_params = polymorphic_params, where_clauses = make([dynamic]string, 0, where_count, allocator), tags = make([dynamic]string, 0, tags_count, allocator)}
		for item in 0 ..< 4 {
			value, valid := read_u64(data, base + 32 + item * 8)
			if !valid do return {}, {kind = .Invalid_Offset, offset = base + 32 + item * 8}
			typ.elem_counts[item] = transmute(i64)value
		}
		for item in 0 ..< types_count_inner {
			value, valid := read_u32(data, types_array_offset + item * 4)
			if !valid do return {}, {kind = .Invalid_Offset, offset = types_array_offset + item * 4}
			append(&typ.types, value)
		}
		for item in 0 ..< entities_count_inner {
			value, valid := read_u32(data, entities_array_offset + item * 4)
			if !valid do return {}, {kind = .Invalid_Offset, offset = entities_array_offset + item * 4}
			append(&typ.entities, value)
		}
		for item in 0 ..< where_count {
			value, valid := read_string(data, where_offset + item * 8, allocator)
			if !valid do return {}, {kind = .Invalid_Offset, offset = where_offset + item * 8}
			append(&typ.where_clauses, value)
		}
		for item in 0 ..< tags_count {
			value, valid := read_string(data, tags_offset + item * 8, allocator)
			if !valid do return {}, {kind = .Invalid_Offset, offset = tags_offset + item * 8}
			append(&typ.tags, value)
		}
		append(&doc.types, typ)
	}
	if err := validate_references(&doc); err.kind != .None do return {}, err
	return doc, {}
}

write_attributes :: proc(data: ^[dynamic]u8, descriptor_offset: int, values: []Attribute) {
	if len(values) == 0 {
		put_u32(data, descriptor_offset, 0); put_u32(data, descriptor_offset + 4, 0); return
	}
	append_align(data, 4); offset := len(data^); append_zeros(data, len(values) * ATTRIBUTE_SIZE)
	for value, index in values {
		base := offset + index * ATTRIBUTE_SIZE
		write_string(data, base, value.name)
		write_string(data, base + 8, value.value)
	}
	put_u32(data, descriptor_offset, u32(offset)); put_u32(data, descriptor_offset + 4, u32(len(values)))
}

write_scope_entries :: proc(data: ^[dynamic]u8, descriptor_offset: int, values: []Scope_Entry) {
	if len(values) == 0 {
		put_u32(data, descriptor_offset, 0); put_u32(data, descriptor_offset + 4, 0); return
	}
	append_align(data, 4); offset := len(data^); append_zeros(data, len(values) * SCOPE_ENTRY_SIZE)
	for value, index in values {
		base := offset + index * SCOPE_ENTRY_SIZE
		write_string(data, base, value.name)
		put_u32(data, base + 8, value.entity)
	}
	put_u32(data, descriptor_offset, u32(offset)); put_u32(data, descriptor_offset + 4, u32(len(values)))
}

Write :: proc(doc: ^Document, allocator: mem.Allocator = context.allocator) -> ([dynamic]u8, Error) {
	if doc == nil do return nil, {kind = .Invalid_Array}
	if err := validate_references(doc); err.kind != .None do return nil, err
	if len(doc.files) == 0 || len(doc.packages) == 0 || len(doc.entities) == 0 || len(doc.types) == 0 do return nil, {kind = .Invalid_Array}
	data := make([dynamic]u8, 0, 1024, allocator)
	append_zeros(&data, HEADER_SIZE)
	append_align(&data, 4); files_offset := len(data); append_zeros(&data, len(doc.files) * FILE_SIZE)
	append_align(&data, 4); packages_offset := len(data); append_zeros(&data, len(doc.packages) * PACKAGE_SIZE)
	append_align(&data, 8); entities_offset := len(data); append_zeros(&data, len(doc.entities) * ENTITY_SIZE)
	append_align(&data, 8); types_offset := len(data); append_zeros(&data, len(doc.types) * TYPE_SIZE)
	append_align(&data, 16)

	for file, index in doc.files[1:] {
		base := files_offset + (index + 1) * FILE_SIZE
		put_u32(&data, base, file.pkg)
		write_string(&data, base + 4, file.name)
	}
	for pkg, index in doc.packages[1:] {
		base := packages_offset + (index + 1) * PACKAGE_SIZE
		write_string(&data, base, pkg.fullpath)
		write_string(&data, base + 8, pkg.name)
		put_u32(&data, base + 16, pkg.flags)
		write_string(&data, base + 20, pkg.docs)
		write_u32_array(&data, base + 28, pkg.files[:])
		write_scope_entries(&data, base + 36, pkg.entries[:])
	}
	for entity, index in doc.entities[1:] {
		base := entities_offset + (index + 1) * ENTITY_SIZE
		put_u32(&data, base, entity.kind)
		put_u64(&data, base + 8, entity.flags)
		put_u32(&data, base + 16, entity.pos.file); put_u32(&data, base + 20, entity.pos.line); put_u32(&data, base + 24, entity.pos.column); put_u32(&data, base + 28, entity.pos.offset)
		write_string(&data, base + 32, entity.name)
		put_u32(&data, base + 40, entity.type)
		write_string(&data, base + 44, entity.init_string)
		write_string(&data, base + 56, entity.comment)
		write_string(&data, base + 64, entity.docs)
		put_u32(&data, base + 72, transmute(u32)entity.field_group_index)
		put_u32(&data, base + 76, entity.foreign_library)
		write_string(&data, base + 80, entity.link_name)
		write_attributes(&data, base + 88, entity.attributes[:])
		write_u32_array(&data, base + 96, entity.grouped_entities[:])
		write_string_array(&data, base + 104, entity.where_clauses[:])
	}
	for typ, index in doc.types[1:] {
		base := types_offset + (index + 1) * TYPE_SIZE
		put_u32(&data, base, typ.kind); put_u32(&data, base + 4, typ.flags)
		write_string(&data, base + 8, typ.name); write_string(&data, base + 16, typ.custom_align)
		put_u32(&data, base + 24, typ.elem_count_len)
		for item in 0 ..< 4 do put_u64(&data, base + 32 + item * 8, transmute(u64)typ.elem_counts[item])
		write_string(&data, base + 64, typ.calling_convention)
		write_u32_array(&data, base + 72, typ.types[:]); write_u32_array(&data, base + 80, typ.entities[:])
		put_u32(&data, base + 88, typ.polymorphic_params)
		write_string_array(&data, base + 92, typ.where_clauses[:]); write_string_array(&data, base + 100, typ.tags[:])
	}

	magic := "odindoc\x00"
	for index in 0 ..< 8 do data[index] = magic[index]
	data[12] = VERSION_MAJOR; data[13] = VERSION_MINOR; data[14] = VERSION_PATCH
	put_u32(&data, 16, u32(len(data)))
	put_u32(&data, 20, HEADER_SIZE)
	put_u32(&data, 28, u32(files_offset)); put_u32(&data, 32, u32(len(doc.files)))
	put_u32(&data, 36, u32(packages_offset)); put_u32(&data, 40, u32(len(doc.packages)))
	put_u32(&data, 44, u32(entities_offset)); put_u32(&data, 48, u32(len(doc.entities)))
	put_u32(&data, 52, u32(types_offset)); put_u32(&data, 56, u32(len(doc.types)))
	put_u32(&data, 24, fnv1a_32(data[:], HEADER_SIZE))
	return data, {}
}
