# ClaraOS build. Needs Homebrew llvm, lld and qemu (brew install llvm lld qemu).
LLVM   ?= /opt/homebrew/opt/llvm/bin
CC     := $(LLVM)/clang
LLD    ?= /opt/homebrew/opt/lld/bin
LD     := $(LLD)/lld-link
BUILD  := build
ESP    := $(BUILD)/esp/EFI/BOOT

CFLAGS := -std=c11 -O2 -g -Wall -Wextra -Werror \
          -ffreestanding -fno-builtin -fno-stack-protector -fno-stack-check \
          -mno-stack-arg-probe -mgeneral-regs-only -fshort-wchar -Ikernel
LDFLAGS := /nologo /subsystem:efi_application /entry:efi_main /nodefaultlib /debug:dwarf

COMMON_SRCS := $(wildcard kernel/*.c)
HEADERS     := $(wildcard kernel/*.h)

.PHONY: all test image clean
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

run-%: all
	tools/run.sh $*

test: all
	tools/boottest.sh x86_64
	tools/boottest.sh aarch64

image: all
	tools/mkimage.sh

clean:
	rm -rf $(BUILD)
