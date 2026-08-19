ODIN_BIN ?= odin
DOC ?=
ODIN_BUILD_FLAGS ?= -o:speed
PREVIEW_OUT ?= .varde-preview/site
PREVIEW_PORT ?= 1314
PREVIEW_BIND ?= 127.0.0.1
PREVIEW_PYTHON ?= python3
PREVIEW_WATCH_INTERVAL ?= 0.75
SHOWCASE_PREVIEW_OUT ?=

.PHONY: test inspect scan extract-source build-cli build-inspector build-doc preview-build preview preview-watch showcase-preview sample-odin-stdlib

test:
	$(ODIN_BIN) test runtime
	$(ODIN_BIN) test doc_format
	$(ODIN_BIN) test extractor

build-cli:
	mkdir -p dist
	$(ODIN_BIN) build cli $(ODIN_BUILD_FLAGS) -out:dist/varde

build-inspector: build-cli

inspect: build-cli
	@test -n "$(DOC)" || (echo "Usage: make inspect DOC=path/to/file.odin-doc"; exit 2)
	./dist/varde inspect "$(DOC)"

scan: build-cli
	./dist/varde scan --source "$(or $(SOURCE),.)"

extract-source: build-cli
	@test -n "$(DOC)" || (echo "Usage: make extract-source SOURCE=. DOC=build/project.odin-doc"; exit 2)
	./dist/varde extract --source "$(or $(SOURCE),.)" --out "$(DOC)" --allow-incomplete

build-doc: build-cli
	@test -n "$(DOC)" || (echo "Usage: make build-doc DOC=path/to/file.odin-doc [WORKSPACE=. OUT=dist/varde]"; exit 2)
	./dist/varde build --doc "$(DOC)" --workspace "$(or $(WORKSPACE),.)" --out "$(or $(OUT),dist/varde)"

# Developer-only local preview. The generated output is ignored by Git.
# Python is a temporary development convenience until Odin has suitable HTTP
# support for a native `varde serve` command.
preview-build: build-cli
	./dist/varde build --source "$(or $(SOURCE),.)" --allow-incomplete --out "$(PREVIEW_OUT)"

preview: preview-build
	$(PREVIEW_PYTHON) -m http.server "$(PREVIEW_PORT)" --bind "$(PREVIEW_BIND)" -d "$(PREVIEW_OUT)"

preview-watch:
	$(PREVIEW_PYTHON) tools/preview.py --make "$(MAKE)" --source "$(or $(SOURCE),.)" --out "$(PREVIEW_OUT)" --port "$(PREVIEW_PORT)" --bind "$(PREVIEW_BIND)" --interval "$(PREVIEW_WATCH_INTERVAL)" --odin-bin "$(ODIN_BIN)" --odin-build-flags="$(ODIN_BUILD_FLAGS)"

# Build the pinned multi-project catalog through Varde source mode, then serve
# it locally. A timestamped output prevents a preview command from replacing
# another generated showcase; set SHOWCASE_PREVIEW_OUT to retain a known path.
showcase-preview: build-cli
	@showcase_out="$(SHOWCASE_PREVIEW_OUT)"; \
	if [ -z "$$showcase_out" ]; then showcase_out=".varde-preview/showcase-$$(date +%s)"; fi; \
	$(PREVIEW_PYTHON) tools/build_showcase.py --varde "$(CURDIR)/dist/varde" --output "$$showcase_out" && \
	echo "Serving Varde showcase from $$showcase_out at http://$(PREVIEW_BIND):$(PREVIEW_PORT)" && \
	$(PREVIEW_PYTHON) -m http.server "$(PREVIEW_PORT)" --bind "$(PREVIEW_BIND)" -d "$$showcase_out"

sample-odin-stdlib: build-cli
	@test -n "$(ODIN_ROOT)" || (echo "Usage: make sample-odin-stdlib ODIN_ROOT=/path/to/Odin [OUT=dist/varde-stdlib]"; exit 2)
	ODIN_ROOT="$(ODIN_ROOT)" OUT="$(or $(OUT),dist/varde-stdlib)" sh ./examples/odin-stdlib/build.sh
