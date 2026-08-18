package varde

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

// Markup is intentionally owned by Varde. It is a small, predictable subset
// suitable for source comments: headings, lists, tables, fenced/indented code,
// examples, outputs, emphasis, inline code, and safe explicit links.
Markup_Block_Kind :: enum u8 {
	Paragraph,
	Heading,
	Horizontal_Rule,
	Code,
	Example,
	Operation,
	Output,
	Possible_Output,
	List,
	Table,
}

Markup_Inline_Kind :: enum u8 { Text, Link, Code, Bold }

Markup_Inline :: struct {
	kind: Markup_Inline_Kind,
	text: string,
	url:  string,
}

Markup_Block :: struct {
	kind:  Markup_Block_Kind,
	title: string,
	lines: [dynamic]string,
}

markup_clone_lines :: proc(items: []string, allocator: mem.Allocator) -> [dynamic]string {
	out := make([dynamic]string, 0, len(items), allocator)
	for item in items do append(&out, strings.clone(item, allocator))
	return out
}

markup_strip_common_indent :: proc(lines: []string, allocator: mem.Allocator) -> []string {
	if len(lines) == 0 do return lines
	min_tabs := max(int)
	found := false
	for line in lines {
		if strings.trim_space(line) == "" do continue
		count := 0
		for ch in line {
			if ch == '\t' {
				count += 1
			} else {
				break
			}
		}
		min_tabs = min(min_tabs, count)
		found = true
	}
	if !found || min_tabs <= 0 do return lines
	out := make([]string, len(lines), allocator)
	for line, index in lines {
		if strings.trim_space(line) == "" {
			out[index] = line
		} else {
			out[index] = line[min_tabs:]
		}
	}
	return out
}

markup_flush :: proc(blocks: ^[dynamic]Markup_Block, buffer: ^[dynamic]string, kind: Markup_Block_Kind, title: string, allocator: mem.Allocator) {
	line_start := 0
	if kind == .Code || kind == .Example || kind == .Operation || kind == .Output || kind == .Possible_Output {
		// A blank line after a label makes authored comments easier to read, but
		// it is not part of the displayed example/output. Preserve blanks inside
		// a block while removing this accidental leading newline.
		for line_start < len(buffer^) && strings.trim_space(buffer^[line_start]) == "" do line_start += 1
	}
	line_count := len(buffer^)
	for line_count > 0 && strings.trim_space(buffer^[line_count - 1]) == "" do line_count -= 1
	if line_start >= line_count { resize(buffer, 0); return }
	append(blocks, Markup_Block{kind = kind, title = strings.clone(title, allocator), lines = markup_clone_lines(buffer^[line_start:line_count], allocator)})
	resize(buffer, 0)
}

markup_is_table_row :: proc(line: string) -> bool {
	trimmed := strings.trim_space(line)
	if len(trimmed) < 3 || trimmed[0] != '|' || trimmed[len(trimmed) - 1] != '|' do return false
	pipes := 0
	for ch in trimmed { if ch == '|' do pipes += 1 }
	return pipes >= 2
}

markup_blocks_parse :: proc(text: string, allocator: mem.Allocator = context.allocator) -> [dynamic]Markup_Block {
	if len(text) > 16 * 1024 * 1024 do return nil
	content := strings.trim_right_space(text)
	if len(strings.trim_space(content)) == 0 do return nil
	raw_lines := strings.split_lines(content)
	defer delete(raw_lines)
	lines := markup_strip_common_indent(raw_lines, context.temp_allocator)
	if raw_data(lines) != raw_data(raw_lines) do defer delete(lines, context.temp_allocator)
	blocks := make([dynamic]Markup_Block, 0, 8, allocator)
	buffer := make([dynamic]string, 0, 8, allocator)
	defer delete(buffer)
	kind := Markup_Block_Kind.Paragraph
	title := ""
	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "```") {
			markup_flush(&blocks, &buffer, kind, title, allocator)
			if kind == .Code { kind = .Paragraph } else { kind = .Code }
			title = ""
			continue
		}
		if kind == .Code { append(&buffer, line); continue }
		switch {
		case trimmed == "":
			if kind == .Example || kind == .Operation || kind == .Output || kind == .Possible_Output { append(&buffer, ""); continue }
			markup_flush(&blocks, &buffer, kind, title, allocator); kind = .Paragraph; title = ""
		case trimmed == "---" || trimmed == "***" || trimmed == "___":
			markup_flush(&blocks, &buffer, kind, title, allocator); append(&blocks, Markup_Block{kind = .Horizontal_Rule}); kind = .Paragraph; title = ""
		case strings.has_prefix(line, "Example:"):
			markup_flush(&blocks, &buffer, kind, title, allocator); kind = .Example; title = "Example:"
			remainder := strings.trim_left_space(strings.trim_prefix(line, "Example:")); if len(remainder) > 0 do append(&buffer, remainder)
		case strings.has_prefix(line, "Operation:"):
			markup_flush(&blocks, &buffer, kind, title, allocator); kind = .Operation; title = "Operation:"
			remainder := strings.trim_left_space(strings.trim_prefix(line, "Operation:")); if len(remainder) > 0 do append(&buffer, remainder)
		case strings.has_prefix(line, "Possible Output:"):
			markup_flush(&blocks, &buffer, kind, title, allocator); kind = .Possible_Output; title = "Possible Output:"
			remainder := strings.trim_left_space(strings.trim_prefix(line, "Possible Output:")); if len(remainder) > 0 do append(&buffer, remainder)
		case strings.has_prefix(line, "Output:"):
			markup_flush(&blocks, &buffer, kind, title, allocator); kind = .Output; title = "Output:"
			remainder := strings.trim_left_space(strings.trim_prefix(line, "Output:")); if len(remainder) > 0 do append(&buffer, remainder)
		case strings.has_prefix(trimmed, "#"):
			markup_flush(&blocks, &buffer, kind, title, allocator); level := 0; for level < len(trimmed) && trimmed[level] == '#' do level += 1
			append(&blocks, Markup_Block{kind = .Heading, title = strings.clone(fmt.tprintf("%d", level), allocator), lines = markup_clone_lines([]string{strings.trim_space(trimmed[level:])}, allocator)})
			kind = .Paragraph; title = ""
		case strings.has_prefix(trimmed, "- ") || strings.has_prefix(trimmed, "* "):
			if kind != .List { markup_flush(&blocks, &buffer, kind, title, allocator); kind = .List; title = "" }
			append(&buffer, strings.trim_space(trimmed[2:]))
		case markup_is_table_row(line):
			if kind != .Table { markup_flush(&blocks, &buffer, kind, title, allocator); kind = .Table; title = "" }
			append(&buffer, trimmed)
		case strings.has_prefix(line, "\t"):
			if kind != .Example && kind != .Operation && kind != .Output && kind != .Possible_Output { markup_flush(&blocks, &buffer, kind, title, allocator); kind = .Code; title = "" }
			append(&buffer, strings.trim_prefix(line, "\t"))
		case:
			if kind != .Paragraph { markup_flush(&blocks, &buffer, kind, title, allocator); kind = .Paragraph; title = "" }
			append(&buffer, line)
		}
	}
	markup_flush(&blocks, &buffer, kind, title, allocator)
	return blocks
}

markup_blocks_destroy :: proc(blocks: ^[dynamic]Markup_Block, allocator: mem.Allocator = context.allocator) {
	for &block in blocks^ {
		if len(block.title) > 0 do delete(block.title, allocator)
		for line in block.lines { if len(line) > 0 do delete(line, allocator) }
		delete(block.lines)
	}
	delete(blocks^)
	blocks^ = nil
}

@(test)
test_markup_examples_and_outputs_drop_label_spacing :: proc(t: ^testing.T) {
	blocks := markup_blocks_parse("Example:\n\n\tvalue := 1\n\nOutput:\n\n\t1")
	defer markup_blocks_destroy(&blocks)
	testing.expect(t, len(blocks) == 2, "example and output should each form one block")
	testing.expect(t, blocks[0].kind == .Example && blocks[0].lines[0] == "value := 1", "example code should not begin with an empty rendered line")
	testing.expect(t, blocks[1].kind == .Output && blocks[1].lines[0] == "1", "output should not begin with an empty rendered line")
}

markup_find_from :: proc(text, needle: string, start: int) -> int {
	if len(needle) == 0 do return start
	for index in max(0, start) ..= len(text) - len(needle) { if text[index:index + len(needle)] == needle do return index }
	return -1
}

markup_append_text :: proc(segments: ^[dynamic]Markup_Inline, text: string, lo, hi: int, allocator: mem.Allocator) {
	if hi > lo do append(segments, Markup_Inline{kind = .Text, text = strings.clone(text[lo:hi], allocator)})
}

markup_inline_parse :: proc(text: string, allocator: mem.Allocator = context.allocator) -> [dynamic]Markup_Inline {
	segments := make([dynamic]Markup_Inline, 0, 4, allocator)
	start, index := 0, 0
	for index < len(text) {
		if text[index] == '*' {
			run := 1; for index + run < len(text) && text[index + run] == '*' && run < 3 do run += 1
			end := markup_find_from(text, text[index:index + run], index + run)
			if end >= 0 { markup_append_text(&segments, text, start, index, allocator); append(&segments, Markup_Inline{kind = .Bold, text = strings.clone(text[index + run:end], allocator)}); index = end + run; start = index; continue }
		}
		if text[index] == '`' {
			end := markup_find_from(text, "`", index + 1)
			if end >= 0 { markup_append_text(&segments, text, start, index, allocator); append(&segments, Markup_Inline{kind = .Code, text = strings.clone(text[index + 1:end], allocator)}); index = end + 1; start = index; continue }
		}
		if index + 1 < len(text) && text[index:index + 2] == "[[" {
			end := markup_find_from(text, "]]", index + 2)
			if end >= 0 {
				markup_append_text(&segments, text, start, index, allocator); payload := text[index + 2:end]; label := strings.trim_space(payload); url := label
				if sep := strings.index_byte(payload, ';'); sep >= 0 { label = strings.trim_space(payload[:sep]); url = strings.trim_space(payload[sep + 1:]) }
				append(&segments, Markup_Inline{kind = .Link, text = strings.clone(label, allocator), url = strings.clone(url, allocator)}); index = end + 2; start = index; continue
			}
		}
		if text[index] == '[' {
			middle := markup_find_from(text, "](", index + 1)
			end := -1
			if middle >= 0 do end = markup_find_from(text, ")", middle + 2)
			if end >= 0 { markup_append_text(&segments, text, start, index, allocator); append(&segments, Markup_Inline{kind = .Link, text = strings.clone(text[index + 1:middle], allocator), url = strings.clone(text[middle + 2:end], allocator)}); index = end + 1; start = index; continue }
		}
		index += 1
	}
	markup_append_text(&segments, text, start, len(text), allocator)
	return segments
}

markup_inline_destroy :: proc(segments: ^[dynamic]Markup_Inline, allocator: mem.Allocator = context.allocator) {
	for segment in segments^ { if len(segment.text) > 0 do delete(segment.text, allocator); if len(segment.url) > 0 do delete(segment.url, allocator) }
	delete(segments^); segments^ = nil
}
