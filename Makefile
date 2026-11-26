# DownlinkScope build file.
# Targets: all, test, asan, lint, format, compdb, bench-up, bench-down, clean, help.

CC      ?= cc
BUILD   := build
TARGET  := $(BUILD)/downlinkscope

PKGS    := libpcap libcrypto
PKG_CFLAGS := $(shell pkg-config --cflags $(PKGS))
PKG_LIBS   := $(shell pkg-config --libs $(PKGS))

WARN    := -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wsign-conversion \
           -Wformat=2 -Wstrict-prototypes -Wmissing-prototypes -Werror
HARDEN  := -D_FORTIFY_SOURCE=2 -fstack-protector-strong
CSTD    := -std=c11 -D_DEFAULT_SOURCE
CPPFLAGS += -Iinclude
# OPT holds optimisation and instrumentation flags. The sanitizer build
# overrides only OPT, so the standard and warning flags always stay active.
OPT     ?= -O2
CFLAGS  ?=
ALL_CFLAGS := $(OPT) $(CSTD) $(WARN) $(PKG_CFLAGS) $(CFLAGS)

SAN     := -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all

# Library sources: everything in src/ except the program entry point.
LIB_SRC := $(filter-out src/main.c,$(wildcard src/*.c))
LIB_OBJ := $(LIB_SRC:src/%.c=$(BUILD)/obj/%.o)

TEST_SRC := $(wildcard tests/unit/test_*.c)
TEST_BIN := $(TEST_SRC:tests/unit/%.c=$(BUILD)/tests/%)

UNITY_DIR := third_party/unity
UNITY_OBJ := $(BUILD)/obj/unity.o
# Third-party code: warnings shown, but never treated as errors.
UNITY_CFLAGS := $(CSTD) -O1 -g -Wall

LINT_SRC := $(wildcard src/*.c include/dls/*.h tests/unit/*.c)

.PHONY: all test asan lint format compdb bench-up bench-down clean help

all: $(TARGET)

$(TARGET): $(BUILD)/obj/main.o $(LIB_OBJ)
	$(CC) $(ALL_CFLAGS) $(LDFLAGS) -o $@ $^ $(PKG_LIBS)

$(BUILD)/obj/%.o: src/%.c | $(BUILD)/obj
	$(CC) $(CPPFLAGS) $(HARDEN) $(ALL_CFLAGS) -MMD -MP -c -o $@ $<

$(UNITY_OBJ): $(UNITY_DIR)/unity.c | $(BUILD)/obj
	$(CC) $(UNITY_CFLAGS) -c -o $@ $<

$(BUILD)/tests/test_%: tests/unit/test_%.c $(LIB_OBJ) $(UNITY_OBJ) | $(BUILD)/tests
	$(CC) $(CPPFLAGS) -I$(UNITY_DIR) $(ALL_CFLAGS) $(LDFLAGS) -o $@ $^ $(PKG_LIBS)

test: $(TEST_BIN)
	@set -e; for t in $(TEST_BIN); do echo "== $$t"; $$t; done

# Rebuild everything with AddressSanitizer and UndefinedBehaviorSanitizer, then run the tests.
asan:
	$(MAKE) clean
	$(MAKE) test OPT="$(SAN)" LDFLAGS="-fsanitize=address,undefined" HARDEN=""

lint:
	clang-format --dry-run --Werror $(LINT_SRC)
	cppcheck --quiet --error-exitcode=1 --enable=warning,style,performance,portability \
	  --std=c11 --inline-suppr -Iinclude src include tests/unit
	clang-tidy --quiet $(filter %.c,$(LINT_SRC)) -- $(CPPFLAGS) -I$(UNITY_DIR) $(CSTD) $(PKG_CFLAGS)
	shellcheck bench/*.sh
	python3 -m py_compile bench/*.py

format:
	clang-format -i $(LINT_SRC)

# compile_commands.json for CLion code analysis.
compdb:
	$(MAKE) clean
	bear -- $(MAKE) all $(TEST_BIN)

# Test bench: network namespaces with netem, then ChirpStack in Docker.
# See bench/README.md. The network commands need root rights.
bench-up:
	sudo bench/netns.sh up
	bench/bench.sh up

bench-down:
	-bench/bench.sh down
	sudo bench/netns.sh down

$(BUILD)/obj $(BUILD)/tests:
	mkdir -p $@

clean:
	rm -rf $(BUILD)

help:
	@echo "make         build $(TARGET)"
	@echo "make test    build and run the unit tests"
	@echo "make asan    run the unit tests with sanitizers"
	@echo "make lint    clang-format check, cppcheck, clang-tidy"
	@echo "make format  format the sources in place"
	@echo "make compdb  write compile_commands.json for the IDE"
	@echo "make bench-up    start the test bench (see bench/README.md)"
	@echo "make bench-down  stop the test bench"

-include $(wildcard $(BUILD)/obj/*.d)
