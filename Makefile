# Variables
include .env
SRC_DIR    := src
VENDOR_DIR := vendor
BUILD_DIR  := build
TEST_DIR   := tests
LINTER     := luacheck

# Default target
.PHONY: all
all: build-all

# Build: Copy source files into the build directory
.PHONY: build
build:
	@echo "Building source..."
	@rm -rf $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)
	@cp -r $(SRC_DIR)/* $(BUILD_DIR)/
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

# Build-All: Build source and vendor libs
.PHONY: build-all
build-all: build build-vendor

# Env: Pin each vendor submodule to the revision specified in .env
.PHONY: env
env:
	@echo "Initialising vendor submodules..."
	@git submodule update --init --recursive
	@cd $(VENDOR_DIR)/lua-fibers && git fetch && git checkout $(FIBERS_VER)
	@cd $(VENDOR_DIR)/lua-trie   && git fetch && git checkout $(TRIE_VER)
	@cd $(VENDOR_DIR)/lua-bus    && git fetch && git checkout $(BUS_VER)
	@echo "Vendor submodules pinned."

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

# Lint: Static analysis on source and test directories
.PHONY: lint
lint:
	@echo "Running linter..."
	@$(LINTER) $(SRC_DIR) $(TEST_DIR)
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
	@echo "  build-all     Run both build and build-vendor (default)"
	@echo "  env           Pin vendor submodules to revisions in .env"
	@echo "  test          Run the devicecode test suite"
	@echo "  test-all      Run devicecode and all vendor test suites"
	@echo "  lint          Run luacheck on $(SRC_DIR)/ and $(TEST_DIR)/"
	@echo "  clean         Remove $(BUILD_DIR)/"
	@echo "  help          Show this message"
