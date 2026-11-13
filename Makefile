# ClaraOS build. Needs clang, lld and qemu with EDK2 firmware.
#   macOS:  brew install llvm lld qemu
#   Ubuntu: apt install clang lld make qemu-system-x86 qemu-system-arm ovmf qemu-efi-aarch64 netcat-openbsd
# Homebrew keeps llvm and lld out of the PATH, so they are looked for where it
# puts them; anywhere else clang and lld-link come from the PATH. LLVM= and
# LLD= name other directories.
LLVM   ?= $(wildcard /opt/homebrew/opt/llvm/bin)
LLD    ?= $(wildcard /opt/homebrew/opt/lld/bin)
CC     := $(if $(LLVM),$(LLVM)/)clang
LD     := $(if $(LLD),$(LLD)/)lld-link
BUILD  := build
ESP    := $(BUILD)/esp/EFI/BOOT
BOOTDIR := $(BUILD)/esp/clara

CFLAGS := -std=c11 -O2 -g -Wall -Wextra -Werror \
          -ffreestanding -fno-builtin -fno-stack-protector -fno-stack-check \
          -mno-stack-arg-probe -mgeneral-regs-only -fshort-wchar -Ikernel
LDFLAGS := /nologo /subsystem:efi_application /entry:efi_main /nodefaultlib /debug:dwarf

COMMON_SRCS := $(wildcard kernel/*.c)
HEADERS     := $(wildcard kernel/*.h)
BOOT_FILES  := $(patsubst lisp/%,$(BOOTDIR)/%,$(wildcard lisp/*.lisp))

.PHONY: all test image font site clean
all:

# $(1) arch  $(2) clang target  $(3) extra CFLAGS  $(4) EFI file name  $(5) lld machine
define ARCH_RULES
$(1)_OBJS := $$(patsubst kernel/%.c,$(BUILD)/$(1)/%.o,$(COMMON_SRCS) $$(wildcard kernel/arch/$(1)/*.c))
$(BUILD)/$(1)/%.o: kernel/%.c $(HEADERS)
	@mkdir -p $$(dir $$@)
	$(CC) $(CFLAGS) --target=$(2) $(3) -c $$< -o $$@
$(ESP)/$(4): $$($(1)_OBJS)
	@mkdir -p $$(dir $$@)
	$(LD) $(LDFLAGS) /machine:$(5) /out:$$@ $$^
all: $(ESP)/$(4)
endef

$(eval $(call ARCH_RULES,x86_64,x86_64-unknown-windows,-mno-red-zone,BOOTX64.EFI,x64))
$(eval $(call ARCH_RULES,aarch64,aarch64-unknown-windows,,BOOTAA64.EFI,arm64))

# The boot handoff reads every file in the ESP's \clara directory.
$(BOOTDIR)/%: lisp/%
	@mkdir -p $(dir $@)
	cp $< $@
all: $(BOOT_FILES)

run-%: all
	tools/run.sh $*

test: all
	tools/boottest.sh x86_64
	tools/boottest.sh aarch64

image: all
	tools/mkimage.sh

# Regenerate kernel/font.c after changing the font or tools/bdf2c.py.
font:
	python3 -I tools/bdf2c.py fonts/spleen-8x16.bdf fonts/LICENSE.spleen kernel/font.c

# The website, the way .github/workflows/site.yml builds it for GitHub Pages.
site:
	python3 -I site/build.py $(BUILD)/site

clean:
	rm -rf $(BUILD)
