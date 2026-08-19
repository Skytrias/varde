// Varde is a standalone, file://-safe API documentation site builder.
//
// The package deliberately accepts an already-scanned Model. Frontends such as
// Vigil or a future `varde` CLI own source scanning; Varde owns the durable
// reference model, link resolution, assets, and safe static-site build.
package varde

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import tokenizer "core:odin/tokenizer"

SITE_CONFIG_FILE_NAME :: "varde.json"
SITE_LEGACY_CONFIG_FILE_NAME :: "vigil-site.json"
SITE_MANIFEST_FILE_NAME :: "varde-site-manifest.json"
SITE_LEGACY_MANIFEST_FILE_NAME :: "vigil-site-manifest.json"
SITE_OVERRIDES_CSS_FILE_NAME :: "overrides.css"
SITE_SCHEMA_VERSION :: 5

THEME_ODIN_LIGHT :: "odin-light"
THEME_MONOKAI :: "monokai"
THEME_GITHUB_LIGHT :: "github-light"
THEME_TOKYO_NIGHT :: "tokyo-night"

SITE_OVERRIDES_CSS :: `/*
 * Varde loads this stylesheet after assets/site.css on every generated page.
 *
 * Put project-specific visual overrides here: colors, typography, layout, or
 * new presentational rules. Varde preserves this file on later site builds.
 * Keep generated content in the other assets files; they are replaced safely.
 */

`

Config :: struct {
	schema_version:       int    `json:"schema_version"`,
	title:                string `json:"title"`,
	description:          string `json:"description"`,
	output_dir:           string `json:"output_dir"`,
	include_brand_artwork: bool   `json:"include_brand_artwork"`,
	include_source_links:  bool   `json:"include_source_links"`,
	source_url_prefix:     string `json:"source_url_prefix"`,
	theme:                 string `json:"theme"`,
	system_light_theme:    string `json:"system_light_theme"`,
	system_dark_theme:     string `json:"system_dark_theme"`,
	motion:                string `json:"motion"`,
	code_tab_width:        int    `json:"code_tab_width"`,
	collapse_package_tree: bool   `json:"collapse_package_tree"`,
	workspace_packages_only: bool  `json:"workspace_packages_only"`,
	head_html:             string `json:"head_html"`,
	before_content_html:   string `json:"before_content_html"`,
	after_content_html:    string `json:"after_content_html"`,
	_owns_strings:         bool   `json:"-"`,
}

Entry :: struct {
	id:        string,
	name:      string,
	anchor:    string,
	kind:      string,
	signature: string,
	docs:      string,
	comment:   string,
	summary:   string,
	source_path: string,
	source_line: int,
}

// Declarations are presented in the same stable categories used by Odin's
// package documentation. Keep an Other bucket for newer document kinds so a
// site never silently loses a declaration just because its renderer predates
// that kind.
Entry_Group :: enum {
	Types,
	Constants,
	Variables,
	Procedures,
	Procedure_Groups,
	Other,
}

ENTRY_GROUP_ORDER :: []Entry_Group{.Types, .Constants, .Variables, .Procedures, .Procedure_Groups, .Other}

Package_Entry :: struct {
	entry: ^Entry,
	file:  ^File,
}

source_links_validate :: proc(config: Config) -> string {
	if !config.include_source_links do return ""
	prefix := strings.trim_space(config.source_url_prefix)
	if len(prefix) == 0 do return "Source links are enabled, but no repository URL prefix was provided"
	if !strings.has_prefix(prefix, "https://") do return "Source URL prefix must start with https://"
	return ""
}

Import :: struct {
	alias: string,
	path:  string,
}

File :: struct {
	name:     string,
	path:     string,
	overview: string,
	imports:  [dynamic]Import,
	entries:  [dynamic]Entry,
}

Package :: struct {
	id:            string,
	name:          string,
	path:          string,
	relative_path: string,
	overview:      string,
	summary:       string,
	files:         [dynamic]File,
}

Stats :: struct {
	package_count: int,
	file_count:    int,
	entry_count:   int,
	sloc:          int,
}

Model :: struct {
	workspace_path: string,
	packages:       [dynamic]Package,
	stats:          Stats,
}

Assets :: struct {
	brand_png: []u8,
}

Build_Result :: struct {
	ok:              bool,
	output_path:     string,
	package_count:   int,
	entry_count:     int,
	error_message:   string,
}

config_default :: proc(workspace_path, title, description: string) -> Config {
	base := filepath.base(workspace_path)
	if base == "." || len(base) == 0 {
		if absolute_path, err := filepath.abs(workspace_path, context.temp_allocator); err == nil do base = filepath.base(absolute_path)
	}
	resolved_title := title
	if len(resolved_title) == 0 do resolved_title = fmt.tprintf("%s Documentation", base)
	return Config{
		schema_version = SITE_SCHEMA_VERSION,
		title = resolved_title,
		description = description,
		output_dir = "dist/varde",
		include_brand_artwork = true,
		include_source_links = false,
		theme = "system",
		system_light_theme = THEME_ODIN_LIGHT,
		system_dark_theme = THEME_MONOKAI,
		motion = "system",
		code_tab_width = 4,
		collapse_package_tree = true,
	}
}

site_theme_valid :: proc(value: string) -> bool {
	return value == THEME_ODIN_LIGHT || value == THEME_MONOKAI || value == THEME_GITHUB_LIGHT || value == THEME_TOKYO_NIGHT
}

site_theme_is_dark :: proc(value: string) -> bool { return value == THEME_MONOKAI || value == THEME_TOKYO_NIGHT }
config_theme_valid :: proc(value: string) -> bool { return value == "system" || site_theme_valid(value) }
config_theme_upgrade_legacy :: proc(value: string) -> string {
	if value == "light" do return THEME_ODIN_LIGHT
	if value == "dark" do return THEME_MONOKAI
	return value
}
config_motion_valid :: proc(value: string) -> bool { return value == "system" || value == "full" || value == "reduced" }
config_tab_width_valid :: proc(value: int) -> bool { return value == 2 || value == 4 || value == 8 }

path_join :: proc(parts: []string, allocator := context.temp_allocator) -> string {
	path, err := filepath.join(parts, allocator)
	if err != nil do return ""
	return path
}

config_path :: proc(workspace_path: string, allocator := context.temp_allocator) -> string {
	return path_join({workspace_path, SITE_CONFIG_FILE_NAME}, allocator)
}

config_load :: proc(workspace_path, title, description: string, allocator := context.allocator) -> (Config, string) {
	defaults := config_default(workspace_path, title, description)
	config := defaults
	path := config_path(workspace_path, allocator)
	if !os.exists(path) {
		delete(path, allocator)
		legacy_path := path_join({workspace_path, SITE_LEGACY_CONFIG_FILE_NAME}, allocator)
		path = legacy_path
		if !os.exists(path) {
			delete(path, allocator)
			return config, ""
		}
	}
	defer delete(path, allocator)
	data, err := os.read_entire_file(path, allocator)
	if err != nil do return config, fmt.tprintf("Could not read site configuration: %v", err)
	defer delete(data, allocator)
	config = {}
	if err := json.unmarshal(data, &config); err != nil {
		config._owns_strings = true
		config_destroy(&config, allocator)
		return config_default(workspace_path, title, description), fmt.tprintf("varde.json is invalid: %v", err)
	}
	config._owns_strings = true
	needs_presentation_migration := config.schema_version < SITE_SCHEMA_VERSION
	if config.schema_version != SITE_SCHEMA_VERSION {
		config.schema_version = SITE_SCHEMA_VERSION
	}
	if len(strings.trim_space(config.title)) == 0 do config.title = strings.clone(defaults.title, allocator)
	if len(strings.trim_space(config.description)) == 0 && len(defaults.description) > 0 do config.description = strings.clone(defaults.description, allocator)
	if len(strings.trim_space(config.output_dir)) == 0 do config.output_dir = strings.clone(defaults.output_dir, allocator)
	legacy_theme := config_theme_upgrade_legacy(config.theme)
	if legacy_theme != config.theme {
		if len(config.theme) > 0 do delete(config.theme, allocator)
		config.theme = strings.clone(legacy_theme, allocator)
	}
	if !config_theme_valid(config.theme) {
		if len(config.theme) > 0 do delete(config.theme, allocator)
		config.theme = strings.clone(defaults.theme, allocator)
	}
	legacy_system_light_theme := config_theme_upgrade_legacy(config.system_light_theme)
	if legacy_system_light_theme != config.system_light_theme {
		if len(config.system_light_theme) > 0 do delete(config.system_light_theme, allocator)
		config.system_light_theme = strings.clone(legacy_system_light_theme, allocator)
	}
	if !site_theme_valid(config.system_light_theme) {
		if len(config.system_light_theme) > 0 do delete(config.system_light_theme, allocator)
		config.system_light_theme = strings.clone(defaults.system_light_theme, allocator)
	}
	legacy_system_dark_theme := config_theme_upgrade_legacy(config.system_dark_theme)
	if legacy_system_dark_theme != config.system_dark_theme {
		if len(config.system_dark_theme) > 0 do delete(config.system_dark_theme, allocator)
		config.system_dark_theme = strings.clone(legacy_system_dark_theme, allocator)
	}
	if !site_theme_valid(config.system_dark_theme) {
		if len(config.system_dark_theme) > 0 do delete(config.system_dark_theme, allocator)
		config.system_dark_theme = strings.clone(defaults.system_dark_theme, allocator)
	}
	if !config_motion_valid(config.motion) {
		if len(config.motion) > 0 do delete(config.motion, allocator)
		config.motion = strings.clone(defaults.motion, allocator)
	}
	if !config_tab_width_valid(config.code_tab_width) do config.code_tab_width = defaults.code_tab_width
	if needs_presentation_migration do config.collapse_package_tree = defaults.collapse_package_tree
	return config, ""
}

// Config values loaded from disk own their string fields. Defaults are safe
// borrowed values and deliberately need no cleanup. Embedders that retain a
// loaded Config can release it after cloning or saving it.
config_destroy :: proc(config: ^Config, allocator: mem.Allocator = context.allocator) {
	if config == nil || !config._owns_strings {
		if config != nil do config^ = {}
		return
	}
	if len(config.title) > 0 do delete(config.title, allocator)
	if len(config.description) > 0 do delete(config.description, allocator)
	if len(config.output_dir) > 0 do delete(config.output_dir, allocator)
	if len(config.source_url_prefix) > 0 do delete(config.source_url_prefix, allocator)
	if len(config.theme) > 0 do delete(config.theme, allocator)
	if len(config.system_light_theme) > 0 do delete(config.system_light_theme, allocator)
	if len(config.system_dark_theme) > 0 do delete(config.system_dark_theme, allocator)
	if len(config.motion) > 0 do delete(config.motion, allocator)
	if len(config.head_html) > 0 do delete(config.head_html, allocator)
	if len(config.before_content_html) > 0 do delete(config.before_content_html, allocator)
	if len(config.after_content_html) > 0 do delete(config.after_content_html, allocator)
	config^ = {}
}

// config_set_output_dir preserves Config's ownership contract when a CLI or
// embedder overrides a value loaded from varde.json. Command-line strings are
// borrowed, so assigning one directly to an owning Config would later attempt
// to free argument memory during config_destroy.
config_set_output_dir :: proc(config: ^Config, output_dir: string, allocator: mem.Allocator = context.allocator) {
	if config == nil do return
	if config._owns_strings {
		if len(config.output_dir) > 0 do delete(config.output_dir, allocator)
		config.output_dir = strings.clone(output_dir, allocator)
		return
	}
	config.output_dir = output_dir
}

config_save :: proc(workspace_path: string, config: Config) -> string {
	if err := source_links_validate(config); len(err) > 0 do return err
	path := config_path(workspace_path, context.allocator)
	defer delete(path, context.allocator)
	data, err := json.marshal(config, json.Marshal_Options{pretty = true, use_spaces = true, spaces = 2})
	if err != nil do return "Could not serialize varde.json"
	defer delete(data)
	if err := os.write_entire_file(path, data); err != nil do return "Could not write varde.json"
	return ""
}

output_path_resolve :: proc(workspace_path, output_dir: string, allocator := context.temp_allocator) -> (string, string) {
	if len(strings.trim_space(workspace_path)) == 0 do return "", "No workspace is open"
	if len(strings.trim_space(output_dir)) == 0 do return "", "Output directory is empty"
	if filepath.is_abs(output_dir) do return "", "Output directory must be relative to the workspace"
	clean, err := filepath.clean(output_dir, allocator)
	if err != nil do return "", "Could not normalize output directory"
	if clean == "." || clean == ".." || strings.has_prefix(clean, "../") do return "", "Output directory must stay inside the workspace"
	return path_join({workspace_path, clean}, allocator), ""
}

html_escape_append :: proc(builder: ^strings.Builder, value: string, attribute := false) {
	for ch in value {
		switch ch {
		case '&': strings.write_string(builder, "&amp;")
		case '<': strings.write_string(builder, "&lt;")
		case '>': strings.write_string(builder, "&gt;")
		case '"': strings.write_string(builder, "&quot;")
		case '\'':
			if attribute {
				strings.write_string(builder, "&#39;")
			} else {
				strings.write_rune(builder, ch)
			}
		case: strings.write_rune(builder, ch)
		}
	}
}

html_text :: proc(builder: ^strings.Builder, value: string) { html_escape_append(builder, value) }
html_attr :: proc(builder: ^strings.Builder, value: string) { html_escape_append(builder, value, true) }

package_url_path :: proc(pkg: Package, allocator := context.temp_allocator) -> string {
	relative := pkg.relative_path
	if len(relative) == 0 || relative == "." do relative = pkg.name
	return strings.concatenate({"packages/", relative, "/"}, allocator)
}

package_output_path :: proc(pkg: Package, allocator := context.temp_allocator) -> string {
	return path_join({package_url_path(pkg, allocator), "index.html"}, allocator)
}

package_href_from :: proc(from_file, target_file: string, anchor: string, allocator := context.temp_allocator) -> string {
	from_dir := filepath.dir(from_file)
	path, err := filepath.rel(from_dir, target_file, allocator)
	if err != nil do path = target_file
	if strings.has_suffix(path, "/index.html") do path = path[:len(path)-len("index.html")]
	if path == "index.html" do path = "./"
	if len(anchor) > 0 do return strings.concatenate({path, "#", anchor}, allocator)
	return path
}

source_path_url_encode :: proc(value: string, allocator := context.temp_allocator) -> string {
	builder: strings.Builder
	defer strings.builder_destroy(&builder)
	for index in 0 ..< len(value) {
		byte := value[index]
		if ('a' <= byte && byte <= 'z') || ('A' <= byte && byte <= 'Z') || ('0' <= byte && byte <= '9') || byte == '/' || byte == '-' || byte == '_' || byte == '.' || byte == '~' {
			strings.write_rune(&builder, rune(byte))
		} else {
			strings.write_string(&builder, "%")
			fmt.sbprintf(&builder, "%02X", byte)
		}
	}
	return strings.clone(strings.to_string(builder), allocator)
}

// workspace_path_relative_base resolves a caller-supplied workspace root before
// comparing it with extractor and doc-format paths, which are canonical and
// absolute. This keeps `--source .` from leaking the local filesystem into
// generated routes, headings, search labels, and source links.
workspace_path_relative_base :: proc(workspace_path: string, allocator := context.temp_allocator) -> string {
	if len(workspace_path) == 0 || filepath.is_abs(workspace_path) do return workspace_path
	absolute_path, err := filepath.abs(workspace_path, allocator)
	if err != nil do return workspace_path
	return absolute_path
}

// source_path_display turns an input file name into a portable, human-facing
// path for generated search results. Keep the original path on the model: it
// is still needed for optional source-repository links.
source_path_display :: proc(model: ^Model, path: string, allocator := context.temp_allocator) -> string {
	if len(path) == 0 do return path
	if !filepath.is_abs(path) {
		web_path, _ := strings.replace_all(path, "\\", "/", allocator)
		return web_path
	}
	if model == nil || len(model.workspace_path) == 0 do return path
	workspace_path := workspace_path_relative_base(model.workspace_path, allocator)
	relative_path, relative_err := filepath.rel(workspace_path, path, allocator)
	if relative_err != nil || relative_path == ".." || strings.has_prefix(relative_path, "../") do return path
	web_path, _ := strings.replace_all(relative_path, "\\", "/", allocator)
	return web_path
}

source_href :: proc(config: Config, model: ^Model, entry: Entry) -> (string, bool) {
	if !config.include_source_links || model == nil || len(entry.source_path) == 0 do return "", false
	workspace_path := workspace_path_relative_base(model.workspace_path, context.temp_allocator)
	relative_path, relative_err := filepath.rel(workspace_path, entry.source_path, context.temp_allocator)
	if relative_err != nil || relative_path == ".." || strings.has_prefix(relative_path, "../") do return "", false
	web_path, _ := strings.replace_all(relative_path, "\\", "/", context.temp_allocator)
	web_path = source_path_url_encode(web_path)
	prefix := strings.trim_space(config.source_url_prefix)
	for len(prefix) > 0 && prefix[len(prefix) - 1] == '/' do prefix = prefix[:len(prefix) - 1]
	// GitHub directory URLs are useful to paste, but source lines only exist on
	// blob URLs. Preserve all other hosts and URL shapes exactly as configured.
	if strings.has_prefix(prefix, "https://github.com/") && strings.contains(prefix, "/tree/") {
		prefix, _ = strings.replace_all(prefix, "/tree/", "/blob/", context.temp_allocator)
	}
	if len(prefix) == 0 || len(web_path) == 0 do return "", false
	href := strings.concatenate({prefix, "/", web_path}, context.temp_allocator)
	if entry.source_line > 0 do href = strings.concatenate({href, "#L", fmt.tprintf("%d", entry.source_line)}, context.temp_allocator)
	return href, true
}

ensure_directory :: proc(path: string) -> string {
	if os.exists(path) do return ""
	if err := os.make_directory_all(path); err != nil do return fmt.tprintf("Could not create output directory %q: %v", path, err)
	return ""
}

write_text_file :: proc(path: string, builder: ^strings.Builder) -> string {
	if err := ensure_directory(filepath.dir(path)); len(err) > 0 do return err
	if err := os.write_entire_file(path, strings.to_string(builder^)); err != nil do return "Could not write generated site file"
	return ""
}

write_bytes_file :: proc(path: string, data: []u8) -> string {
	if err := ensure_directory(filepath.dir(path)); len(err) > 0 do return err
	if err := os.write_entire_file(path, data); err != nil do return "Could not write generated asset"
	return ""
}

write_overrides_css :: proc(output_root, prior_output_root: string) -> string {
	destination := path_join({output_root, "assets", SITE_OVERRIDES_CSS_FILE_NAME})
	prior_path := path_join({prior_output_root, "assets", SITE_OVERRIDES_CSS_FILE_NAME})
	if os.exists(prior_path) {
		data, err := os.read_entire_file(prior_path, context.temp_allocator)
		if err != nil do return "Could not preserve assets/overrides.css from prior site output"
		defer delete(data, context.temp_allocator)
		return write_bytes_file(destination, data)
	}
	builder: strings.Builder
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, SITE_OVERRIDES_CSS)
	return write_text_file(destination, &builder)
}

Site_Extensions :: struct {
	head:           []u8,
	before_content: []u8,
	after_content:  []u8,
}

site_extension_read :: proc(workspace_path, configured_path, label: string) -> ([]u8, string) {
	if len(strings.trim_space(configured_path)) == 0 do return nil, ""
	if filepath.is_abs(configured_path) do return nil, fmt.tprintf("%s must be relative to the workspace", label)
	clean, err := filepath.clean(configured_path, context.temp_allocator)
	if err != nil || clean == "." || clean == ".." || strings.has_prefix(clean, "../") do return nil, fmt.tprintf("%s must stay inside the workspace", label)
	path := path_join({workspace_path, clean}, context.temp_allocator)
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil do return nil, fmt.tprintf("Could not read %s %q", label, configured_path)
	return data, ""
}

site_extensions_load :: proc(workspace_path: string, config: Config) -> (Site_Extensions, string) {
	extensions := Site_Extensions{}
	err: string
	extensions.head, err = site_extension_read(workspace_path, config.head_html, "head_html")
	if len(err) > 0 do return extensions, err
	extensions.before_content, err = site_extension_read(workspace_path, config.before_content_html, "before_content_html")
	if len(err) > 0 { site_extensions_destroy(&extensions); return {}, err }
	extensions.after_content, err = site_extension_read(workspace_path, config.after_content_html, "after_content_html")
	if len(err) > 0 { site_extensions_destroy(&extensions); return {}, err }
	return extensions, ""
}

site_extensions_destroy :: proc(extensions: ^Site_Extensions) {
	if extensions == nil do return
	delete(extensions.head)
	delete(extensions.before_content)
	delete(extensions.after_content)
	extensions^ = {}
}

site_head :: proc(builder: ^strings.Builder, page_title, project_title, relative_assets, site_root: string, config: Config, extensions: Site_Extensions) {
	strings.write_string(builder, "<!doctype html><html lang=\"en\" data-site-root=\"")
	html_attr(builder, site_root)
	strings.write_string(builder, "\" data-default-theme=\""); html_attr(builder, config.theme)
	strings.write_string(builder, "\" data-system-light-theme=\""); html_attr(builder, config.system_light_theme)
	strings.write_string(builder, "\" data-system-dark-theme=\""); html_attr(builder, config.system_dark_theme)
	if config.theme != "system" {
		strings.write_string(builder, "\" data-theme=\"")
		html_attr(builder, config.theme)
	}
	strings.write_string(builder, "\" data-default-motion=\""); html_attr(builder, config.motion)
	strings.write_string(builder, "\" data-default-tab-width=\""); fmt.sbprintf(builder, "%d", config.code_tab_width)
	strings.write_string(builder, "\" data-default-collapse-packages=\""); strings.write_string(builder, config.collapse_package_tree ? "true" : "false")
	strings.write_string(builder, "\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><meta name=\"color-scheme\" content=\"")
	if config.theme != "system" {
		strings.write_string(builder, site_theme_is_dark(config.theme) ? "dark" : "light")
	} else {
		strings.write_string(builder, "light dark")
	}
	strings.write_string(builder, "\"><script>")
	strings.write_string(builder, SITE_THEME_BOOTSTRAP_JS)
	strings.write_string(builder, "</script><title>")
	html_text(builder, page_title)
	if page_title != project_title {
		strings.write_string(builder, " · ")
		html_text(builder, project_title)
	}
	strings.write_string(builder, "</title><link rel=\"stylesheet\" href=\"")
	html_attr(builder, strings.concatenate({relative_assets, "site.css"}, context.temp_allocator))
	strings.write_string(builder, "\"><link rel=\"stylesheet\" href=\"")
	html_attr(builder, strings.concatenate({relative_assets, SITE_OVERRIDES_CSS_FILE_NAME}, context.temp_allocator))
	strings.write_string(builder, "\">")
	if len(extensions.head) > 0 do strings.write_string(builder, string(extensions.head[:]))
	strings.write_string(builder, "</head><body><a class=\"skip\" href=\"#main\">Skip to content</a><header class=\"site-header\"><a class=\"brand\" href=\"")
	html_attr(builder, site_root)
	strings.write_string(builder, "\">")
	html_text(builder, project_title)
	strings.write_string(builder, "</a><button id=\"site-search\" class=\"search-trigger\" type=\"button\" aria-haspopup=\"dialog\" aria-controls=\"search-dialog\" aria-label=\"Search documentation\"><svg class=\"search-trigger-icon\" aria-hidden=\"true\" viewBox=\"0 0 16 16\" fill=\"none\"><circle cx=\"6.75\" cy=\"6.75\" r=\"4.25\"></circle><path d=\"m10 10 3.25 3.25\"></path></svg><span>Search</span><kbd>⌘K</kbd></button><button id=\"site-settings\" type=\"button\" aria-haspopup=\"dialog\" aria-controls=\"settings-dialog\" aria-label=\"Documentation settings\">Settings</button></header>")
}

site_footer :: proc(builder: ^strings.Builder, relative_assets: string, extensions: Site_Extensions) {
	if len(extensions.after_content) > 0 do strings.write_string(builder, string(extensions.after_content[:]))
	strings.write_string(builder, "<footer>Generated by Varde</footer><dialog id=\"search-dialog\" aria-labelledby=\"search-title\"><section class=\"search-dialog\"><header class=\"search-dialog-header\"><div><p class=\"eyebrow\">Reference search</p><h2 id=\"search-title\">Find anything</h2></div><button id=\"search-close\" type=\"button\" aria-label=\"Close search\">×</button></header><div class=\"search-controls\"><label class=\"sr-only\" for=\"search-input\">Search packages, files, and symbols</label><input id=\"search-input\" autocomplete=\"off\" spellcheck=\"false\" placeholder=\"Search packages, files, and symbols\" aria-describedby=\"search-summary\" aria-controls=\"search-results\"><p id=\"search-summary\" class=\"search-summary\" role=\"status\"></p></div><div class=\"search-results-scroll\"><div id=\"search-results\" role=\"listbox\" aria-label=\"Search results\"></div></div><footer class=\"search-hint\"><span><kbd>↑</kbd><kbd>↓</kbd> navigate</span><span><kbd>↵</kbd> open</span><span><kbd>Esc</kbd> close</span></footer></section></dialog><dialog id=\"settings-dialog\" aria-labelledby=\"settings-title\"><section class=\"settings-dialog\"><header class=\"search-dialog-header\"><div><p class=\"eyebrow\">Documentation preferences</p><h2 id=\"settings-title\">Settings</h2></div><button id=\"settings-close\" type=\"button\" aria-label=\"Close settings\">×</button></header><form id=\"settings-form\" class=\"settings-form\"><label>Theme<select name=\"theme\"><option value=\"system\">System</option><option value=\"odin-light\">Odin Light</option><option value=\"monokai\">Monokai</option><option value=\"github-light\">GitHub Light</option><option value=\"tokyo-night\">Tokyo Night</option></select></label><fieldset class=\"system-theme-options\"><legend>System theme variants</legend><p>Used only while Theme is set to System.</p><label>Light appearance<select name=\"systemLightTheme\"><option value=\"odin-light\">Odin Light</option><option value=\"github-light\">GitHub Light</option><option value=\"monokai\">Monokai</option><option value=\"tokyo-night\">Tokyo Night</option></select></label><label>Dark appearance<select name=\"systemDarkTheme\"><option value=\"monokai\">Monokai</option><option value=\"tokyo-night\">Tokyo Night</option><option value=\"odin-light\">Odin Light</option><option value=\"github-light\">GitHub Light</option></select></label></fieldset><label>Motion<select name=\"motion\"><option value=\"system\">System preference</option><option value=\"full\">Full motion</option><option value=\"reduced\">Reduced motion</option></select></label><label>Code tab width<select name=\"tabWidth\"><option value=\"2\">2 spaces</option><option value=\"4\">4 spaces</option><option value=\"8\">8 spaces</option></select></label><label class=\"settings-check\"><input name=\"collapsePackages\" type=\"checkbox\"> Collapse package groups on home</label><button type=\"button\" id=\"settings-reset\">Reset to project defaults</button></form></section></dialog><script src=\"")
	html_attr(builder, strings.concatenate({relative_assets, "search-index.js"}, context.temp_allocator))
	strings.write_string(builder, "\"></script><script src=\"")
	html_attr(builder, strings.concatenate({relative_assets, "site.js"}, context.temp_allocator))
	strings.write_string(builder, "\"></script></body></html>")
}

entry_body :: proc(entry: Entry) -> string {
	if len(strings.trim_space(entry.docs)) > 0 do return entry.docs
	return entry.comment
}

Doc_Render_Context :: struct {
	model:       ^Model,
	indexes:     ^Site_Render_Indexes,
	output_root: string,
	page_path:   string,
	pkg:         ^Package,
	file:        ^File,
}

Site_Package_Index :: struct {
	pkg:        ^Package,
	entries:    map[string]^Entry,
	duplicates: map[string]bool,
}

// Site_Render_Indexes make token-level link rendering scale with the number of
// tokens rather than repeatedly scanning every declaration in a package.
Site_Render_Indexes :: struct {
	packages:         [dynamic]Site_Package_Index,
	by_package:       map[^Package]^Site_Package_Index,
	by_relative_path: map[string]^Package,
	by_path:          map[string]^Package,
}

site_render_indexes_build :: proc(model: ^Model, allocator: mem.Allocator = context.allocator) -> Site_Render_Indexes {
	if model == nil do return {}
	indexes := Site_Render_Indexes{
		packages = make([dynamic]Site_Package_Index, 0, len(model.packages), allocator),
		by_package = make(map[^Package]^Site_Package_Index, len(model.packages), allocator),
		by_relative_path = make(map[string]^Package, len(model.packages), allocator),
		by_path = make(map[string]^Package, len(model.packages), allocator),
	}
	for &pkg in model.packages {
		if !site_package_is_renderable(pkg) do continue
		indexes.by_relative_path[pkg.relative_path] = &pkg
		indexes.by_path[pkg.path] = &pkg
		entry_capacity := 0
		for &file in pkg.files do entry_capacity += len(file.entries)
		pkg_index := Site_Package_Index{
			pkg = &pkg,
			entries = make(map[string]^Entry, entry_capacity, allocator),
			duplicates = make(map[string]bool, 0, allocator),
		}
		for &file in pkg.files {
			for &entry in file.entries {
				if _, duplicate := pkg_index.duplicates[entry.name]; duplicate do continue
				if _, exists := pkg_index.entries[entry.name]; exists {
					delete_key(&pkg_index.entries, entry.name)
					pkg_index.duplicates[entry.name] = true
					continue
				}
				pkg_index.entries[entry.name] = &entry
			}
		}
		append(&indexes.packages, pkg_index)
		indexes.by_package[&pkg] = &indexes.packages[len(indexes.packages)-1]
	}
	return indexes
}

site_render_indexes_destroy :: proc(indexes: ^Site_Render_Indexes) {
	if indexes == nil do return
	for &pkg_index in indexes.packages {
		delete(pkg_index.entries)
		delete(pkg_index.duplicates)
	}
	delete(indexes.packages)
	delete(indexes.by_package)
	delete(indexes.by_relative_path)
	delete(indexes.by_path)
	indexes^ = {}
}

site_index_for_package :: proc(indexes: ^Site_Render_Indexes, pkg: ^Package) -> ^Site_Package_Index {
	if indexes == nil || pkg == nil do return nil
	pkg_index, ok := indexes.by_package[pkg]
	if ok do return pkg_index
	return nil
}

odin_token_class :: proc(kind: tokenizer.Token_Kind) -> string {
	if tokenizer.is_keyword(kind) do return "tok-keyword"
	if tokenizer.is_literal(kind) do return "tok-literal"
	if tokenizer.is_operator(kind) do return "tok-operator"
	#partial switch kind {
	case .Comment:
		return "tok-comment"
	case .File_Tag:
		return "tok-directive"
	case .Invalid:
		return "tok-invalid"
	case:
		return "tok-ident"
	}
}

write_odin_code :: proc(builder: ^strings.Builder, code: string, ctx: Doc_Render_Context) {
	lexer: tokenizer.Tokenizer
	tokenizer.init(&lexer, code, "", nil)
	cursor := 0
	previous_kind := tokenizer.Token_Kind.Invalid
	previous_ident := ""
	selector_alias := ""
	directive_name_follows := false
	for {
		token := tokenizer.scan(&lexer)
		if token.kind == .EOF do break
		start := clamp(token.pos.offset, 0, len(code))
		if start > cursor do html_text(builder, code[cursor:start])
		text := token.text
		end := min(len(code), start + len(text))
		if len(text) == 0 {
			cursor = max(cursor, end)
			continue
		}

		is_directive := text == "#" || directive_name_follows
		class := odin_token_class(token.kind)
		if is_directive do class = "tok-directive"
		href := ""
		linked := false
		if token.kind == .Ident && !is_directive {
			if len(selector_alias) > 0 {
				href, linked = site_internal_href(ctx, strings.concatenate({selector_alias, ".", text}, context.temp_allocator), false)
			} else {
				href, linked = site_internal_href(ctx, text, false)
			}
		}
		if linked {
			strings.write_string(builder, "<a class=\"tok-link "); strings.write_string(builder, class); strings.write_string(builder, "\" href=\"")
			html_attr(builder, href)
			strings.write_string(builder, "\">"); html_text(builder, text); strings.write_string(builder, "</a>")
		} else {
			strings.write_string(builder, "<span class=\""); strings.write_string(builder, class); strings.write_string(builder, "\">")
			html_text(builder, text)
			strings.write_string(builder, "</span>")
		}
		cursor = max(cursor, end)
		directive_name_follows = text == "#"
		if token.kind == .Period && previous_kind == .Ident {
			selector_alias = previous_ident
		} else if token.kind == .Ident {
			previous_ident = text
			selector_alias = ""
		} else if token.kind != .Period {
			selector_alias = ""
		}
		previous_kind = token.kind
	}
	if cursor < len(code) do html_text(builder, code[cursor:])
}

site_entry_find_unique :: proc(indexes: ^Site_Render_Indexes, pkg: ^Package, name: string) -> (^Entry, bool) {
	if pkg == nil || len(name) == 0 do return nil, false
	if pkg_index := site_index_for_package(indexes, pkg); pkg_index != nil {
		entry, ok := pkg_index.entries[name]
		return entry, ok
	}
	matched: ^Entry
	for &file in pkg.files {
		for &entry in file.entries {
			if entry.name != name do continue
			if matched != nil do return nil, false
			matched = &entry
		}
	}
	return matched, matched != nil
}

site_package_find_relative :: proc(indexes: ^Site_Render_Indexes, model: ^Model, relative_path: string) -> ^Package {
	if model == nil || len(relative_path) == 0 do return nil
	if indexes != nil {
		pkg, ok := indexes.by_relative_path[relative_path]
		if ok do return pkg
	}
	for &pkg in model.packages {
		if !site_package_is_renderable(pkg) do continue
		if pkg.relative_path == relative_path do return &pkg
	}
	return nil
}

site_package_find_path :: proc(indexes: ^Site_Render_Indexes, model: ^Model, package_path: string) -> ^Package {
	if model == nil || len(package_path) == 0 do return nil
	if indexes != nil {
		pkg, ok := indexes.by_path[package_path]
		if ok do return pkg
	}
	for &pkg in model.packages {
		if !site_package_is_renderable(pkg) do continue
		clean, err := filepath.clean(pkg.path, context.temp_allocator)
		if err == nil && clean == package_path do return &pkg
	}
	return nil
}

site_package_for_import :: proc(indexes: ^Site_Render_Indexes, model: ^Model, current: ^Package, import_path: string) -> ^Package {
	path := strings.trim_space(import_path)
	if len(path) == 0 do return nil
	if colon := strings.index_byte(path, ':'); colon >= 0 {
		collection, suffix := path[:colon], path[colon + 1:]
		if qualified := site_package_find_relative(indexes, model, path_join({collection, suffix})); qualified != nil do return qualified
		// Some workspace snapshots omit collection folders from their displayed path.
		if fallback := site_package_find_relative(indexes, model, suffix); fallback != nil do return fallback
		return nil
	}
	if current != nil {
		relative_candidate := path_join({filepath.dir(current.relative_path), path})
		if clean, err := filepath.clean(relative_candidate, context.temp_allocator); err == nil {
			if target := site_package_find_relative(indexes, model, clean); target != nil do return target
		}
		physical_candidate := path_join({current.path, path})
		if clean, err := filepath.clean(physical_candidate, context.temp_allocator); err == nil {
			if target := site_package_find_path(indexes, model, clean); target != nil do return target
		}
	}
	if clean, err := filepath.clean(path, context.temp_allocator); err == nil do return site_package_find_relative(indexes, model, clean)
	return nil
}

site_import_find_alias :: proc(file: ^File, alias: string) -> ^Import {
	if file == nil || len(alias) == 0 do return nil
	for &import_entry in file.imports {
		if import_entry.alias == alias do return &import_entry
	}
	return nil
}

site_internal_href :: proc(ctx: Doc_Render_Context, raw_url: string, resolve_package := true) -> (string, bool) {
	if ctx.model == nil || ctx.pkg == nil do return "", false
	url := strings.trim_space(raw_url)
	if len(url) == 0 do return "", false
	if url[0] == '#' {
		anchor := url[1:]
		for &file in ctx.pkg.files {
			for &entry in file.entries {
				if entry.anchor == anchor do return url, true
			}
		}
		return "", false
	}
	// Imported alias.Symbol names can be resolved without guessing across
	// unrelated packages. This is intentionally stricter than global name lookup.
	if dot := strings.index_byte(url, '.'); dot > 0 && dot + 1 < len(url) {
		if import_entry := site_import_find_alias(ctx.file, url[:dot]); import_entry != nil {
			if target_pkg := site_package_for_import(ctx.indexes, ctx.model, ctx.pkg, import_entry.path); target_pkg != nil {
				if target_entry, ok := site_entry_find_unique(ctx.indexes, target_pkg, url[dot + 1:]); ok {
					target_path := path_join({ctx.output_root, package_output_path(target_pkg^)})
					return package_href_from(ctx.page_path, target_path, target_entry.anchor), true
				}
			}
		}
	}
	if target_entry, ok := site_entry_find_unique(ctx.indexes, ctx.pkg, url); ok {
		return strings.concatenate({"#", target_entry.anchor}, context.temp_allocator), true
	}
	if !resolve_package do return "", false
	if target_pkg := site_package_for_import(ctx.indexes, ctx.model, ctx.pkg, url); target_pkg != nil {
		target_path := path_join({ctx.output_root, package_output_path(target_pkg^)})
		return package_href_from(ctx.page_path, target_path, ""), true
	}
	return "", false
}

write_inline :: proc(builder: ^strings.Builder, text: string, ctx: Doc_Render_Context) {
	segments := markup_inline_parse(text, context.allocator)
	defer markup_inline_destroy(&segments, context.allocator)
	for segment in segments {
		switch segment.kind {
		case .Text:
			html_text(builder, segment.text)
		case .Code:
			strings.write_string(builder, "<code>"); html_text(builder, segment.text); strings.write_string(builder, "</code>")
		case .Bold:
			strings.write_string(builder, "<strong>"); html_text(builder, segment.text); strings.write_string(builder, "</strong>")
		case .Link:
			if strings.has_prefix(segment.url, "https://") || strings.has_prefix(segment.url, "http://") || strings.has_prefix(segment.url, "mailto:") {
				strings.write_string(builder, "<a href=\""); html_attr(builder, segment.url); strings.write_string(builder, "\" rel=\"noreferrer noopener\" target=\"_blank\">"); html_text(builder, segment.text); strings.write_string(builder, "</a>")
			} else if href, ok := site_internal_href(ctx, segment.url); ok {
				strings.write_string(builder, "<a href=\""); html_attr(builder, href); strings.write_string(builder, "\">"); html_text(builder, segment.text); strings.write_string(builder, "</a>")
			} else {
				html_text(builder, segment.text)
			}
		}
	}
}

doc_table_separator_row :: proc(cells: []string) -> bool {
	if len(cells) == 0 do return false
	for cell in cells {
		trimmed := strings.trim_space(cell)
		if len(trimmed) == 0 do return false
		for ch in trimmed {
			if ch != '-' && ch != ':' do return false
		}
	}
	return true
}

write_doc_table :: proc(builder: ^strings.Builder, lines: []string, ctx: Doc_Render_Context) {
	if len(lines) == 0 do return
	has_header := false
	if len(lines) > 1 {
		separator_text := strings.trim_space(lines[1])
		if len(separator_text) >= 2 && separator_text[0] == '|' && separator_text[len(separator_text) - 1] == '|' {
			separator_text = separator_text[1:len(separator_text) - 1]
		}
		separator_cells := strings.split(separator_text, "|", context.temp_allocator)
		has_header = doc_table_separator_row(separator_cells[:])
	}
	strings.write_string(builder, "<div class=\"doc-table-wrap\"><table class=\"doc-table\">")
	for line, line_index in lines {
		trimmed := strings.trim_space(line)
		if len(trimmed) >= 2 && trimmed[0] == '|' && trimmed[len(trimmed) - 1] == '|' {
			trimmed = trimmed[1:len(trimmed) - 1]
		}
		cells := strings.split(trimmed, "|", context.temp_allocator)
		if has_header && line_index == 1 {
			continue
		}
		strings.write_string(builder, "<tr>")
		for cell in cells {
			if has_header && line_index == 0 {
				strings.write_string(builder, "<th scope=\"col\">")
			} else {
				strings.write_string(builder, "<td>")
			}
			write_inline(builder, strings.trim_space(cell), ctx)
			if has_header && line_index == 0 {
				strings.write_string(builder, "</th>")
			} else {
				strings.write_string(builder, "</td>")
			}
		}
		strings.write_string(builder, "</tr>")
	}
	strings.write_string(builder, "</table></div>")
}

write_doc_body :: proc(builder: ^strings.Builder, text: string, ctx: Doc_Render_Context) {
	if len(strings.trim_space(text)) == 0 do return
	blocks := markup_blocks_parse(text, context.allocator)
	defer markup_blocks_destroy(&blocks, context.allocator)
	for block in blocks {
		joined := strings.join(block.lines[:], "\n", context.temp_allocator)
		switch block.kind {
		case .Heading:
			level := 2
			if len(block.title) > 0 do level = min(6, max(2, int(block.title[0] - '0') + 1))
			fmt.sbprintf(builder, "<h%d>", level); write_inline(builder, joined, ctx); fmt.sbprintf(builder, "</h%d>", level)
		case .Horizontal_Rule:
			strings.write_string(builder, "<hr>")
		case .List:
			strings.write_string(builder, "<ul>")
			for line in block.lines { strings.write_string(builder, "<li>"); write_inline(builder, line, ctx); strings.write_string(builder, "</li>") }
			strings.write_string(builder, "</ul>")
		case .Code, .Example, .Operation, .Output, .Possible_Output:
			if len(block.title) > 0 { strings.write_string(builder, "<h4>"); html_text(builder, block.title); strings.write_string(builder, "</h4>") }
			strings.write_string(builder, "<pre><code>")
			if block.kind == .Code || block.kind == .Example { write_odin_code(builder, joined, ctx) } else { html_text(builder, joined) }
			strings.write_string(builder, "</code></pre>")
		case .Table:
			write_doc_table(builder, block.lines[:], ctx)
		case .Paragraph:
			paragraph, _ := strings.replace_all(joined, "\n", " ", context.temp_allocator)
			strings.write_string(builder, "<p>"); write_inline(builder, paragraph, ctx); strings.write_string(builder, "</p>")
		}
	}
}

entry_group_for_kind :: proc(kind: string) -> Entry_Group {
	switch kind {
	case "Types": return .Types
	case "Constants": return .Constants
	case "Variables": return .Variables
	case "Procedures": return .Procedures
	case "Procedure Groups": return .Procedure_Groups
	case: return .Other
	}
}

entry_group_title :: proc(group: Entry_Group) -> string {
	switch group {
	case .Types: return "Types"
	case .Constants: return "Constants"
	case .Variables: return "Variables"
	case .Procedures: return "Procedures"
	case .Procedure_Groups: return "Procedure Groups"
	case .Other: return "Other Declarations"
	}
	return "Other Declarations"
}

entry_group_anchor :: proc(group: Entry_Group) -> string {
	switch group {
	case .Types: return "group-types"
	case .Constants: return "group-constants"
	case .Variables: return "group-variables"
	case .Procedures: return "group-procedures"
	case .Procedure_Groups: return "group-procedure-groups"
	case .Other: return "group-other"
	}
	return "group-other"
}

package_entry_less :: proc(left, right: Package_Entry) -> bool {
	if left.entry.name != right.entry.name do return left.entry.name < right.entry.name
	if left.file.name != right.file.name do return left.file.name < right.file.name
	if left.entry.source_line != right.entry.source_line do return left.entry.source_line < right.entry.source_line
	return left.entry.anchor < right.entry.anchor
}

package_group_entries :: proc(pkg: ^Package, group: Entry_Group) -> [dynamic]Package_Entry {
	entries := make([dynamic]Package_Entry, 0, 8)
	for &file in pkg.files {
		for &entry in file.entries {
			if entry_group_for_kind(entry.kind) == group do append(&entries, Package_Entry{entry = &entry, file = &file})
		}
	}
	slice.sort_by(entries[:], package_entry_less)
	return entries
}

write_package_entry :: proc(builder: ^strings.Builder, model: ^Model, package_context: Doc_Render_Context, config: Config, item: Package_Entry) {
	entry := item.entry
	entry_context := package_context
	entry_context.file = item.file
	strings.write_string(builder, "<article class=\"symbol\" id=\"")
	html_attr(builder, entry.anchor)
	strings.write_string(builder, "\"><header class=\"symbol-heading\"><h3><a class=\"symbol-name\" href=\"#")
	html_attr(builder, entry.anchor)
	strings.write_string(builder, "\">")
	html_text(builder, entry.name)
	strings.write_string(builder, "</a><span class=\"kind\">")
	html_text(builder, entry_kind_singular(entry.kind))
	strings.write_string(builder, "</span></h3>")
	if href, ok := source_href(config, model, entry^); ok {
		strings.write_string(builder, "<a class=\"source-link\" href=\""); html_attr(builder, href); strings.write_string(builder, "\" rel=\"noreferrer noopener\" target=\"_blank\">Source</a>")
	}
	strings.write_string(builder, "</header><pre><code>")
	write_odin_code(builder, entry.signature, entry_context)
	strings.write_string(builder, "</code></pre>")
	if len(entry.summary) > 0 { strings.write_string(builder, "<p class=\"summary\">"); html_text(builder, entry.summary); strings.write_string(builder, "</p>") }
	write_doc_body(builder, entry_body(entry^), entry_context)
	strings.write_string(builder, "</article>")
}

write_package_entry_group :: proc(builder: ^strings.Builder, model: ^Model, package_context: Doc_Render_Context, config: Config, group: Entry_Group, entries: []Package_Entry) {
	if len(entries) == 0 do return
	anchor := entry_group_anchor(group)
	strings.write_string(builder, "<section class=\"entry-group\" id=\""); html_attr(builder, anchor); strings.write_string(builder, "\" aria-labelledby=\"")
	html_attr(builder, strings.concatenate({anchor, "-heading"}, context.temp_allocator))
	strings.write_string(builder, "\"><header class=\"entry-group-heading\"><h2 id=\"")
	html_attr(builder, strings.concatenate({anchor, "-heading"}, context.temp_allocator))
	strings.write_string(builder, "\">"); html_text(builder, entry_group_title(group)); strings.write_string(builder, "</h2><span class=\"entry-group-count\">")
	write_grouped_count(builder, len(entries))
	strings.write_string(builder, "</span></header>")
	for item in entries do write_package_entry(builder, model, package_context, config, item)
	strings.write_string(builder, "</section>")
}

write_package_toc_group :: proc(builder: ^strings.Builder, group: Entry_Group, entries: []Package_Entry) {
	if len(entries) == 0 do return
	anchor := entry_group_anchor(group)
	strings.write_string(builder, "<section class=\"toc-group\" data-toc-group=\"")
	html_attr(builder, anchor)
	strings.write_string(builder, "\"><a class=\"toc-group-link\" data-toc-group-target=\"")
	html_attr(builder, anchor)
	strings.write_string(builder, "\" href=\"#")
	html_attr(builder, anchor)
	strings.write_string(builder, "\">"); html_text(builder, entry_group_title(group)); strings.write_string(builder, " <span>")
	write_grouped_count(builder, len(entries))
	strings.write_string(builder, "</span></a><div class=\"toc-entries\">")
	for item in entries {
		strings.write_string(builder, "<a class=\"toc-entry\" data-toc-target=\"")
		html_attr(builder, item.entry.anchor)
		strings.write_string(builder, "\" href=\"#")
		html_attr(builder, item.entry.anchor)
		strings.write_string(builder, "\">")
		html_text(builder, item.entry.name)
		strings.write_string(builder, "</a>")
	}
	strings.write_string(builder, "</div></section>")
}

write_package_page :: proc(model: ^Model, indexes: ^Site_Render_Indexes, pkg: ^Package, config: Config, extensions: Site_Extensions, output_root: string) -> string {
	page_relative := package_output_path(pkg^)
	page_path := path_join({output_root, page_relative})
	assets_relative, _ := filepath.rel(filepath.dir(page_path), path_join({output_root, "assets"}), context.temp_allocator)
	assets_relative = strings.concatenate({assets_relative, "/"}, context.temp_allocator)
	site_root, _ := filepath.rel(filepath.dir(page_path), output_root, context.temp_allocator)
	site_root = strings.concatenate({site_root, "/"}, context.temp_allocator)
	builder: strings.Builder
	defer strings.builder_destroy(&builder)
	site_head(&builder, pkg.name, config.title, assets_relative, site_root, config, extensions)
	if len(extensions.before_content) > 0 do strings.write_string(&builder, string(extensions.before_content[:]))
	strings.write_string(&builder, "<main id=\"main\" class=\"reference-layout\"><aside class=\"package-explorer\"><nav aria-label=\"Package explorer\"><p class=\"explorer-title\">Packages</p>")
	write_package_tree(&builder, model, page_path, output_root, pkg.relative_path, false, false)
	strings.write_string(&builder, "</nav></aside><article class=\"reference\"><nav class=\"breadcrumb\" aria-label=\"Breadcrumb\"><a href=\"")
	html_attr(&builder, package_href_from(page_path, path_join({output_root, "index.html"}), ""))
	strings.write_string(&builder, "\">Packages</a> / ")
	html_text(&builder, pkg.name)
	strings.write_string(&builder, "</nav><header class=\"package-heading\"><p class=\"package-path\">")
	html_text(&builder, pkg.relative_path)
	strings.write_string(&builder, "</p><h1>")
	html_text(&builder, pkg.name)
	strings.write_string(&builder, "</h1></header>")
	package_context := Doc_Render_Context{model = model, indexes = indexes, output_root = output_root, page_path = page_path, pkg = pkg}
	write_doc_body(&builder, pkg.overview, package_context)
	for group in ENTRY_GROUP_ORDER {
		entries := package_group_entries(pkg, group)
		defer delete(entries)
		write_package_entry_group(&builder, model, package_context, config, group, entries[:])
	}
	strings.write_string(&builder, "</article><aside class=\"package-toc\"><nav aria-label=\"On this page\"><p class=\"toc-title\">On this page</p><a class=\"toc-overview\" href=\"#main\">Overview</a><div class=\"toc-jumps\" aria-label=\"Declaration groups\">")
	for group in ENTRY_GROUP_ORDER {
		entries := package_group_entries(pkg, group)
		defer delete(entries)
		if len(entries) == 0 do continue
		anchor := entry_group_anchor(group)
		strings.write_string(&builder, "<a href=\"#"); html_attr(&builder, anchor); strings.write_string(&builder, "\">")
		html_text(&builder, entry_group_title(group))
		strings.write_string(&builder, "</a>")
	}
	strings.write_string(&builder, "</div>")
	for group in ENTRY_GROUP_ORDER {
		entries := package_group_entries(pkg, group)
		defer delete(entries)
		write_package_toc_group(&builder, group, entries[:])
	}
	strings.write_string(&builder, "</nav></aside></main>")
	site_footer(&builder, assets_relative, extensions)
	return write_text_file(page_path, &builder)
}

package_symbol_count :: proc(pkg: Package) -> int {
	count := 0
	for file in pkg.files do count += len(file.entries)
	return count
}

// The upstream pkg.odin-lang.org renderer admits a package only when it has
// public scope entries and its collection-relative path does not contain "/_".
// Keep this strictly in the render layer: .odin-doc input and Varde's model
// retain hidden helper packages for data fidelity and non-rendering consumers.
//
// Deliberately do not broaden this to names such as "tests" or "tools". The
// upstream rule is path-based, and a collection-root package named "_foo" is
// not excluded because it has no "/_" segment.
site_package_is_renderable :: proc(pkg: Package) -> bool {
	if package_symbol_count(pkg) == 0 do return false
	return !strings.contains(pkg.relative_path, "/_")
}

site_render_stats :: proc(model: ^Model) -> Stats {
	if model == nil do return {}
	stats := Stats{sloc = model.stats.sloc}
	for pkg in model.packages {
		if !site_package_is_renderable(pkg) do continue
		stats.package_count += 1
		stats.file_count += len(pkg.files)
		stats.entry_count += package_symbol_count(pkg)
	}
	return stats
}

@(test)
test_site_renderer_matches_upstream_package_visibility_rule :: proc(t: ^testing.T) {
	visible := Package{relative_path = "core/crypto/aes", files = make([dynamic]File, 0, 1)}
	defer {
		delete(visible.files[0].entries)
		delete(visible.files)
	}
	visible_file := File{entries = make([dynamic]Entry, 0, 1)}
	append(&visible_file.entries, Entry{name = "Encrypt"})
	append(&visible.files, visible_file)

	underscore_helper := visible
	underscore_helper.relative_path = "core/crypto/_aes/ct64"
	empty := Package{relative_path = "core/crypto/hash", files = make([dynamic]File, 0, 1)}
	defer {
		delete(empty.files[0].entries)
		delete(empty.files)
	}
	append(&empty.files, File{entries = make([dynamic]Entry, 0)})
	collection_root_underscore := visible
	collection_root_underscore.relative_path = "_private"

	testing.expect(t, site_package_is_renderable(visible), "public packages with entries should render")
	testing.expect(t, !site_package_is_renderable(underscore_helper), "a nested underscore path must be hidden like pkg.odin-lang.org")
	testing.expect(t, !site_package_is_renderable(empty), "packages without public entries must not get pages")
	testing.expect(t, site_package_is_renderable(collection_root_underscore), "the upstream /_ rule does not hide a collection-root underscore name")
}

@(test)
test_site_build_excludes_upstream_hidden_packages_everywhere :: proc(t: ^testing.T) {
	root, root_err := os.make_directory_temp("", "varde-render-filter-*", context.temp_allocator)
	testing.expect(t, root_err == nil, "temporary renderer-filter workspace should be created")
	defer _ = os.remove_all(root)

	model := Model{workspace_path = root, stats = {package_count = 3, file_count = 3, entry_count = 2}}
	model.packages = make([dynamic]Package, 0, 3)
	defer {
		for &pkg in model.packages {
			for &file in pkg.files do delete(file.entries)
			delete(pkg.files)
		}
		delete(model.packages)
	}
	visible := Package{name = "aes", relative_path = "core/crypto/aes", files = make([dynamic]File, 0, 1)}
	visible_file := File{name = "aes.odin", entries = make([dynamic]Entry, 0, 1)}
	append(&visible_file.entries, Entry{name = "Encrypt", anchor = "Encrypt", kind = "Procedures", signature = "Encrypt :: proc()"})
	append(&visible.files, visible_file)
	append(&model.packages, visible)
	hidden := Package{name = "_aes", relative_path = "core/crypto/_aes", files = make([dynamic]File, 0, 1)}
	hidden_file := File{name = "internal.odin", entries = make([dynamic]Entry, 0, 1)}
	append(&hidden_file.entries, Entry{name = "Hidden", anchor = "Hidden", kind = "Procedures", signature = "Hidden :: proc()"})
	append(&hidden.files, hidden_file)
	append(&model.packages, hidden)
	empty := Package{name = "empty", relative_path = "core/crypto/empty", files = make([dynamic]File, 0, 1)}
	append(&empty.files, File{name = "empty.odin", entries = make([dynamic]Entry, 0)})
	append(&model.packages, empty)

	config := config_default(root, "Filter", "Renderer policy test.")
	result := build(&model, config, {})
	testing.expect(t, result.ok && result.package_count == 1 && result.entry_count == 1, "only the public package should be reported as rendered")
	site_root := path_join({root, config.output_dir})
	visible_page := path_join({site_root, "packages", "core", "crypto", "aes", "index.html"})
	hidden_page := path_join({site_root, "packages", "core", "crypto", "_aes", "index.html"})
	empty_page := path_join({site_root, "packages", "core", "crypto", "empty", "index.html"})
	testing.expect(t, os.exists(visible_page), "visible packages should retain their page")
	testing.expect(t, !os.exists(hidden_page) && !os.exists(empty_page), "hidden and empty packages must not get pages")

	index_data, index_err := os.read_entire_file(path_join({site_root, "index.html"}), context.temp_allocator)
	defer if index_err == nil do delete(index_data, context.temp_allocator)
	search_data, search_err := os.read_entire_file(path_join({site_root, "assets", "search-index.js"}), context.temp_allocator)
	defer if search_err == nil do delete(search_data, context.temp_allocator)
	manifest_data, manifest_err := os.read_entire_file(path_join({site_root, SITE_MANIFEST_FILE_NAME}), context.temp_allocator)
	defer if manifest_err == nil do delete(manifest_data, context.temp_allocator)
	testing.expect(t, index_err == nil && !strings.contains(string(index_data), "_aes") && !strings.contains(string(index_data), "empty"), "the package directory and homepage metrics must omit excluded packages")
	testing.expect(t, search_err == nil && strings.contains(string(search_data), "Encrypt") && !strings.contains(string(search_data), "Hidden") && !strings.contains(string(search_data), "_aes"), "excluded packages must not leak into offline search")
	testing.expect(t, manifest_err == nil && strings.contains(string(manifest_data), "\"packages\": 1") && strings.contains(string(manifest_data), "\"symbols\": 1"), "the manifest must report rendered rather than input package counts")
}

write_grouped_count :: proc(builder: ^strings.Builder, count: int) {
	text := fmt.tprintf("%d", count)
	first_digit := 0
	if len(text) > 0 && text[0] == '-' {
		strings.write_rune(builder, '-')
		first_digit = 1
	}
	for index in first_digit ..< len(text) {
		if index > first_digit && (len(text) - index) % 3 == 0 do strings.write_rune(builder, ',')
		strings.write_rune(builder, rune(text[index]))
	}
}

entry_kind_singular :: proc(kind: string) -> string {
	switch kind {
	case "Procedures": return "Procedure"
	case "Procedure Groups": return "Procedure Group"
	case "Types": return "Type"
	case "Variables": return "Variable"
	case "Constants": return "Constant"
	case "Config Values": return "Config Value"
	case: return kind
	}
}

Package_Tree_Node :: struct {
	name:          string,
	package_index: int,
	children:      [dynamic]int,
}

package_tree_child_find :: proc(nodes: []Package_Tree_Node, parent_index: int, name: string) -> int {
	for child_index in nodes[parent_index].children {
		if nodes[child_index].name == name do return child_index
	}
	return -1
}

package_tree_sort :: proc(nodes: ^[dynamic]Package_Tree_Node, node_index: int) {
	children := nodes[node_index].children[:]
	for left in 0 ..< len(children) {
		for right in left + 1 ..< len(children) {
			if nodes[children[right]].name < nodes[children[left]].name {
				children[left], children[right] = children[right], children[left]
			}
		}
	}
	for child_index in children do package_tree_sort(nodes, child_index)
}

package_tree_build :: proc(model: ^Model) -> [dynamic]Package_Tree_Node {
	nodes := make([dynamic]Package_Tree_Node, 0, max(1, len(model.packages) * 2), context.temp_allocator)
	append(&nodes, Package_Tree_Node{package_index = -1})
	for pkg, package_index in model.packages {
		if !site_package_is_renderable(pkg) do continue
		segments := strings.split(pkg.relative_path, "/", context.temp_allocator)
		current_index := 0
		for segment in segments {
			if len(segment) == 0 do continue
			next_index := package_tree_child_find(nodes[:], current_index, segment)
			if next_index < 0 {
				next_index = len(nodes)
				append(&nodes, Package_Tree_Node{name = segment, package_index = -1})
				append(&nodes[current_index].children, next_index)
			}
			current_index = next_index
		}
		if current_index != 0 do nodes[current_index].package_index = package_index
	}
	package_tree_sort(&nodes, 0)
	return nodes
}

package_tree_destroy :: proc(nodes: [dynamic]Package_Tree_Node) {
	for &node in nodes do delete(node.children)
	delete(nodes)
}

write_package_tree_children :: proc(
	builder: ^strings.Builder,
	model: ^Model,
	nodes: []Package_Tree_Node,
	node_index: int,
	page_path, output_root, active_relative_path: string,
	show_metadata, collapse_branches: bool,
) {
	for child_index in nodes[node_index].children {
		node := nodes[child_index]
		has_children := len(node.children) > 0
		strings.write_string(builder, "<li>")
		if collapse_branches && has_children do strings.write_string(builder, "<details class=\"package-branch\" data-package-branch><summary>")
		if node.package_index >= 0 {
			pkg := &model.packages[node.package_index]
			target_path := path_join({output_root, package_output_path(pkg^)})
			strings.write_string(builder, "<a class=\"tree-package")
			if pkg.relative_path == active_relative_path do strings.write_string(builder, " is-active")
			strings.write_string(builder, "\" href=\""); html_attr(builder, package_href_from(page_path, target_path, "")); strings.write_string(builder, "\"")
			if pkg.relative_path == active_relative_path do strings.write_string(builder, " aria-current=\"page\"")
			strings.write_string(builder, "><span class=\"tree-name\">"); html_text(builder, node.name); strings.write_string(builder, "</span>")
			if show_metadata {
				strings.write_string(builder, "<span class=\"tree-meta\">"); html_text(builder, pkg.name); strings.write_string(builder, " · "); write_grouped_count(builder, len(pkg.files)); strings.write_string(builder, " files · "); write_grouped_count(builder, package_symbol_count(pkg^)); strings.write_string(builder, " symbols</span>")
			}
			strings.write_string(builder, "</a>")
		} else {
			strings.write_string(builder, "<span class=\"tree-folder\">"); html_text(builder, node.name); strings.write_string(builder, "</span>")
		}
		if collapse_branches && has_children do strings.write_string(builder, "</summary>")
		if has_children {
			strings.write_string(builder, "<ul>")
			write_package_tree_children(builder, model, nodes, child_index, page_path, output_root, active_relative_path, show_metadata, collapse_branches)
			strings.write_string(builder, "</ul>")
		}
		if collapse_branches && has_children do strings.write_string(builder, "</details>")
		strings.write_string(builder, "</li>")
	}
}

write_package_tree :: proc(builder: ^strings.Builder, model: ^Model, page_path, output_root, active_relative_path: string, show_metadata, collapse_branches: bool) {
	nodes := package_tree_build(model)
	defer package_tree_destroy(nodes)
	strings.write_string(builder, "<ul class=\"package-tree\">")
	write_package_tree_children(builder, model, nodes[:], 0, page_path, output_root, active_relative_path, show_metadata, collapse_branches)
	strings.write_string(builder, "</ul>")
}

write_index_page :: proc(model: ^Model, config: Config, extensions: Site_Extensions, output_root: string) -> string {
	page_path := path_join({output_root, "index.html"})
	builder: strings.Builder
	defer strings.builder_destroy(&builder)
	site_head(&builder, config.title, config.title, "assets/", "", config, extensions)
	if len(extensions.before_content) > 0 do strings.write_string(&builder, string(extensions.before_content[:]))
	strings.write_string(&builder, "<main id=\"main\" class=\"home\"><section class=\"hero\">")
	if config.include_brand_artwork { strings.write_string(&builder, "<img src=\"assets/brand-mark.png\" width=\"64\" height=\"64\" alt=\"Project mark\">") }
	strings.write_string(&builder, "<h1>"); html_text(&builder, config.title); strings.write_string(&builder, "</h1><p>"); html_text(&builder, config.description); strings.write_string(&builder, "</p></section><section class=\"metrics\" aria-label=\"Workspace statistics\"><span>")
	render_stats := site_render_stats(model)
	write_grouped_count(&builder, render_stats.package_count)
	strings.write_string(&builder, " packages</span><span>"); write_grouped_count(&builder, render_stats.file_count)
	strings.write_string(&builder, " files</span><span>"); write_grouped_count(&builder, render_stats.entry_count)
	strings.write_string(&builder, " symbols</span><span>"); write_grouped_count(&builder, model.stats.sloc)
	strings.write_string(&builder, " SLOC</span></section>")
	strings.write_string(&builder, "<section class=\"package-directory\"><div class=\"section-heading\"><h2>Package directory</h2><p>The workspace hierarchy, preserved for browsing.</p></div>")
	write_package_tree(&builder, model, page_path, output_root, "", true, true)
	strings.write_string(&builder, "</section></main>")
	site_footer(&builder, "assets/", extensions)
	return write_text_file(page_path, &builder)
}

// This runs before the stylesheet is requested. It applies a persisted preset
// (including the reader's system-light/system-dark choices) before a page can
// flash with the wrong palette.
SITE_THEME_BOOTSTRAP_JS :: `(()=>{const r=document.documentElement,d=r.dataset,k="varde-settings",presets=["odin-light","monokai","github-light","tokyo-night"],dark=new Set(["monokai","tokyo-night"]),normalize=v=>v==="light"?"odin-light":v==="dark"?"monokai":v,validPreset=v=>presets.includes(normalize(v)),validTheme=v=>v==="system"||validPreset(v),validMotion=v=>v==="system"||v==="full"||v==="reduced",validTab=v=>v==="2"||v==="4"||v==="8",palette={"odin-light":["#f7f9ff","#14213d"],monokai:["#272822","#f8f8f2"],"github-light":["#ffffff","#1f2328"],"tokyo-night":["#1a1b26","#c0caf5"]};let raw="";try{raw=localStorage.getItem(k)||""}catch(_){}if(!raw)try{const bag=window.name?JSON.parse(window.name):{};raw=typeof bag.__varde_settings_v1__==="string"?bag.__varde_settings_v1__:""}catch(_){}let saved={};try{saved=JSON.parse(raw||"{}")||{}}catch(_){}const theme=validTheme(saved.theme)?normalize(saved.theme):normalize(d.defaultTheme)||"system",systemLight=validPreset(saved.systemLightTheme)?normalize(saved.systemLightTheme):normalize(d.systemLightTheme)||"odin-light",systemDark=validPreset(saved.systemDarkTheme)?normalize(saved.systemDarkTheme):normalize(d.systemDarkTheme)||"monokai",motion=validMotion(saved.motion)?saved.motion:d.defaultMotion||"system",tab=validTab(String(saved.tabWidth))?String(saved.tabWidth):d.defaultTabWidth||"4",resolved=theme==="system"?(matchMedia("(prefers-color-scheme: dark)").matches?systemDark:systemLight):theme,colors=palette[resolved]||palette["odin-light"];d.theme=resolved;d.motion=motion;r.style.colorScheme=dark.has(resolved)?"dark":"light";r.style.backgroundColor=colors[0];r.style.color=colors[1];r.style.setProperty("--code-tab-width",tab)})();`

SITE_CSS :: `
:root { color-scheme: light dark; --bg:#f6f7f4; --surface:#ffffff; --surface-raised:#fbfcfa; --text:#1b231d; --muted:#617066; --line:#d8ded8; --accent:#08784b; --accent-ink:#ffffff; --code:#f0f4f0; --focus:#1d8dcb; font-family:ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
:root[data-theme="light"] { color-scheme:light; }
:root[data-theme="dark"] { color-scheme:dark; --bg:#101511; --surface:#18211a; --surface-raised:#1d2820; --text:#e7eee8; --muted:#a6b7a9; --line:#344338; --accent:#77d9a4; --accent-ink:#092016; --code:#0c130e; --focus:#75c7f5; }
@media(prefers-color-scheme:dark){:root:not([data-theme]){--bg:#101511;--surface:#18211a;--surface-raised:#1d2820;--text:#e7eee8;--muted:#a6b7a9;--line:#344338;--accent:#77d9a4;--accent-ink:#092016;--code:#0c130e;--focus:#75c7f5}}
*{box-sizing:border-box} body{margin:0;background:var(--bg);color:var(--text);line-height:1.55}button,input{font:inherit}button{color:var(--text);background:var(--surface);border:1px solid var(--line);padding:8px 12px;border-radius:8px;cursor:pointer}button:hover{border-color:var(--accent)}button:focus-visible,a:focus-visible,input:focus-visible{outline:3px solid color-mix(in srgb,var(--focus) 55%,transparent);outline-offset:2px}.site-header{min-height:68px;padding:0 max(5vw,24px);display:flex;align-items:center;gap:10px;border-bottom:1px solid var(--line);background:color-mix(in srgb,var(--bg) 93%,transparent);backdrop-filter:blur(12px);position:sticky;top:0;z-index:2}.brand{margin-right:auto;font-weight:760;letter-spacing:-.02em;color:var(--text);text-decoration:none}.site-header button:first-of-type{border-color:color-mix(in srgb,var(--accent) 38%,var(--line));color:var(--accent);font-weight:650}main{max-width:1080px;margin:0 auto;padding:52px max(5vw,24px) 96px}.hero{max-width:760px}.hero img{float:right;border-radius:15px;box-shadow:0 12px 32px color-mix(in srgb,var(--accent) 20%,transparent)}.hero h1{font-size:clamp(2.35rem,6vw,4.8rem);letter-spacing:-.055em;line-height:1;margin:.16em 0}.hero p{font-size:1.12rem;color:var(--muted);max-width:62ch}.metrics{display:flex;flex-wrap:wrap;gap:9px;margin:32px 0}.metrics span,.kind{font-size:.8rem;color:var(--muted);border:1px solid var(--line);padding:5px 9px;border-radius:999px;background:var(--surface-raised)}.packages{padding:0;list-style:none;display:grid;gap:10px}.packages a{display:block;text-decoration:none;color:var(--text);padding:18px 20px;background:var(--surface);border:1px solid var(--line);border-radius:12px;transition:border-color .14s ease,transform .14s ease}.packages a:hover{border-color:var(--accent);transform:translateY(-1px)}.packages strong,.packages span{display:block}.packages .package-path{margin-top:2px;color:var(--accent);font-size:.8rem;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}.packages span{color:var(--muted);font-size:.92rem}.reference{max-width:920px}.reference nav{font-size:.9rem;color:var(--muted)}.reference nav a{color:inherit}.reference h1{letter-spacing:-.035em}.file{padding:30px 0;border-top:1px solid var(--line)}.file:first-of-type{margin-top:30px}.imports{font-size:.9rem;color:var(--muted)}.symbol{padding:22px;margin:18px 0;background:var(--surface);border:1px solid var(--line);border-radius:12px;scroll-margin-top:88px}.symbol h3{margin:3px 0 12px;letter-spacing:-.02em}.symbol pre{overflow:auto;background:var(--code);padding:15px;border-radius:8px;border:1px solid color-mix(in srgb,var(--line) 75%,transparent)}.summary{font-weight:650}footer{max-width:1080px;margin:auto;padding:28px max(5vw,24px);border-top:1px solid var(--line);color:var(--muted);font-size:.85rem}.skip{position:absolute;left:-999px}.skip:focus{left:8px;top:8px;z-index:4;background:var(--surface);padding:8px}.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}dialog{width:min(720px,94vw);border:0;background:transparent;padding:0;color:var(--text)}dialog::backdrop{background:color-mix(in srgb,#071008 54%,transparent);backdrop-filter:blur(3px)}.search-dialog{background:var(--surface);border:1px solid var(--line);border-radius:16px;padding:22px;box-shadow:0 24px 70px color-mix(in srgb,#000 30%,transparent)}.search-dialog-header{display:flex;align-items:start;justify-content:space-between;gap:18px}.search-dialog-header h2{margin:0;letter-spacing:-.025em}.search-dialog-header button{font-size:1.3rem;line-height:1;padding:5px 10px}.eyebrow{margin:0 0 2px;color:var(--accent);font-size:.78rem;font-weight:750;text-transform:uppercase;letter-spacing:.09em}.search-dialog input{width:100%;margin:18px 0 8px;padding:14px 15px;font:inherit;background:var(--bg);color:var(--text);border:1px solid var(--line);border-radius:9px}.search-summary{min-height:1.6em;margin:0 0 10px;color:var(--muted);font-size:.9rem}.search-result{display:grid;grid-template-columns:auto 1fr;column-gap:9px;padding:11px 12px;color:var(--text);text-decoration:none;border-radius:8px;border:1px solid transparent}.search-result:hover,.search-result:focus,.search-result[data-selected="true"]{background:var(--code);border-color:color-mix(in srgb,var(--accent) 35%,var(--line));outline:none}.search-kind{align-self:start;color:var(--accent);font-size:.76rem;font-weight:700;padding-top:2px}.search-result strong{min-width:0}.search-result small{grid-column:2;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.search-hint{margin:16px 0 0;color:var(--muted);font-size:.82rem}.search-hint kbd{padding:1px 5px;border:1px solid var(--line);border-radius:4px;background:var(--surface-raised)}@media(max-width:620px){.site-header{padding:0 18px}.site-header kbd{display:none}main{padding-top:34px}.hero img{width:48px;height:48px}.symbol{padding:16px}.search-dialog{padding:18px}.search-result{grid-template-columns:1fr}.search-result small{grid-column:1}.search-kind{display:none}}
/* Dense reference pages deliberately follow the documentation-first rhythm of
   conventional language package sites: section rules, compact signatures, and
   a persistent local index rather than a stack of dashboard cards. */
main.reference-layout{max-width:1380px;display:grid;grid-template-columns:minmax(0,1fr) 218px;gap:48px;align-items:start;padding-top:32px}.reference-layout .reference{max-width:960px;min-width:0}.breadcrumb{font-size:.88rem;color:var(--muted)}.breadcrumb a{color:inherit}.package-heading{padding:10px 0 20px;border-bottom:1px solid var(--line)}.package-heading .package-path{margin:0;color:var(--muted);font-size:.84rem;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}.package-heading h1{margin:3px 0 0;font-size:clamp(2rem,4vw,3.2rem);line-height:1.08;letter-spacing:-.045em}.reference>.package-heading+*{margin-top:22px}.file{padding:28px 0 0;margin:0;border:0;border-top:1px solid var(--line)}.file:first-of-type{margin-top:28px}.file-heading h2{margin:0;font-size:1.12rem;letter-spacing:-.01em}.imports{margin:6px 0 16px;font-size:.84rem}.imports a{color:inherit;text-decoration-style:dotted}.symbol{padding:22px 0;margin:0;background:transparent;border:0;border-bottom:1px solid var(--line);border-radius:0;scroll-margin-top:88px}.symbol-heading{display:flex;align-items:baseline;gap:12px}.symbol .kind{display:inline-block;flex:none;margin:0;padding:2px 0;border:0;border-radius:0;background:transparent;color:var(--muted);font-size:.73rem;font-weight:700;text-transform:uppercase;letter-spacing:.07em}.symbol h3{margin:0;font-size:1.25rem;line-height:1.25}.symbol-name{color:var(--accent);text-decoration:none}.symbol-name:hover{text-decoration:underline}.symbol pre{margin:10px 0 0;padding:10px 14px;background:var(--code);border:1px solid var(--line);border-radius:6px;font-size:.94rem;line-height:1.45}.symbol p{margin:12px 0}.symbol .summary{font-weight:650}.symbol h4{margin:16px 0 4px;font-size:.92rem}.doc-table-wrap{overflow:auto;margin:14px 0;border:1px solid var(--line);border-radius:6px}.doc-table{width:100%;border-collapse:collapse;font-size:.92rem}.doc-table th,.doc-table td{padding:8px 11px;text-align:left;vertical-align:top;border-bottom:1px solid var(--line)}.doc-table th{background:var(--code);font-weight:700}.doc-table tr:last-child td{border-bottom:0}.doc-table p{margin:0}.package-toc{position:sticky;top:92px;max-height:calc(100vh - 112px);overflow:auto;border-left:1px solid var(--line);padding-left:18px;font-size:.84rem;line-height:1.35}.package-toc nav>a,.toc-group a{display:block;color:var(--muted);text-decoration:none;padding:3px 0}.package-toc a:hover,.package-toc a:focus-visible{color:var(--accent)}.toc-title{margin:0 0 7px;color:var(--text);font-weight:700}.toc-group{margin:12px 0}.toc-group .toc-file{color:var(--text);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.78rem;font-weight:650;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.toc-group .toc-entry{padding-left:9px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.reference-layout+footer{max-width:1380px}@media(max-width:980px){main.reference-layout{display:block;max-width:980px}.package-toc{display:none}.reference-layout .reference{max-width:none}}@media(max-width:620px){main.reference-layout{padding-top:24px}.symbol-heading{display:block}.symbol .kind{margin-bottom:4px}.symbol h3{font-size:1.13rem}.symbol pre{font-size:.84rem;padding:9px 11px}.file{padding-top:22px}}.package-directory{margin-top:46px}.section-heading{display:flex;align-items:baseline;justify-content:space-between;gap:20px;margin-bottom:10px}.section-heading h2{margin:0;letter-spacing:-.025em}.section-heading p{margin:0;color:var(--muted);font-size:.9rem}.home .packages{display:block;gap:0;margin:0;border:1px solid var(--line);border-radius:8px;overflow:hidden;background:var(--surface)}.home .packages li+li{border-top:1px solid var(--line)}.home .packages a{padding:11px 14px;border:0;border-radius:0;background:transparent;transform:none}.home .packages a:hover{background:var(--surface-raised);border-color:transparent;transform:none}.home .packages .package-route{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.92rem;color:var(--accent)}.home .packages .package-meta{margin-top:1px;font-size:.8rem}.home .packages .package-summary{margin-top:3px;font-size:.86rem;line-height:1.35}@media(max-width:620px){.section-heading{display:block}.section-heading p{margin-top:3px}}
`

// The first two presets deliberately echo Odin's public package site: a bright
// blue primary action and orange secondary accent in light mode, then a vivid
// Monokai-inspired dark reference surface. GitHub Light and Tokyo Night give
// readers two familiar alternatives without changing document structure.
SITE_THEME_PRESETS_CSS :: `
:root,:root[data-theme="odin-light"]{color-scheme:light;--bg:#f7f9ff;--surface:#ffffff;--surface-raised:#f2f6ff;--text:#14213d;--muted:#52627b;--line:#d6e0f0;--accent:#0059d6;--secondary:#f06f00;--accent-ink:#ffffff;--code:#edf3ff;--focus:#f06f00}
:root[data-theme="monokai"]{color-scheme:dark;--bg:#272822;--surface:#30312b;--surface-raised:#3a3b34;--text:#f8f8f2;--muted:#b6b5a9;--line:#515249;--accent:#a6e22e;--secondary:#fd971f;--accent-ink:#20211c;--code:#1f201b;--focus:#66d9ef}
:root[data-theme="github-light"]{color-scheme:light;--bg:#ffffff;--surface:#ffffff;--surface-raised:#f6f8fa;--text:#1f2328;--muted:#57606a;--line:#d0d7de;--accent:#0969da;--secondary:#bf8700;--accent-ink:#ffffff;--code:#f6f8fa;--focus:#0969da}
:root[data-theme="tokyo-night"]{color-scheme:dark;--bg:#1a1b26;--surface:#24283b;--surface-raised:#2f354f;--text:#c0caf5;--muted:#9aa5ce;--line:#414868;--accent:#7aa2f7;--secondary:#ff9e64;--accent-ink:#1a1b26;--code:#16161e;--focus:#bb9af7}
.site-header #site-search{display:inline-flex;align-items:center;gap:9px;min-height:40px;padding:0 10px 0 13px;border-color:var(--accent);border-radius:999px;background:var(--accent);color:var(--accent-ink);font-weight:750;box-shadow:0 4px 12px color-mix(in srgb,var(--accent) 24%,transparent);transition:background .14s ease,transform .14s ease,box-shadow .14s ease}.site-header #site-search:hover{border-color:var(--accent);background:color-mix(in srgb,var(--accent) 88%,#000);color:var(--accent-ink);transform:translateY(-1px);box-shadow:0 7px 16px color-mix(in srgb,var(--accent) 30%,transparent)}.site-header #site-search:focus-visible{outline-color:color-mix(in srgb,var(--focus) 68%,transparent)}.search-trigger-icon{display:block;flex:none;width:16px;height:16px;stroke:currentColor;stroke-width:2.1;stroke-linecap:round}.site-header #site-search kbd{display:inline-flex;align-items:center;justify-content:center;min-width:27px;margin-left:2px;padding:3px 5px;border:1px solid color-mix(in srgb,var(--accent-ink) 38%,transparent);border-radius:5px;background:color-mix(in srgb,var(--accent-ink) 14%,transparent);color:inherit;font-size:.69em;font-weight:750;letter-spacing:-.03em;line-height:1.05}.site-header #site-settings{color:var(--muted)}@media(max-width:620px){.site-header #site-search{padding:0 11px}.site-header #site-search span:not(.search-trigger-icon){display:none}}
.eyebrow{color:var(--secondary)}.settings-form fieldset{display:grid;gap:9px;margin:0;padding:12px;border:1px solid var(--line);border-radius:8px}.settings-form legend{padding:0 4px;color:var(--text);font-size:.86rem;font-weight:700}.settings-form fieldset p{margin:0;color:var(--muted);font-size:.78rem;line-height:1.4}.settings-form fieldset label{font-size:.8rem}
:root[data-theme="odin-light"] .tok-keyword{color:#005cc5}:root[data-theme="odin-light"] .tok-literal{color:#bf4d00}:root[data-theme="odin-light"] .tok-operator{color:#52627b}:root[data-theme="odin-light"] .tok-comment{color:#6a737d}:root[data-theme="odin-light"] .tok-directive{color:#7c3aed}:root[data-theme="odin-light"] .tok-invalid{color:#cf222e}:root[data-theme="odin-light"] .tok-link{color:#0059d6}
:root[data-theme="monokai"] .tok-keyword{color:#f92672}:root[data-theme="monokai"] .tok-literal{color:#ae81ff}:root[data-theme="monokai"] .tok-operator{color:#f8f8f2}:root[data-theme="monokai"] .tok-comment{color:#a7a799}:root[data-theme="monokai"] .tok-directive{color:#66d9ef}:root[data-theme="monokai"] .tok-invalid{color:#f92672}:root[data-theme="monokai"] .tok-link{color:#a6e22e}
:root[data-theme="github-light"] .tok-keyword{color:#cf222e}:root[data-theme="github-light"] .tok-literal{color:#0550ae}:root[data-theme="github-light"] .tok-operator{color:#57606a}:root[data-theme="github-light"] .tok-comment{color:#6e7781}:root[data-theme="github-light"] .tok-directive{color:#8250df}:root[data-theme="github-light"] .tok-invalid{color:#cf222e}:root[data-theme="github-light"] .tok-link{color:#0969da}
:root[data-theme="tokyo-night"] .tok-keyword{color:#bb9af7}:root[data-theme="tokyo-night"] .tok-literal{color:#ff9e64}:root[data-theme="tokyo-night"] .tok-operator{color:#89ddff}:root[data-theme="tokyo-night"] .tok-comment{color:#565f89}:root[data-theme="tokyo-night"] .tok-directive{color:#7dcfff}:root[data-theme="tokyo-night"] .tok-invalid{color:#f7768e}:root[data-theme="tokyo-night"] .tok-link{color:#7aa2f7}
`

// Keep the browser's document scrollbar native. These rules only theme scroll
// regions that belong to the documentation UI, where their own surface gives
// the track a clear visual home in either reader theme.
SITE_SCOPED_SCROLLBAR_CSS :: `
.package-explorer,.package-toc{--varde-scroll-surface:var(--bg);--varde-scroll-thumb:color-mix(in srgb,var(--muted) 58%,var(--bg));--varde-scroll-track-active:color-mix(in srgb,var(--surface-raised) 84%,var(--bg));scrollbar-width:thin;scrollbar-color:var(--varde-scroll-thumb) transparent}
.reference pre,.doc-table-wrap{--varde-scroll-surface:var(--code);--varde-scroll-thumb:color-mix(in srgb,var(--muted) 62%,var(--code));--varde-scroll-track-active:color-mix(in srgb,var(--surface-raised) 50%,var(--code));scrollbar-width:thin;scrollbar-color:var(--varde-scroll-thumb) transparent}
.search-results-scroll{--varde-scroll-surface:var(--surface);--varde-scroll-thumb:color-mix(in srgb,var(--muted) 58%,var(--surface));--varde-scroll-track-active:var(--surface-raised);scrollbar-width:thin;scrollbar-color:var(--varde-scroll-thumb) transparent}
.package-explorer:hover,.package-explorer:focus-within,.package-toc:hover,.package-toc:focus-within,.reference pre:hover,.reference pre:focus-within,.doc-table-wrap:hover,.doc-table-wrap:focus-within,.search-results-scroll:hover,.search-results-scroll:focus-within{scrollbar-color:var(--varde-scroll-thumb) var(--varde-scroll-track-active)}
.package-explorer::-webkit-scrollbar,.package-toc::-webkit-scrollbar,.reference pre::-webkit-scrollbar,.doc-table-wrap::-webkit-scrollbar,.search-results-scroll::-webkit-scrollbar{width:11px;height:11px}
.package-explorer::-webkit-scrollbar-track,.package-toc::-webkit-scrollbar-track,.reference pre::-webkit-scrollbar-track,.doc-table-wrap::-webkit-scrollbar-track,.search-results-scroll::-webkit-scrollbar-track{background:transparent}
.package-explorer::-webkit-scrollbar-thumb,.package-toc::-webkit-scrollbar-thumb,.reference pre::-webkit-scrollbar-thumb,.doc-table-wrap::-webkit-scrollbar-thumb,.search-results-scroll::-webkit-scrollbar-thumb{background:var(--varde-scroll-thumb);background-clip:padding-box;border:3px solid transparent;border-radius:999px}
.package-explorer:hover::-webkit-scrollbar-track,.package-explorer:focus-within::-webkit-scrollbar-track,.package-toc:hover::-webkit-scrollbar-track,.package-toc:focus-within::-webkit-scrollbar-track,.reference pre:hover::-webkit-scrollbar-track,.reference pre:focus-within::-webkit-scrollbar-track,.doc-table-wrap:hover::-webkit-scrollbar-track,.doc-table-wrap:focus-within::-webkit-scrollbar-track,.search-results-scroll:hover::-webkit-scrollbar-track,.search-results-scroll:focus-within::-webkit-scrollbar-track{background:var(--varde-scroll-track-active)}
.package-explorer:hover::-webkit-scrollbar-thumb,.package-explorer:focus-within::-webkit-scrollbar-thumb,.package-toc:hover::-webkit-scrollbar-thumb,.package-toc:focus-within::-webkit-scrollbar-thumb,.reference pre:hover::-webkit-scrollbar-thumb,.reference pre:focus-within::-webkit-scrollbar-thumb,.doc-table-wrap:hover::-webkit-scrollbar-thumb,.doc-table-wrap:focus-within::-webkit-scrollbar-thumb,.search-results-scroll:hover::-webkit-scrollbar-thumb,.search-results-scroll:focus-within::-webkit-scrollbar-thumb{border-color:var(--varde-scroll-track-active)}
.package-explorer::-webkit-scrollbar-thumb:hover,.package-toc::-webkit-scrollbar-thumb:hover,.reference pre::-webkit-scrollbar-thumb:hover,.doc-table-wrap::-webkit-scrollbar-thumb:hover,.search-results-scroll::-webkit-scrollbar-thumb:hover{background:color-mix(in srgb,var(--accent) 54%,var(--varde-scroll-surface))}
.package-explorer::-webkit-scrollbar-corner,.package-toc::-webkit-scrollbar-corner,.reference pre::-webkit-scrollbar-corner,.doc-table-wrap::-webkit-scrollbar-corner,.search-results-scroll::-webkit-scrollbar-corner{background:transparent}
`

// The reading track is deliberately flexible: when both sidebars are visible,
// it receives all remaining viewport width without compressing the existing
// declaration rhythm or navigation sizing.
SITE_REFERENCE_WIDTH_CSS :: `
main.reference-layout{grid-template-columns:minmax(175px,215px) minmax(0,1fr) minmax(170px,210px)!important;column-gap:clamp(20px,2vw,32px);padding-left:clamp(24px,3vw,56px);padding-right:clamp(24px,3vw,56px)}
@media(max-width:1120px){main.reference-layout{grid-template-columns:minmax(0,1fr) 210px!important;padding-left:clamp(24px,4vw,56px);padding-right:clamp(24px,4vw,56px)}}
`

SITE_JS :: `
(() => {
  const root=document.documentElement;
  const dialog=document.querySelector("#search-dialog"),open=document.querySelector("#site-search"),close=document.querySelector("#search-close"),input=document.querySelector("#search-input"),results=document.querySelector("#search-results"),summary=document.querySelector("#search-summary"),entries=Array.isArray(window.VARDE_SEARCH_INDEX)?window.VARDE_SEARCH_INDEX:[],siteRoot=root.dataset.siteRoot||"";
  let shown=[],selected=-1;
  const fuzzy=(query,value)=>{const q=query.toLocaleLowerCase(),text=value.toLocaleLowerCase(),direct=text.indexOf(q);if(direct>=0)return 2000-q.length*4-direct;let cursor=0,score=0,last=-2;for(const letter of q){const at=text.indexOf(letter,cursor);if(at<0)return -1;score+=18-at*.06;if(at===last+1)score+=14;if(at===0||" _-./:".includes(text[at-1]))score+=10;last=at;cursor=at+1;}return score-text.length*.015;};
	  const select=(index)=>{selected=index;const rows=results.querySelectorAll(".search-result");rows.forEach((row,i)=>row.dataset.selected=String(i===selected));if(selected>=0&&rows[selected]){rows[selected].scrollIntoView({block:"nearest"});input.setAttribute("aria-activedescendant",rows[selected].id);}else input.removeAttribute("aria-activedescendant");};
	  const formatDuration=elapsed=>(elapsed<10?elapsed.toFixed(1):String(Math.round(elapsed)))+" ms";
	  const render=()=>{const started=performance.now(),query=input.value.trim();results.replaceChildren();shown=[];selected=-1;if(!query){summary.textContent=entries.length.toLocaleString()+" indexed items. Search a name, path, or signature.";return;}shown=entries.map(item=>({item,score:fuzzy(query,item.search)})).filter(result=>result.score>=0).sort((a,b)=>b.score-a.score||a.item.label.localeCompare(b.item.label)).slice(0,32);shown.forEach(({item},index)=>{const row=document.createElement("a"),kind=document.createElement("span"),label=document.createElement("strong"),context=document.createElement("small");row.className="search-result";row.id="search-result-"+index;row.href=siteRoot+item.href;row.setAttribute("role","option");row.dataset.selected="false";label.textContent=item.label;kind.className="search-kind";kind.textContent=item.kind;context.textContent=item.context;row.append(label,kind,context);row.addEventListener("mouseenter",()=>select(index));results.append(row);});const elapsed=formatDuration(performance.now()-started);summary.textContent=shown.length?shown.length.toLocaleString()+" matches · "+elapsed:"No matches · "+elapsed;if(shown.length)select(0);};
  const showSearch=()=>{if(!dialog.open)dialog.showModal();render();requestAnimationFrame(()=>input.focus());};
  open?.addEventListener("click",showSearch);close?.addEventListener("click",()=>dialog.close());dialog?.addEventListener("click",event=>{if(event.target===dialog)dialog.close();});input?.addEventListener("input",render);input?.addEventListener("keydown",event=>{if(event.key==="ArrowDown"&&shown.length){event.preventDefault();select((selected+1)%shown.length);}else if(event.key==="ArrowUp"&&shown.length){event.preventDefault();select((selected-1+shown.length)%shown.length);}else if(event.key==="Enter"&&selected>=0){event.preventDefault();results.querySelectorAll(".search-result")[selected]?.click();}});
  document.addEventListener("click",event=>{if(location.protocol!=="file:"||event.defaultPrevented||event.button!==0||event.metaKey||event.ctrlKey||event.shiftKey||event.altKey)return;const link=event.target instanceof Element?event.target.closest("a[href]"):null;if(!link||link.target||link.hasAttribute("download"))return;const destination=new URL(link.getAttribute("href"),location.href);if(destination.protocol!=="file:"||!destination.pathname.endsWith("/"))return;event.preventDefault();destination.pathname+="index.html";location.href=destination.href;});
  document.addEventListener("keydown",event=>{const editable=event.target instanceof HTMLInputElement||event.target instanceof HTMLTextAreaElement||event.target?.isContentEditable;if((event.metaKey||event.ctrlKey)&&event.key.toLowerCase()==="k"){event.preventDefault();showSearch();}else if(event.key==="/"&&!editable&&!dialog?.open){event.preventDefault();showSearch();}else if(event.key==="Escape"&&dialog?.open)dialog.close();});
	const tocPanel=document.querySelector(".package-toc"),tocLinks=[...document.querySelectorAll(".toc-entry[data-toc-target]")],tocTargets=tocLinks.map(link=>({link,target:document.getElementById(link.dataset.tocTarget)})).filter(item=>item.target),tocGroups=[...document.querySelectorAll(".toc-group")];
	if(tocTargets.length){let scheduled=false,activeLink=null;const updateToc=()=>{scheduled=false;let active=tocTargets[0];for(const item of tocTargets){if(item.target.getBoundingClientRect().top<=132)active=item;else break;}tocTargets.forEach(item=>item.link.dataset.active=String(item===active));const activeGroup=active.link.closest(".toc-group");tocGroups.forEach(group=>{const isActive=group===activeGroup;group.dataset.active=String(isActive);const link=group.querySelector(".toc-group-link");if(link)link.dataset.active=String(isActive);});if(active.link!==activeLink&&tocPanel){const linkRect=active.link.getBoundingClientRect(),panelRect=tocPanel.getBoundingClientRect(),padding=14;if(linkRect.top<panelRect.top+padding)tocPanel.scrollTop+=linkRect.top-panelRect.top-padding;else if(linkRect.bottom>panelRect.bottom-padding)tocPanel.scrollTop+=linkRect.bottom-panelRect.bottom+padding;activeLink=active.link;}};const scheduleToc=()=>{if(!scheduled){scheduled=true;requestAnimationFrame(updateToc);}};addEventListener("scroll",scheduleToc,{passive:true});addEventListener("resize",scheduleToc);scheduleToc();}
})();
`

// Browser preferences deliberately live in localStorage rather than the
// generated site so people can tune a shared offline documentation bundle
// without changing project configuration or requiring a server.
SITE_SETTINGS_JS :: `
(() => {
  const root=document.documentElement,key="varde-settings",settings=document.querySelector("#site-settings"),dialog=document.querySelector("#settings-dialog"),close=document.querySelector("#settings-close"),form=document.querySelector("#settings-form"),reset=document.querySelector("#settings-reset");
  if(!form)return;
  const presets=["odin-light","monokai","github-light","tokyo-night"],darkThemes=new Set(["monokai","tokyo-night"]),normalizeTheme=value=>value==="light"?"odin-light":value==="dark"?"monokai":value,validPreset=value=>presets.includes(normalizeTheme(value)),validTheme=value=>value==="system"||validPreset(value),validMotion=value=>["system","full","reduced"].includes(value),validTab=value=>["2","4","8"].includes(String(value));
  const defaults={theme:normalizeTheme(root.dataset.defaultTheme)||"system",systemLightTheme:normalizeTheme(root.dataset.systemLightTheme)||"odin-light",systemDarkTheme:normalizeTheme(root.dataset.systemDarkTheme)||"monokai",motion:root.dataset.defaultMotion||"system",tabWidth:root.dataset.defaultTabWidth||"4",collapsePackages:root.dataset.defaultCollapsePackages!=="false"};
  const palette={"odin-light":["#f7f9ff","#14213d"],monokai:["#272822","#f8f8f2"],"github-light":["#ffffff","#1f2328"],"tokyo-night":["#1a1b26","#c0caf5"]};
  const fallbackKey="__varde_settings_v1__";
  const fallbackRead=()=>{try{const name=window.name||"";if(!name)return "";const bag=JSON.parse(name);return typeof bag[fallbackKey]==="string"?bag[fallbackKey]:"";}catch(_){return "";}};
  const fallbackWrite=raw=>{try{const name=window.name||"",bag=name?JSON.parse(name):{};bag[fallbackKey]=raw;window.name=JSON.stringify(bag);}catch(_){}};
  const fallbackClear=()=>{try{const name=window.name||"",bag=name?JSON.parse(name):{};delete bag[fallbackKey];window.name=JSON.stringify(bag);}catch(_){}};
  const read=()=>{let raw="";try{raw=localStorage.getItem(key)||"";}catch(_){}if(!raw)raw=fallbackRead();try{return {...defaults,...JSON.parse(raw||"{}")} ;}catch(_){return {...defaults};}};
  const save=value=>{const raw=JSON.stringify(value);try{localStorage.setItem(key,raw);}catch(_){}fallbackWrite(raw);};
  const apply=value=>{const state={theme:validTheme(value.theme)?normalizeTheme(value.theme):defaults.theme,systemLightTheme:validPreset(value.systemLightTheme)?normalizeTheme(value.systemLightTheme):defaults.systemLightTheme,systemDarkTheme:validPreset(value.systemDarkTheme)?normalizeTheme(value.systemDarkTheme):defaults.systemDarkTheme,motion:validMotion(value.motion)?value.motion:defaults.motion,tabWidth:validTab(value.tabWidth)?String(value.tabWidth):defaults.tabWidth,collapsePackages:typeof value.collapsePackages==="boolean"?value.collapsePackages:defaults.collapsePackages};const resolved=state.theme==="system"?(matchMedia("(prefers-color-scheme: dark)").matches?state.systemDarkTheme:state.systemLightTheme):state.theme,colors=palette[resolved]||palette["odin-light"];root.dataset.theme=resolved;root.dataset.motion=state.motion;root.style.colorScheme=darkThemes.has(resolved)?"dark":"light";root.style.backgroundColor=colors[0];root.style.color=colors[1];root.style.setProperty("--code-tab-width",state.tabWidth);document.querySelectorAll("details[data-package-branch]").forEach(branch=>branch.open=!state.collapsePackages);form.elements.theme.value=state.theme;form.elements.systemLightTheme.value=state.systemLightTheme;form.elements.systemDarkTheme.value=state.systemDarkTheme;form.elements.motion.value=state.motion;form.elements.tabWidth.value=state.tabWidth;form.elements.collapsePackages.checked=state.collapsePackages;return state;};
  let state=apply(read());
  settings?.addEventListener("click",()=>{if(!dialog.open)dialog.showModal();});close?.addEventListener("click",()=>dialog.close());dialog?.addEventListener("click",event=>{if(event.target===dialog)dialog.close();});
  form.addEventListener("change",()=>{state=apply({theme:form.elements.theme.value,systemLightTheme:form.elements.systemLightTheme.value,systemDarkTheme:form.elements.systemDarkTheme.value,motion:form.elements.motion.value,tabWidth:form.elements.tabWidth.value,collapsePackages:form.elements.collapsePackages.checked});save(state);});
  reset?.addEventListener("click",()=>{try{localStorage.removeItem(key);}catch(_){}fallbackClear();state=apply(defaults);});
  matchMedia("(prefers-color-scheme: dark)").addEventListener?.("change",()=>{if(state.theme==="system")state=apply(state);});
  document.addEventListener("keydown",event=>{const editable=event.target instanceof HTMLInputElement||event.target instanceof HTMLSelectElement||event.target?.isContentEditable;if(event.key===","&&!editable&&!dialog?.open){event.preventDefault();settings?.click();}else if(event.key==="Escape"&&dialog?.open)dialog.close();});
})();
`

search_index_entry_write :: proc(
	builder: ^strings.Builder,
	label, kind, entry_context, href, search: string,
	first: bool,
) -> bool {
	if !first do strings.write_string(builder, ",")
	strings.write_string(builder, "{label:")
	fmt.sbprintf(builder, "%q", label)
	strings.write_string(builder, ",kind:")
	fmt.sbprintf(builder, "%q", kind)
	strings.write_string(builder, ",context:")
	fmt.sbprintf(builder, "%q", entry_context)
	strings.write_string(builder, ",href:")
	fmt.sbprintf(builder, "%q", href)
	strings.write_string(builder, ",search:")
	fmt.sbprintf(builder, "%q", search)
	strings.write_string(builder, "}")
	return false
}

write_assets :: proc(model: ^Model, output_root: string, assets: Assets) -> string {
	css_path := path_join({output_root, "assets", "site.css"})
	js_path := path_join({output_root, "assets", "site.js"})
	css_builder: strings.Builder
	defer strings.builder_destroy(&css_builder)
	strings.write_string(&css_builder, SITE_CSS)
	strings.write_string(&css_builder, SITE_SCOPED_SCROLLBAR_CSS)
	strings.write_string(&css_builder, "/* Package declarations are grouped by their public kind, then alphabetized. The index repeats that structure so it supports both quick group jumps and precise symbol navigation. */\n.entry-group{margin:30px 0 0;scroll-margin-top:88px}.entry-group-heading{display:flex;align-items:baseline;justify-content:space-between;gap:16px;padding:0 0 9px;border-bottom:1px solid var(--line)}.entry-group-heading h2{margin:0;font-size:1.22rem;letter-spacing:-.02em}.entry-group-count{color:var(--muted);font-size:.78rem;font-weight:700;font-variant-numeric:tabular-nums}.entry-group .symbol:first-of-type{padding-top:17px}.toc-jumps{display:flex;flex-wrap:wrap;gap:4px;margin:8px 0 14px}.toc-jumps a{padding:3px 6px!important;border:1px solid var(--line);border-radius:999px;background:var(--surface-raised);font-size:.72rem;line-height:1.25}.toc-group{padding:8px 0 0;border-top:1px solid color-mix(in srgb,var(--line) 72%,transparent)}.toc-group-link{display:flex!important;align-items:baseline;justify-content:space-between;gap:8px;color:var(--text)!important;font-size:.77rem;font-weight:750}.toc-group-link span{color:var(--muted);font-size:.7rem;font-variant-numeric:tabular-nums}.toc-group-link[data-active=\"true\"]{color:var(--accent)!important}.toc-group[data-active=\"true\"]{border-color:color-mix(in srgb,var(--accent) 58%,var(--line))}.toc-entries{margin-top:3px}.toc-group .toc-entry{padding:2px 0 2px 9px}.toc-entry[data-active=\"true\"]{color:var(--accent);font-weight:700;border-left:2px solid var(--accent);margin-left:-19px;padding-left:26px}.toc-entry[data-active=\"true\"]:not(:focus-visible){background:color-mix(in srgb,var(--accent) 8%,transparent)}\n")
	strings.write_string(&css_builder, ".source-link{margin-left:auto;color:var(--muted);font-size:.78rem;font-weight:650;text-decoration:none}.source-link:hover{color:var(--accent);text-decoration:underline}.tok-keyword{color:#b23b7d;font-weight:650}.tok-literal{color:#9c5b16}.tok-operator{color:#62756a}.tok-comment{color:var(--muted);font-style:italic}.tok-directive{color:#6b56bb}.tok-invalid{color:#c43d3d;text-decoration:underline}.tok-link{color:#2776c4;text-decoration:none;font-weight:650}.tok-link:hover{text-decoration:underline}:root[data-theme=\"dark\"] .tok-keyword{color:#f08bb8}:root[data-theme=\"dark\"] .tok-literal{color:#f0ba6a}:root[data-theme=\"dark\"] .tok-operator{color:#b6c8ba}:root[data-theme=\"dark\"] .tok-directive{color:#c3b2ff}:root[data-theme=\"dark\"] .tok-link{color:#8ec5ff}\n")
	strings.write_string(&css_builder, ".reference-layout{width:100%;max-width:none!important;grid-template-columns:minmax(220px,1fr) minmax(0,960px) minmax(200px,1fr)!important;column-gap:clamp(28px,3vw,56px);align-items:start;padding:32px clamp(24px,4vw,72px) 96px}.reference-layout .reference{width:100%;max-width:960px;justify-self:center}.package-explorer{position:sticky;top:92px;justify-self:start;width:min(100%,260px);max-height:calc(100vh - 112px);overflow:auto;padding-right:16px;border-right:1px solid var(--line);font-size:.84rem;line-height:1.32}.package-toc{justify-self:end;width:min(100%,240px)}.explorer-title{margin:0 0 8px;font-weight:750;color:var(--text)}.package-tree,.package-tree ul{list-style:none;margin:0;padding:0}.package-tree ul{margin:2px 0 2px 7px;padding-left:12px;border-left:1px solid color-mix(in srgb,var(--line) 85%,transparent)}.package-tree li{margin:1px 0}.tree-package,.tree-folder{display:block;min-width:0;padding:5px 7px;border-radius:5px}.tree-package{color:var(--text);text-decoration:none}.tree-package:hover,.tree-package:focus-visible{background:var(--surface-raised);color:var(--accent);outline:0}.tree-package.is-active{background:color-mix(in srgb,var(--accent) 12%,var(--surface));color:var(--accent);font-weight:700}.tree-folder{color:var(--muted);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.79rem}.tree-name,.tree-meta{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tree-meta{margin-top:1px;color:var(--muted);font-size:.75rem;font-weight:400}.home-insights{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;margin:34px 0}.home-insights article{padding:16px 17px;background:var(--surface);border:1px solid var(--line);border-radius:8px}.home-insights h2{margin:2px 0 5px;font-size:1rem;letter-spacing:-.015em}.home-insights p:last-child{margin:0;color:var(--muted);font-size:.87rem;line-height:1.45}.home .package-tree{padding:8px;background:var(--surface);border:1px solid var(--line);border-radius:8px}.home .package-tree .tree-package{padding:8px 10px}.home .package-tree .tree-package:hover{background:var(--surface-raised)}.symbol h3 .kind{display:inline-block;vertical-align:middle;margin:0 0 0 9px;padding:2px 7px;border:1px solid var(--line);border-radius:999px;background:var(--surface-raised);font-size:.66rem;line-height:1.25;letter-spacing:.06em}.reference-layout+footer{max-width:none;padding-left:clamp(24px,4vw,72px);padding-right:clamp(24px,4vw,72px)}@media(max-width:1320px){.reference-layout{grid-template-columns:minmax(0,960px) 218px!important;justify-content:center}.package-explorer{display:none}}@media(max-width:980px){.reference-layout{display:block!important;max-width:980px!important}.package-toc{display:none}}@media(max-width:760px){.home-insights{grid-template-columns:1fr}.home-insights article{padding:14px}}@media(max-width:620px){.source-link{margin:5px 0 0;display:inline-block}.symbol h3 .kind{margin:5px 0 0;vertical-align:baseline}}\n")
	strings.write_string(&css_builder, "/* The reference canvas stays fluid: side rails occupy the edges while the documentation expands through the center. The homepage retains a focused reading width. */\nmain.home{width:100%;max-width:1080px;padding:52px clamp(24px,4vw,72px) 96px}.home .hero,.home .metrics{max-width:960px;margin-left:auto;margin-right:auto}.home .package-directory{width:100%;max-width:none}.reference-layout{grid-template-columns:minmax(190px,250px) minmax(0,1fr) minmax(190px,250px)!important;column-gap:clamp(24px,3vw,48px)}.reference-layout .reference{max-width:none}.package-explorer,.package-toc{display:block;width:100%}@media(max-width:1120px){.reference-layout{grid-template-columns:minmax(0,1fr) 218px!important;justify-content:center}.package-explorer{display:none}}\n")
	strings.write_string(&css_builder, "/* Search is a fixed reference tool: header and query controls stay in view while only results scroll. */\ndialog{width:min(820px,94vw);max-height:86vh;overflow:hidden}.search-dialog{display:grid;grid-template-rows:auto auto minmax(0,1fr) auto;max-height:min(760px,86vh);padding:0;overflow:hidden;background:var(--surface);border:1px solid var(--line);border-radius:14px;box-shadow:0 28px 80px color-mix(in srgb,#000 34%,transparent)}.search-dialog-header{padding:20px 24px 14px;border-bottom:1px solid var(--line);align-items:center}.search-dialog-header h2{font-size:1.35rem}.search-dialog-header button{border-color:transparent;background:transparent;color:var(--muted)}.search-dialog-header button:hover{color:var(--text);background:var(--surface-raised);border-color:var(--line)}.search-controls{padding:14px 24px 9px;border-bottom:1px solid var(--line)}.search-dialog input{margin:0;padding:12px 14px;border-radius:7px;background:var(--bg)}.search-summary{min-height:1.35em;margin:7px 1px 0;font-size:.8rem}.search-results-scroll{min-height:0;overflow-y:auto;overscroll-behavior:contain;padding:7px 10px 10px}.search-result{grid-template-columns:minmax(0,1fr) auto;column-gap:10px;align-items:center;padding:10px 12px;border-radius:7px}.search-result strong{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:.95rem}.search-kind{grid-column:2;grid-row:1;align-self:center;padding:2px 7px;border:1px solid var(--line);border-radius:999px;background:var(--surface-raised);color:var(--muted);font-size:.66rem;font-weight:750;letter-spacing:.055em;line-height:1.35;text-transform:uppercase}.search-result small{grid-column:1 / -1;margin-top:1px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.75rem;line-height:1.35}.search-hint{max-width:none;display:flex;gap:14px;margin:0;padding:11px 24px;border-top:1px solid var(--line);font-size:.76rem}.search-hint span{display:inline-flex;align-items:center;gap:3px}@media(max-width:620px){dialog{width:calc(100vw - 20px);max-height:calc(100vh - 20px)}.search-dialog{max-height:calc(100vh - 20px)}.search-dialog-header{padding:16px 18px 12px}.search-controls{padding:12px 18px 8px}.search-hint{gap:9px;padding:10px 18px;font-size:.71rem}.search-result{grid-template-columns:minmax(0,1fr) auto}.search-kind{display:block}.search-result small{grid-column:1 / -1}}\n")
	strings.write_string(&css_builder, "/* The homepage collapses package branches so large workspaces start at their collections (for example core, vendor, and base) instead of rendering every package at once. */\n.home .package-branch{margin:2px 0}.home .package-branch>summary{display:flex;align-items:stretch;list-style:none;cursor:pointer;border-radius:6px}.home .package-branch>summary::-webkit-details-marker{display:none}.home .package-branch>summary::before{content:\"›\";flex:none;align-self:center;width:20px;color:var(--muted);font-size:1.18rem;line-height:1;text-align:center;transition:transform .14s ease}.home .package-branch[open]>summary::before{transform:rotate(90deg)}.home .package-branch>summary .tree-package,.home .package-branch>summary .tree-folder{flex:1}.home .package-branch>summary:focus-visible{outline:3px solid color-mix(in srgb,var(--focus) 55%,transparent);outline-offset:2px}.home .package-branch>ul{margin-left:16px}.home .package-branch>summary:hover .tree-folder{color:var(--accent)}\n")
	strings.write_string(&css_builder, "/* Configurable reading preferences. Project defaults are emitted on <html>; a reader's optional settings are stored locally in the browser. */\n:root{--code-tab-width:4}pre,code{tab-size:var(--code-tab-width)}.settings-dialog{width:min(470px,94vw);padding:0;overflow:hidden;background:var(--surface);border:1px solid var(--line);border-radius:14px;box-shadow:0 28px 80px color-mix(in srgb,#000 34%,transparent)}.settings-dialog .search-dialog-header{padding:20px 24px 14px;border-bottom:1px solid var(--line)}.settings-form{display:grid;gap:14px;padding:20px 24px 24px}.settings-form label{display:grid;gap:6px;color:var(--muted);font-size:.86rem;font-weight:650}.settings-form select{width:100%;padding:9px 10px;border:1px solid var(--line);border-radius:7px;background:var(--bg);color:var(--text);font:inherit}.settings-form .settings-check{grid-template-columns:auto 1fr;align-items:center;gap:9px;color:var(--text);font-size:.9rem}.settings-form input[type=checkbox]{width:16px;height:16px;accent-color:var(--accent)}.settings-form button{justify-self:start;margin-top:3px}.site-header #site-settings{color:var(--muted)}@keyframes varde-page-in{from{opacity:0;transform:translateY(5px)}to{opacity:1;transform:none}}@keyframes varde-dialog-in{from{opacity:0;transform:translateY(10px) scale(.985)}to{opacity:1;transform:none}}@media(prefers-reduced-motion:no-preference){html[data-motion=system] main{animation:varde-page-in .28s ease-out both}html[data-motion=system] dialog[open] .search-dialog,html[data-motion=system] dialog[open] .settings-dialog{animation:varde-dialog-in .18s ease-out both}}html[data-motion=full] main{animation:varde-page-in .28s ease-out both}html[data-motion=full] dialog[open] .search-dialog,html[data-motion=full] dialog[open] .settings-dialog{animation:varde-dialog-in .18s ease-out both}@media(prefers-reduced-motion:reduce){html[data-motion=system] *,html[data-motion=reduced] *{animation-duration:.01ms!important;animation-iteration-count:1!important;scroll-behavior:auto!important;transition-duration:.01ms!important}}html[data-motion=reduced] *{animation-duration:.01ms!important;animation-iteration-count:1!important;scroll-behavior:auto!important;transition-duration:.01ms!important}@media(max-width:620px){.settings-dialog .search-dialog-header,.settings-form{padding-left:18px;padding-right:18px}}\n")
	// Full-page entrance animation makes every normal document link feel like a
	// transition. Keep motion scoped to ephemeral dialogs; navigation is direct.
	strings.write_string(&css_builder, "main{animation:none!important}\n")
	strings.write_string(&css_builder, "@media(max-width:620px){.site-header{padding:0 12px;gap:6px}.brand{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.site-header button{padding:7px 8px;font-size:.9rem}}\n")
	// The outer native dialog is the centering box. Match it to the visible panel
	// instead of centering a wide shell with a narrow, left-aligned child.
	strings.write_string(&css_builder, "#settings-dialog{width:min(470px,calc(100vw - 24px));max-width:calc(100vw - 24px);max-height:calc(100vh - 24px);margin:auto;padding:0;border:0;background:transparent;color:var(--text)}#settings-dialog .settings-dialog{width:100%;max-width:none}\n")
	strings.write_string(&css_builder, SITE_REFERENCE_WIDTH_CSS)
	strings.write_string(&css_builder, SITE_THEME_PRESETS_CSS)
	if err := write_text_file(css_path, &css_builder); len(err) > 0 do return err
	js_builder: strings.Builder
	defer strings.builder_destroy(&js_builder)
	strings.write_string(&js_builder, SITE_JS)
	strings.write_string(&js_builder, SITE_SETTINGS_JS)
	if err := write_text_file(js_path, &js_builder); len(err) > 0 do return err
	builder: strings.Builder
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, "window.VARDE_SEARCH_INDEX=[")
	first := true
	for pkg in model.packages {
		if !site_package_is_renderable(pkg) do continue
		package_path := package_url_path(pkg)
		package_context := pkg.relative_path
		first = search_index_entry_write(
			&builder,
			pkg.name,
			"Package",
			package_context,
			package_path,
			strings.concatenate({pkg.name, " ", package_context}, context.temp_allocator),
			first,
		)
		for file in pkg.files {
			file_display_name := source_path_display(model, file.name)
			file_context := strings.concatenate({package_context, " · ", file_display_name}, context.temp_allocator)
			first = search_index_entry_write(
				&builder,
				file_display_name,
				"File",
				file_context,
				package_path,
				strings.concatenate({file_display_name, " ", package_context}, context.temp_allocator),
				first,
			)
			for entry in file.entries {
				first = search_index_entry_write(
					&builder,
					entry.name,
					entry.kind,
					file_context,
					strings.concatenate({package_path, "#", entry.anchor}, context.temp_allocator),
					strings.concatenate({entry.name, " ", entry.signature, " ", file_context}, context.temp_allocator),
					first,
				)
			}
		}
	}
	strings.write_string(&builder, "];\n")
	index_path := path_join({output_root, "assets", "search-index.js"})
	if err := write_text_file(index_path, &builder); len(err) > 0 do return err
	if len(assets.brand_png) > 0 {
		if err := write_bytes_file(path_join({output_root, "assets", "brand-mark.png"}), assets.brand_png); len(err) > 0 do return err
	}
	return ""
}

write_manifest :: proc(output_root: string, config: Config, model: ^Model) -> string {
	render_stats := site_render_stats(model)
	builder: strings.Builder
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, "{\n  \"generator\": \"Varde\",\n  \"schema_version\": ")
	fmt.sbprintf(&builder, "%d", SITE_SCHEMA_VERSION)
	strings.write_string(&builder, ",\n  \"title\": ")
	fmt.sbprintf(&builder, "%q", config.title)
	strings.write_string(&builder, ",\n  \"packages\": ")
	fmt.sbprintf(&builder, "%d", render_stats.package_count)
	strings.write_string(&builder, ",\n  \"symbols\": ")
	fmt.sbprintf(&builder, "%d", render_stats.entry_count)
	strings.write_string(&builder, ",\n  \"source_links\": ")
	if config.include_source_links {
		strings.write_string(&builder, "true")
	} else {
		strings.write_string(&builder, "false")
	}
	strings.write_string(&builder, "\n}\n")
	return write_text_file(path_join({output_root, SITE_MANIFEST_FILE_NAME}), &builder)
}

build_canceled :: proc(cancel_requested: ^int) -> bool {
	return cancel_requested != nil && sync.atomic_load(cancel_requested) != 0
}

build :: proc(model: ^Model, config: Config, assets: Assets, cancel_requested: ^int = nil) -> Build_Result {
	result := Build_Result{}
	if config_err := source_links_validate(config); len(config_err) > 0 { result.error_message = config_err; return result }
	output_root, resolve_err := output_path_resolve(model.workspace_path, config.output_dir)
	if len(resolve_err) > 0 { result.error_message = resolve_err; return result }
	// A staging directory makes failed writes recoverable. Existing generated output
	// is replaced only after the marker check succeeds.
	staging := strings.concatenate({output_root, ".staging"}, context.temp_allocator)
	if os.exists(staging) { _ = os.remove_all(staging) }
	if os.exists(output_root) {
		marker := path_join({output_root, SITE_MANIFEST_FILE_NAME})
		legacy_marker := path_join({output_root, SITE_LEGACY_MANIFEST_FILE_NAME})
		if !os.exists(marker) && !os.exists(legacy_marker) { result.error_message = "Output directory is non-empty and not marked as Varde output"; return result }
	}
	if err := os.make_directory_all(staging); err != nil { result.error_message = "Could not create export staging directory"; return result }
	defer if os.exists(staging) do _ = os.remove_all(staging)
	if build_canceled(cancel_requested) { result.error_message = "Build canceled"; return result }
	indexes := site_render_indexes_build(model)
	defer site_render_indexes_destroy(&indexes)
	extensions, extension_err := site_extensions_load(model.workspace_path, config)
	defer site_extensions_destroy(&extensions)
	if len(extension_err) > 0 { result.error_message = extension_err; return result }
	if err := write_assets(model, staging, assets); len(err) > 0 { result.error_message = err; return result }
	if err := write_overrides_css(staging, output_root); len(err) > 0 { result.error_message = err; return result }
	if build_canceled(cancel_requested) { result.error_message = "Build canceled"; return result }
	index_config := config
	if !config.include_brand_artwork || len(assets.brand_png) == 0 { index_config.include_brand_artwork = false }
	if err := write_index_page(model, index_config, extensions, staging); len(err) > 0 { result.error_message = err; return result }
	for &pkg in model.packages {
		if build_canceled(cancel_requested) { result.error_message = "Build canceled"; return result }
		if !site_package_is_renderable(pkg) do continue
		if err := write_package_page(model, &indexes, &pkg, config, extensions, staging); len(err) > 0 { result.error_message = err; return result }
	}
	if err := write_manifest(staging, config, model); len(err) > 0 { result.error_message = err; return result }
	if build_canceled(cancel_requested) { result.error_message = "Build canceled"; return result }
	if os.exists(output_root) { if err := os.remove_all(output_root); err != nil { result.error_message = "Could not replace prior Varde site output"; return result } }
	if err := os.rename(staging, output_root); err != nil { result.error_message = "Could not finalize generated site"; return result }
	render_stats := site_render_stats(model)
	result.ok = true
	result.output_path = output_root
	result.package_count = render_stats.package_count
	result.entry_count = render_stats.entry_count
	return result
}

@(test)
test_output_path_rejects_escape :: proc(t: ^testing.T) {
	_, err := output_path_resolve("/project", "../outside")
	testing.expect(t, len(err) > 0, "relative path escapes should be rejected")
}

@(test)
test_source_links_are_opt_in_and_https_only :: proc(t: ^testing.T) {
	config := config_default("/workspace", "", "")
	testing.expect(t, config.schema_version == SITE_SCHEMA_VERSION && config.title == "workspace Documentation" && !config.include_source_links && config.theme == "system" && config.system_light_theme == THEME_ODIN_LIGHT && config.system_dark_theme == THEME_MONOKAI && config.motion == "system" && config.code_tab_width == 4 && config.collapse_package_tree, "new site configs should provide project-specific titles and readable presentation defaults")
	testing.expect(t, site_theme_valid(THEME_ODIN_LIGHT) && site_theme_valid(THEME_MONOKAI) && site_theme_valid(THEME_GITHUB_LIGHT) && site_theme_valid(THEME_TOKYO_NIGHT) && site_theme_is_dark(THEME_MONOKAI) && site_theme_is_dark(THEME_TOKYO_NIGHT), "the four supported presets should classify their colour mode")
	relative_config := config_default(".", "", "")
	testing.expect(t, relative_config.title != ". Documentation", "relative workspace roots should resolve to their project directory name")
	config.include_source_links = true
	testing.expect(t, len(source_links_validate(config)) > 0, "enabled source links should require a repository prefix")
	config.source_url_prefix = "http://example.test/repo"
	testing.expect(t, len(source_links_validate(config)) > 0, "source links should require HTTPS")
	config.source_url_prefix = "https://example.test/repo/blob/main/"
	testing.expect(t, len(source_links_validate(config)) == 0, "HTTPS source prefixes should be accepted")
	model := Model{workspace_path = "/workspace"}
	href, ok := source_href(config, &model, Entry{source_path = "/workspace/src/main.odin", source_line = 42})
	testing.expect(t, ok && href == "https://example.test/repo/blob/main/src/main.odin#L42", "source hrefs should use workspace-relative paths and line anchors")
	escaped_href, escaped_ok := source_href(config, &model, Entry{source_path = "/workspace/src/a file.odin"})
	testing.expect(t, escaped_ok && strings.contains(escaped_href, "a%20file.odin"), "source href paths should be URL encoded")
	config.source_url_prefix = "https://github.com/Skytrias/vigil/tree/main"
	github_href, github_ok := source_href(config, &model, Entry{source_path = "/workspace/src/main.odin", source_line = 3})
	testing.expect(t, github_ok && github_href == "https://github.com/Skytrias/vigil/blob/main/src/main.odin#L3", "GitHub tree prefixes should normalize to line-addressable blob URLs")
}

@(test)
test_search_paths_are_workspace_relative :: proc(t: ^testing.T) {
	model := Model{workspace_path = "/workspace"}
	inside := source_path_display(&model, "/workspace/shared/mvg/model/file.odin")
	testing.expect(t, inside == "shared/mvg/model/file.odin", "search should display source paths relative to the workspace")
	relative := source_path_display(&model, "shared/mvg/model/file.odin")
	testing.expect(t, relative == "shared/mvg/model/file.odin", "search should preserve already-relative source paths")
	outside := source_path_display(&model, "/other/project/file.odin")
	testing.expect(t, outside == "/other/project/file.odin", "search should not misrepresent source paths outside the workspace")
	workspace_root, root_err := filepath.abs(".", context.temp_allocator)
	relative_root_model := Model{workspace_path = "."}
	inside_relative_root := source_path_display(&relative_root_model, path_join({workspace_root, "src", "main.odin"}))
	testing.expect(t, root_err == nil && inside_relative_root == "src/main.odin", "relative workspace roots should not leak absolute source paths")
}

@(test)
test_html_escape_handles_hostile_text :: proc(t: ^testing.T) {
	builder: strings.Builder
	defer strings.builder_destroy(&builder)
	html_text(&builder, "<script>&\"")
	testing.expect(t, strings.to_string(builder) == "&lt;script&gt;&amp;&quot;", "HTML text should be escaped")
}

@(test)
test_grouped_counts_are_readable_at_reference_scale :: proc(t: ^testing.T) {
	builder: strings.Builder
	defer strings.builder_destroy(&builder)
	write_grouped_count(&builder, 3864)
	testing.expect(t, strings.to_string(builder) == "3,864", "large reference counts should use grouped digits")
}

@(test)
test_search_dialog_keeps_controls_outside_result_scroller :: proc(t: ^testing.T) {
	builder: strings.Builder
	defer strings.builder_destroy(&builder)
	site_footer(&builder, "assets/", {})
	rendered := strings.to_string(builder)
	testing.expect(t, strings.contains(rendered, "class=\"search-results-scroll\""), "search results should have their own scroll container")
	testing.expect(t, strings.contains(SITE_JS, "performance.now()"), "search status should report measured search time")
	testing.expect(t, strings.contains(SITE_JS, "row.append(label,kind,context)"), "search result kind tags should follow the declaration name")
	testing.expect(t, strings.contains(SITE_JS, "destination.pathname+=\"index.html\""), "offline directory routes should resolve to their concrete entry documents")
	testing.expect(t, strings.contains(SITE_JS, "tocGroups") && strings.contains(SITE_JS, "toc-group-link"), "the scroll spy should expose the active declaration group as well as the active symbol")
	testing.expect(t, strings.contains(SITE_SCOPED_SCROLLBAR_CSS, ".package-explorer") && strings.contains(SITE_SCOPED_SCROLLBAR_CSS, ".reference pre") && strings.contains(SITE_SCOPED_SCROLLBAR_CSS, "scrollbar-color"), "nested reference regions should receive theme-aware scrollbar rules")
	testing.expect(t, strings.contains(SITE_SCOPED_SCROLLBAR_CSS, "scrollbar-color:var(--varde-scroll-thumb) transparent") && strings.contains(SITE_SCOPED_SCROLLBAR_CSS, ":hover::-webkit-scrollbar-track"), "nested scrollbar tracks should stay transparent until their region is active")
	testing.expect(t, !strings.contains(SITE_SCOPED_SCROLLBAR_CSS, "body::-webkit-scrollbar") && !strings.contains(SITE_SCOPED_SCROLLBAR_CSS, "html::-webkit-scrollbar"), "the document scrollbar should remain browser-native")
	testing.expect(t, strings.contains(SITE_REFERENCE_WIDTH_CSS, "minmax(0,1fr)") && strings.contains(SITE_REFERENCE_WIDTH_CSS, "minmax(175px,215px)") && !strings.contains(SITE_REFERENCE_WIDTH_CSS, ".symbol{"), "reference pages should give all remaining width to documentation without changing its vertical rhythm")
}

@(test)
test_config_reads_legacy_vigil_site_and_writes_varde_config :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "varde-config-migration-*", context.temp_allocator)
	testing.expect(t, err == nil, "temporary configuration root should be created")
	defer _ = os.remove_all(root)
	legacy_path := path_join({root, SITE_LEGACY_CONFIG_FILE_NAME})
	legacy_config := `{"schema_version":2,"title":"Migrated","description":"A project","output_dir":"dist/docs","include_brand_artwork":false,"include_source_links":true,"source_url_prefix":"https://example.test/demo/blob/revision","theme":"dark"}`
	write_err := os.write_entire_file(legacy_path, legacy_config)
	testing.expect(t, write_err == nil, "legacy site configuration should be writable")
	config, load_err := config_load(root, "", "")
	defer config_destroy(&config)
	testing.expect(t, len(load_err) == 0 && config.title == "Migrated" && config.output_dir == "dist/docs" && config.include_source_links && config.source_url_prefix == "https://example.test/demo/blob/revision" && config.theme == THEME_MONOKAI && config.system_light_theme == THEME_ODIN_LIGHT && config.system_dark_theme == THEME_MONOKAI, "legacy Vigil configuration should remain usable, preserve source-link settings, and receive theme defaults")
	testing.expect(t, config.schema_version == SITE_SCHEMA_VERSION, "loaded configurations should migrate to Varde's schema")
	save_err := config_save(root, config)
	testing.expect(t, len(save_err) == 0 && os.exists(path_join({root, SITE_CONFIG_FILE_NAME})), "saving a migrated config should create varde.json")
}

@(test)
test_markup_supports_reference_comment_blocks_and_inline_links :: proc(t: ^testing.T) {
	blocks := markup_blocks_parse("# Heading\n\nA **bold** [link](https://example.test).\n\n- item\n\n| name | value |\n| --- | --- |\n| a | b |\n\nExample:\n\tvalue := 1\n\nOutput:\n\t1")
	defer markup_blocks_destroy(&blocks)
	testing.expect(t, len(blocks) == 6, "Varde markup should preserve headings, paragraphs, lists, tables, examples, and outputs")
	testing.expect(t, blocks[0].kind == .Heading && blocks[3].kind == .Table && blocks[4].kind == .Example && blocks[5].kind == .Output, "reference markup blocks should retain their semantic kinds")
	inline_segments := markup_inline_parse("A **bold** [link](https://example.test)")
	defer markup_inline_destroy(&inline_segments)
	testing.expect(t, len(inline_segments) == 4 && inline_segments[1].kind == .Bold && inline_segments[3].kind == .Link, "inline markup should expose emphasis and explicit links")
}

@(test)
test_package_tree_preserves_workspace_nesting :: proc(t: ^testing.T) {
	model := Model{workspace_path = "/workspace"}
	model.packages = make([dynamic]Package, 0, 3)
	defer {
		for &pkg in model.packages {
			for &file in pkg.files do delete(file.entries)
			delete(pkg.files)
		}
		delete(model.packages)
	}
	pairs := [3][2]string{[2]string{"src", "src"}, [2]string{"feature", "src/feature"}, [2]string{"ui", "shared/ui"}}
	for pair in pairs {
		pkg := Package{name = pair[0], relative_path = pair[1], files = make([dynamic]File, 0, 1)}
		file := File{entries = make([dynamic]Entry, 0, 1)}
		append(&file.entries, Entry{name = pair[0]})
		append(&pkg.files, file)
		append(&model.packages, pkg)
	}
	builder: strings.Builder
	defer strings.builder_destroy(&builder)
	write_package_tree(&builder, &model, "/out/index.html", "/out", "src/feature", true, false)
	rendered := strings.to_string(builder)
	src_index := strings.index(rendered, ">src<")
	feature_index := strings.index(rendered, ">feature<")
	testing.expect(t, strings.contains(rendered, "class=\"package-tree\""), "package directories should render as a semantic tree")
	testing.expect(t, src_index > 0 && feature_index > src_index && strings.contains(rendered[src_index:feature_index], "</a><ul>"), "nested package branches should remain beneath their parent branch")
	testing.expect(t, strings.contains(rendered, "is-active") && strings.contains(rendered, "aria-current=\"page\""), "the current package should be identifiable in the explorer")
	collapsed_builder: strings.Builder
	defer strings.builder_destroy(&collapsed_builder)
	write_package_tree(&collapsed_builder, &model, "/out/index.html", "/out", "", true, true)
	collapsed := strings.to_string(collapsed_builder)
	testing.expect(t, strings.contains(collapsed, "<details class=\"package-branch\" data-package-branch><summary>") && strings.contains(collapsed, "</summary><ul>"), "homepage package branches should be expandable instead of eagerly rendering every descendant")
}

@(test)
test_workspace_collection_imports_resolve_for_links :: proc(t: ^testing.T) {
	model := Model{workspace_path = "/workspace"}
	model.packages = make([dynamic]Package, 0, 2)
	defer {
		for &pkg in model.packages {
			for &file in pkg.files do delete(file.entries)
			delete(pkg.files)
		}
		delete(model.packages)
	}
	triples := [2][3]string{[3]string{"app", "/workspace/src", "src"}, [3]string{"ui", "/workspace/shared/corbel/ui", "shared/corbel/ui"}}
	for triple in triples {
		pkg := Package{name = triple[0], path = triple[1], relative_path = triple[2], files = make([dynamic]File, 0, 1)}
		file := File{entries = make([dynamic]Entry, 0, 1)}
		append(&file.entries, Entry{name = triple[0]})
		append(&pkg.files, file)
		append(&model.packages, pkg)
	}
	target := site_package_for_import(nil, &model, &model.packages[0], "shared:corbel/ui")
	testing.expect(t, target != nil && target.relative_path == "shared/corbel/ui", "collection-qualified imports should resolve to their workspace package")
}

@(test)
test_internal_links_resolve_only_local_or_imported_targets :: proc(t: ^testing.T) {
	model := Model{workspace_path = "/workspace"}
	model.packages = make([dynamic]Package, 0, 2)
	defer {
		for &pkg in model.packages {
			for &file in pkg.files {
				delete(file.imports)
				delete(file.entries)
			}
			delete(pkg.files)
		}
		delete(model.packages)
	}
	local := Package{name = "local", relative_path = "src/local", files = make([dynamic]File, 0, 1)}
	local_file := File{name = "local.odin", imports = make([dynamic]Import, 0, 1), entries = make([dynamic]Entry, 0, 1)}
	append(&local_file.imports, Import{alias = "ui", path = "shared:ui"})
	append(&local_file.entries, Entry{name = "Local", anchor = "local"})
	append(&local.files, local_file)
	append(&model.packages, local)
	imported := Package{name = "ui", relative_path = "ui", files = make([dynamic]File, 0, 1)}
	imported_file := File{name = "element.odin", entries = make([dynamic]Entry, 0, 1)}
	append(&imported_file.entries, Entry{name = "Element", anchor = "element"})
	append(&imported.files, imported_file)
	append(&model.packages, imported)

	ctx := Doc_Render_Context{
		model = &model,
		output_root = "/out",
		page_path = "/out/packages/src/local/index.html",
		pkg = &model.packages[0],
		file = &model.packages[0].files[0],
	}
	local_href, local_ok := site_internal_href(ctx, "Local")
	testing.expect(t, local_ok && local_href == "#local", "unique same-package symbols should resolve locally")
	import_href, import_ok := site_internal_href(ctx, "ui.Element")
	testing.expect(t, import_ok && import_href == "../../ui/#element", "declared imported symbols should resolve to canonical package directories")
	_, unknown_ok := site_internal_href(ctx, "not-a-target")
	testing.expect(t, !unknown_ok, "unresolved references should remain readable rather than inventing a URL")
	code: strings.Builder
	defer strings.builder_destroy(&code)
	write_odin_code(&code, "proc(value: ui.Element) -> Local #packed", ctx)
	rendered := strings.to_string(code)
	testing.expect(t, strings.contains(rendered, "class=\"tok-keyword\">proc"), "Odin keywords should receive syntax classes")
	testing.expect(t, strings.contains(rendered, "../../ui/#element"), "qualified imported identifiers should link in highlighted code")
	testing.expect(t, strings.contains(rendered, "href=\"#local\""), "local identifiers should link in highlighted code")
	testing.expect(t, strings.contains(rendered, "class=\"tok-directive\">#</span><span class=\"tok-directive\">packed"), "Odin directives should retain a single directive color")
}

@(test)
test_build_emits_directly_openable_site :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "vigil-site-export-*", context.temp_allocator)
	testing.expect(t, err == nil, "temporary output root should be created")
	defer _ = os.remove_all(root)
	model := Model{workspace_path = root, stats = {package_count = 1, file_count = 1, entry_count = 6, sloc = 12}}
	model.packages = make([dynamic]Package, 0, 1)
	pkg := Package{name = "core:demo", relative_path = "core/demo", summary = "A <useful> package."}
	pkg.files = make([dynamic]File, 0, 1)
	file := File{name = path_join({root, "demo.odin"})}
	file.entries = make([dynamic]Entry, 0, 6)
	append(&file.entries, Entry{name = "hello", anchor = "hello", kind = "Procedures", signature = "hello :: proc()", docs = "Says hello.\n\n| name | meaning |\n| --- | --- |\n| hello | world |", source_path = path_join({root, "demo.odin"}), source_line = 7})
	append(&file.entries, Entry{name = "Zebra", anchor = "Zebra", kind = "Types", signature = "Zebra :: struct {}"})
	append(&file.entries, Entry{name = "Alpha", anchor = "Alpha", kind = "Types", signature = "Alpha :: enum {}"})
	append(&file.entries, Entry{name = "beta", anchor = "beta", kind = "Constants", signature = "beta :: 2"})
	append(&file.entries, Entry{name = "state", anchor = "state", kind = "Variables", signature = "state: int"})
	append(&file.entries, Entry{name = "Handlers", anchor = "Handlers", kind = "Procedure Groups", signature = "Handlers :: proc{}"})
	append(&pkg.files, file)
	append(&model.packages, pkg)
	defer {
		delete(model.packages[0].files[0].entries)
		delete(model.packages[0].files)
		delete(model.packages)
	}
	config := config_default(root, "Demo", "A safe static site.")
	config.include_source_links = true
	config.source_url_prefix = "https://example.test/demo/blob/main"
	config.theme = THEME_MONOKAI
	config.motion = "reduced"
	config.code_tab_width = 2
	config.head_html = "docs/head.html"
	config.before_content_html = "docs/before.html"
	config.after_content_html = "docs/after.html"
	testing.expect(t, len(ensure_directory(path_join({root, "docs"}))) == 0, "extension fixture directory should be creatable")
	testing.expect(t, os.write_entire_file(path_join({root, config.head_html}), "<meta name=\"demo-extension\" content=\"head\">") == nil, "head extension fixture should be writable")
	testing.expect(t, os.write_entire_file(path_join({root, config.before_content_html}), "<aside id=\"before-content\">Before</aside>") == nil, "before-content extension fixture should be writable")
	testing.expect(t, os.write_entire_file(path_join({root, config.after_content_html}), "<aside id=\"after-content\">After</aside>") == nil, "after-content extension fixture should be writable")
	result := build(&model, config, {})
	testing.expect(t, result.ok, result.error_message)
	site_root := path_join({root, config.output_dir})
	index := path_join({site_root, "index.html"})
	package_page := path_join({site_root, "packages", "core", "demo", "index.html"})
	search_index := path_join({site_root, "assets", "search-index.js"})
	overrides_path := path_join({site_root, "assets", SITE_OVERRIDES_CSS_FILE_NAME})
	testing.expect(t, os.exists(index), "site index should be generated")
	index_data, index_read_err := os.read_entire_file(index, context.temp_allocator)
	testing.expect(t, index_read_err == nil && !strings.contains(string(index_data), "home-insights"), "the homepage should prioritize the package directory over promotional cards")
	testing.expect(t, index_read_err == nil && strings.contains(string(index_data), "search-results-scroll"), "the generated dialog should isolate result scrolling")
	testing.expect(t, index_read_err == nil && strings.contains(string(index_data), ">Demo</a><button id=\"site-search\" class=\"search-trigger\"") && strings.contains(string(index_data), "search-trigger-icon") && !strings.contains(string(index_data), "id=\"theme-toggle\""), "the header should use the configured project title with the search trigger as its primary action")
	testing.expect(t, index_read_err == nil && !strings.contains(string(index_data), "Varde Docs"), "generated headers should not hard-code the Varde product name")
	testing.expect(t, index_read_err == nil && strings.contains(string(index_data), "data-default-theme=\"monokai\"") && strings.contains(string(index_data), "data-theme=\"monokai\"") && strings.contains(string(index_data), "data-system-light-theme=\"odin-light\"") && strings.contains(string(index_data), "data-system-dark-theme=\"monokai\"") && strings.contains(string(index_data), "data-default-tab-width=\"2\""), "project presentation defaults should reach every generated page")
	testing.expect(t, index_read_err == nil && strings.contains(string(index_data), "<meta name=\"color-scheme\" content=\"dark\">") && strings.contains(string(index_data), "<meta name=\"color-scheme\"") && strings.index(string(index_data), "<meta name=\"color-scheme\"") < strings.index(string(index_data), "assets/site.css"), "fixed project themes should declare their preferred color scheme before stylesheets load")
	light_config := config
	light_config.theme = THEME_ODIN_LIGHT
	light_head: strings.Builder
	defer strings.builder_destroy(&light_head)
	site_head(&light_head, "Light", "Demo", "assets/", "", light_config, {})
	light_markup := strings.to_string(light_head)
	testing.expect(t, strings.contains(light_markup, "data-theme=\"odin-light\"") && strings.contains(light_markup, "<meta name=\"color-scheme\" content=\"light\">") && strings.index(light_markup, "<meta name=\"color-scheme\"") < strings.index(light_markup, "assets/site.css"), "a fixed light theme must establish the light browser canvas before a dark system preference can paint")
	bootstrap_index := strings.index(string(index_data), "varde-settings")
	stylesheet_index := strings.index(string(index_data), "assets/site.css")
	testing.expect(t, index_read_err == nil && bootstrap_index >= 0 && bootstrap_index < stylesheet_index, "saved reader preferences should be applied before the first stylesheet can paint")
	testing.expect(t, strings.contains(SITE_THEME_BOOTSTRAP_JS, "r.style.colorScheme") && strings.contains(SITE_THEME_BOOTSTRAP_JS, "r.style.backgroundColor"), "the pre-stylesheet bootstrap should align the browser canvas with the resolved reader theme")
	testing.expect(t, index_read_err == nil && strings.contains(string(index_data), "id=\"settings-dialog\"") && strings.contains(string(index_data), "id=\"site-settings\"") && strings.contains(string(index_data), "name=\"systemLightTheme\"") && strings.contains(string(index_data), "name=\"systemDarkTheme\""), "generated sites should expose persistent reader settings and system theme variants")
	testing.expect(t, index_read_err == nil && strings.contains(string(index_data), "demo-extension") && strings.contains(string(index_data), "before-content") && strings.contains(string(index_data), "after-content"), "configured trusted HTML insertion points should be emitted")
	testing.expect(t, os.exists(package_page), "package page should be generated")
	overrides_data, overrides_read_err := os.read_entire_file(overrides_path, context.temp_allocator)
	testing.expect(t, overrides_read_err == nil && strings.contains(string(overrides_data), "Varde loads this stylesheet after assets/site.css"), "a documented stylesheet override file should be generated")
	data, read_err := os.read_entire_file(search_index, context.temp_allocator)
	testing.expect(t, read_err == nil && strings.contains(string(data), "hello"), "offline search index should include symbols")
	testing.expect(t, read_err == nil && strings.contains(string(data), "packages/core/demo/#hello") && !strings.contains(string(data), "index.html#"), "search links should use canonical package-directory URLs")
	testing.expect(t, read_err == nil && strings.contains(string(data), "kind"), "offline search index should label result kinds")
	testing.expect(t, read_err == nil && !strings.contains(string(data), "%!(MISSING"), "search index should be valid JavaScript object syntax")
	page_data, page_read_err := os.read_entire_file(package_page, context.temp_allocator)
	testing.expect(t, page_read_err == nil && strings.contains(string(page_data), "data-site-root=\"../../../\""), "package documents should provide a root-relative search base")
	testing.expect(t, page_read_err == nil && strings.contains(string(page_data), "../../../assets/overrides.css"), "every page should load the optional override stylesheet after base styles")
	testing.expect(t, page_read_err == nil && strings.contains(string(page_data), "class=\"package-toc\""), "package pages should include a compact on-page index")
	testing.expect(t, page_read_err == nil && strings.contains(string(page_data), "id=\"group-types\"") && strings.contains(string(page_data), "id=\"group-procedure-groups\""), "package pages should group declarations by kind")
	testing.expect(t, page_read_err == nil && strings.contains(string(page_data), "class=\"toc-group\" data-toc-group=\"group-types\"") && strings.contains(string(page_data), "class=\"toc-jumps\""), "the on-page index should offer grouped quick jumps")
	alpha_index := strings.index(string(page_data), "id=\"Alpha\"")
	zebra_index := strings.index(string(page_data), "id=\"Zebra\"")
	constants_index := strings.index(string(page_data), "id=\"group-constants\"")
	testing.expect(t, page_read_err == nil && alpha_index >= 0 && zebra_index > alpha_index && constants_index > zebra_index, "each declaration group should be alphabetized and keep the package kind order")
	testing.expect(t, page_read_err == nil && !strings.contains(string(page_data), root), "package pages should not expose absolute workspace paths")
	testing.expect(t, page_read_err == nil && strings.contains(string(page_data), "<table class=\"doc-table\">"), "documentation tables should render as semantic HTML tables")
	testing.expect(t, page_read_err == nil && strings.contains(string(page_data), "class=\"symbol-heading\""), "package pages should use compact declaration headings")
	testing.expect(t, page_read_err == nil && strings.contains(string(page_data), "https://example.test/demo/blob/main/demo.odin#L7"), "enabled source links should point to repository files and lines")
	manifest_path := path_join({site_root, SITE_MANIFEST_FILE_NAME})
	manifest_data, manifest_read_err := os.read_entire_file(manifest_path, context.temp_allocator)
	testing.expect(t, manifest_read_err == nil && strings.contains(string(manifest_data), "\"source_links\": true"), "manifest should report when source links were emitted")
	custom_overrides: strings.Builder
	strings.write_string(&custom_overrides, ":root{--accent:#ff00aa}")
	custom_write_err := write_text_file(overrides_path, &custom_overrides)
	strings.builder_destroy(&custom_overrides)
	testing.expect(t, len(custom_write_err) == 0, "test should be able to customize the override stylesheet")
	second_result := build(&model, config, {})
	testing.expect(t, second_result.ok, "a second build should preserve user overrides")
	preserved_overrides, preserved_read_err := os.read_entire_file(overrides_path, context.temp_allocator)
	testing.expect(t, preserved_read_err == nil && strings.contains(string(preserved_overrides), "--accent:#ff00aa"), "site builds should preserve an existing override stylesheet")
	if read_err == nil do delete(data, context.temp_allocator)
	if index_read_err == nil do delete(index_data, context.temp_allocator)
	if overrides_read_err == nil do delete(overrides_data, context.temp_allocator)
	if page_read_err == nil do delete(page_data, context.temp_allocator)
	if manifest_read_err == nil do delete(manifest_data, context.temp_allocator)
	if preserved_read_err == nil do delete(preserved_overrides, context.temp_allocator)
}
