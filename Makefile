# Variables
include .env
SRC_DIR    := src
VENDOR_DIR := vendor
BUILD_DIR  := build
TEST_DIR   := tests
LINTER     := luacheck
LUA_INDENT_DIRS := $(SRC_DIR) $(TEST_DIR) examples tools
UI_REPO   ?= https://github.com/jangala-dev/local-ui.git
UI_DIR    ?= local-ui
UI_WWW_DIR := $(SRC_DIR)/services/ui/www

# Default target
.PHONY: all
all: env build-all test-all lint

# Build: Copy source files into the build directory
.PHONY: build
build:
	@echo "Building source..."
	@rm -rf $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)
	@cp -r $(SRC_DIR)/* $(BUILD_DIR)/
	@rm -rf $(BUILD_DIR)/services/ui/local-ui
	@echo "Build complete."

# Build-Vendor: Copy vendor library source into build/lib
.PHONY: build-vendor
build-vendor:
	@echo "Building vendor libs..."
	@mkdir -p $(BUILD_DIR)/lib
	@cp -r $(VENDOR_DIR)/lua-fibers/src/. $(BUILD_DIR)/lib/
	@cp -r $(VENDOR_DIR)/lua-trie/src/. $(BUILD_DIR)/lib/
	@cp -r $(VENDOR_DIR)/lua-bus/src/. $(BUILD_DIR)/lib/
	@echo "Vendor build complete."

# Build-UI: Build local-ui and stage static files for the UI service
.PHONY: build-ui
build-ui:
	@echo "Building local UI..."
	@if [ ! -d "$(UI_DIR)/client" ]; then \
		echo "local-ui checkout missing; run 'make env' first." >&2; \
		exit 1; \
	fi
	@$(MAKE) -C $(UI_DIR) build
	@rm -rf $(UI_WWW_DIR)
	@mkdir -p $(UI_WWW_DIR)
	@cp -R $(UI_DIR)/build/dist/. $(UI_WWW_DIR)/
	@echo "Local UI build complete."

# Build-All: Build UI, source, and vendor libs, then substitute secrets
.PHONY: build-all
build-all: build-ui build build-vendor substitute-secrets

# Substitute-Secrets: Replace $VAR placeholders in build configs using .env.secret
.PHONY: substitute-secrets
substitute-secrets:
	@echo "Substituting secrets in build configs..."
	@if [ ! -f .env.secret ]; then \
		echo "WARNING: .env.secret not found — \$$VAR placeholders in build configs will not be replaced."; \
	else \
		while IFS='=' read -r key value; do \
			[ -z "$$key" ] && continue; \
			find $(BUILD_DIR)/configs -name "*.json" | while read -r f; do \
				sed -i 's|\$$'"$$key"'|'"$$value"'|g' "$$f"; \
			done; \
		done < .env.secret; \
	fi
	@echo "Secret substitution complete."

# Env: Pin each vendor submodule to the revision specified in .env
.PHONY: env
env:
	@echo "Initialising vendor submodules..."
	@git submodule update --init --recursive
	@cd $(VENDOR_DIR)/lua-fibers && git fetch && git checkout $(FIBERS_VER)
	@cd $(VENDOR_DIR)/lua-trie   && git fetch && git checkout $(TRIE_VER)
	@cd $(VENDOR_DIR)/lua-bus    && git fetch && git checkout $(BUS_VER)
	@if [ ! -d "$(UI_DIR)/.git" ]; then \
		if [ -e "$(UI_DIR)" ]; then \
			echo "$(UI_DIR) exists but is not a git checkout." >&2; \
			exit 1; \
		fi; \
		git clone $(UI_REPO) $(UI_DIR); \
	fi
	@cd $(UI_DIR) && git fetch && git checkout --detach $(UI_VER)
	@cd $(UI_DIR)/client && npm install
	@echo "Submodules pinned."

# Test: Run the devicecode test suite
.PHONY: test
test:
	@echo "Running devicecode tests..."
	@cd $(TEST_DIR) && luajit run.lua
	@echo "Tests complete."

# Test-All: Run devicecode and vendor test suites
.PHONY: test-all
test-all:
	@echo "Running all tests..."
# Devicecode tests
	@cd $(TEST_DIR) && luajit run.lua
# Fibers tests
	@cd $(VENDOR_DIR)/lua-fibers/tests && luajit test.lua
# Trie tests
	@cd $(VENDOR_DIR)/lua-trie/tests && luajit test.lua
# Bus tests — fibers and trie must be present on the require path; stage then clean up
	@cp -r $(VENDOR_DIR)/lua-fibers/src/fibers      $(VENDOR_DIR)/lua-bus/src/
	@cp    $(VENDOR_DIR)/lua-fibers/src/fibers.lua  $(VENDOR_DIR)/lua-bus/src/
	@cp    $(VENDOR_DIR)/lua-fibers/src/coxpcall.lua $(VENDOR_DIR)/lua-bus/src/
	@cp    $(VENDOR_DIR)/lua-trie/src/trie.lua       $(VENDOR_DIR)/lua-bus/src/
	@cd $(VENDOR_DIR)/lua-bus/tests && luajit test.lua
	@rm -rf $(VENDOR_DIR)/lua-bus/src/fibers
	@rm -f  $(VENDOR_DIR)/lua-bus/src/fibers.lua
	@rm -f  $(VENDOR_DIR)/lua-bus/src/coxpcall.lua
	@rm -f  $(VENDOR_DIR)/lua-bus/src/trie.lua
	@echo "All tests complete."

# Check-Indent: Enforce tab-based indentation in first-party Lua files
.PHONY: check-indent
check-indent:
	@echo "Checking Lua indentation..."
	@luajit tools/check_lua_indentation.lua $(LUA_INDENT_DIRS)
	@echo "Lua indentation check complete."

# Lint: Indentation and static analysis on source and test directories
.PHONY: lint
lint: check-indent
	@echo "Running linter..."
	@$(LINTER) $(SRC_DIR) $(TEST_DIR) tools
	@echo "Linting complete."

# Clean: Remove the build directory
.PHONY: clean
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(BUILD_DIR)
	@echo "Clean complete."

# Help: Show available targets
.PHONY: help
help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Targets:"
	@echo "  build         Copy source files into $(BUILD_DIR)/"
	@echo "  build-vendor  Copy vendor library sources into $(BUILD_DIR)/lib/"
	@echo "  build-ui      Build local-ui into $(UI_WWW_DIR)/"
	@echo "  substitute-secrets  Replace \$$VAR placeholders in $(BUILD_DIR)/configs/ using .env.secret"
	@echo "  build-all     Run build-ui, build, build-vendor, and substitute-secrets (default)"
	@echo "  env           Pin vendor submodules to revisions in .env"
	@echo "  test          Run the devicecode test suite"
	@echo "  test-all      Run devicecode and all vendor test suites"
	@echo "  check-indent  Enforce tab-based indentation in first-party Lua files"
	@echo "  lint          Run indentation checks and luacheck"
	@echo "  clean         Remove $(BUILD_DIR)/"
	@echo "  help          Show this message"
