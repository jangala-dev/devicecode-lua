# Variables
include .env
SRC_DIR := src
BUILD_DIR := build
TEST_DIR := tests
LINTER := luacheck

# Default target
.PHONY: all
all: env test-all build lint

# Build: Moves source files and removes and testing from submodules
.PHONY: build
build:
	@echo "Building the project..."
	@mkdir -p $(BUILD_DIR)
	@cp -r $(SRC_DIR)/* $(BUILD_DIR)/
	@cp $(BUILD_DIR)/lua-bus/src/* $(BUILD_DIR)
	@rm -r $(BUILD_DIR)/lua-bus
	@cp -r $(BUILD_DIR)/lua-fibers/fibers $(BUILD_DIR)
	@rm -r $(BUILD_DIR)/lua-fibers
	@cp $(BUILD_DIR)/lua-trie/src/* $(BUILD_DIR)
	@rm -r $(BUILD_DIR)/lua-trie
	@echo "Build complete."

# Test: Run the project's test suite
.PHONY: test
test:
	@echo "Running project tests..."
	@cd $(TEST_DIR) && luajit test.lua
	@echo "Tests completed."

# Test-All: Run the project's and submodule's test suite
.PHONY: test-all
test-all:
	@echo "Running all tests..."
# Devicecode tests
	@cd $(TEST_DIR) && luajit test.lua
# Fiber tests
	@cd $(SRC_DIR)/lua-fibers/tests && luajit test.lua
# Trie tests
	@cd $(SRC_DIR)/lua-trie/tests && luajit test.lua
# Bus tests (require movement of fiber and trie then cleanup)
	@cp -r $(SRC_DIR)/lua-fibers/fibers $(SRC_DIR)/lua-bus/src
	@cp -r $(SRC_DIR)/lua-trie/src/* $(SRC_DIR)/lua-bus/src
	@cd $(SRC_DIR)/lua-bus/tests && luajit test.lua
	@rm -rf $(SRC_DIR)/lua-bus/src/fibers
	@rm -rf $(SRC_DIR)/lua-bus/src/trie.lua
	@echo "Tests completed."

# Env: Initialize environment and update git submodules
.PHONY: env
env:
	@echo "Updating git submodules..."
	@git submodule update --init --recursive
	@cd $(SRC_DIR)/lua-fibers && git checkout $(FIBERS_VER)
	@cd $(SRC_DIR)/lua-trie && git checkout $(TRIE_VER)
	@cd $(SRC_DIR)/lua-bus && git checkout $(BUS_VER)
	@cd $(SRC_DIR)/services/ui/local-ui && git checkout $(UI_VER)
	@echo "Git submodules updated."

# Lint: Run the linter to check code quality
.PHONY: lint
lint:
	@echo "Running linter..."
	@$(LINTER) $(SRC_DIR) $(TEST_DIR)
	@echo "Linting complete."

# Clean: Remove build artifacts
.PHONY: clean
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(BUILD_DIR)
	@echo "Clean complete."

# Help: Display available targets
help:
	@echo "Available targets:"
	@echo "all          - Build, test, lint, and update submodules"
	@echo "build        - Build the project (removes testing code and documentation)"
	@echo "test         - Run project test suite"
	@echo "test-all     - Run project and submodules test suite"
	@echo "env          - Update and initialize git submodules"
	@echo "lint         - Run the code linter"
	@echo "clean        - Remove build artifacts"
	@echo "help         - Display this help message"
