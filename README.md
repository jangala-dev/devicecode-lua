This repository contains the Lua version of [Jangala's](https://www.janga.la) `devicecode`, the
program that powers our Big Box and Get Box devices.

# Using make script
SRC_DIR, TEST_DIR and BUILD_DIR are all optional values
## Initialise dev environment
Before testing or building the code all submodules need to be loaded in. You can select
the version of each submodule in `.env`.
```
make env SRC_DIR=<src>
```

## Build devicecode
Building devicecode creates a folder with only required source files and restructures the submodules
to make a simpler file structure.
```
make build SRC_DIR=<src> BUILD_DIR=<build>
```

## Test devicecode
Devicecode and it's submodules can be tested, to test devicecode only
```
make test TEST_DIR=<tests>
```
to test devicecode and the submodules
```
make test-all TEST_DIR=<tests> SRC_DIR=<src>
```

## Linter
To run the linter
```
make lint SRC_DIR=<src> TEST_DIR=<tests>
```
