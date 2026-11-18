# ClaraOS build. Needs clang, lld and qemu with EDK2 firmware, SBCL for the
# tests of the Lisp files on the host, Python for the disks that the
# machines boot from, and the host's checker of FAT volumes for what a
# kernel has written to one: macOS has it, fsck_msdos, and elsewhere it is
# fsck.fat of the dosfstools.
#   macOS:  brew install llvm lld qemu sbcl
#   Ubuntu: apt install clang lld make qemu-system-x86 qemu-system-arm ovmf qemu-efi-aarch64 netcat-openbsd sbcl
#           python3 dosfstools
# Homebrew keeps llvm and lld out of the PATH, so they are looked for where it
# puts them; anywhere else clang and lld-link come from the PATH. LLVM= and
# LLD= name other directories.
LLVM   ?= $(wildcard /opt/homebrew/opt/llvm/bin)
LLD    ?= $(wildcard /opt/homebrew/opt/lld/bin)
SBCL   ?= sbcl
CC     := $(if $(LLVM),$(LLVM)/)clang
LD     := $(if $(LLD),$(LLD)/)lld-link
BUILD  := build
ESP    := $(BUILD)/esp/EFI/BOOT
BOOTDIR := $(BUILD)/esp/clara

CFLAGS := -std=c11 -O2 -g -Wall -Wextra -Werror \
          -ffreestanding -fno-builtin -fno-stack-protector -fno-stack-check \
          -mno-stack-arg-probe -mgeneral-regs-only -fshort-wchar -Ikernel
LDFLAGS := /nologo /subsystem:efi_application /entry:efi_main /nodefaultlib /debug:dwarf

ASFLAGS := -g -Ikernel -Wa,--fatal-warnings

COMMON_SRCS := $(wildcard kernel/*.c kernel/lisp/*.c)
HEADERS     := $(wildcard kernel/*.h kernel/lisp/*.h kernel/arch/*/*.h)
BOOT_FILES  := $(BUILD)/boot-files.stamp

.PHONY: all test host-test image font site clean
all:

# $(1) arch  $(2) clang target  $(3) extra CFLAGS  $(4) EFI file name  $(5) lld machine
define ARCH_RULES
$(1)_OBJS := $$(patsubst kernel/%,$(BUILD)/$(1)/%.o,$$(basename $(COMMON_SRCS) $$(wildcard kernel/arch/$(1)/*.c kernel/arch/$(1)/*.S)))
$(BUILD)/$(1)/%.o: kernel/%.c $(HEADERS)
	@mkdir -p $$(dir $$@)
	$(CC) $(CFLAGS) --target=$(2) $(3) -c $$< -o $$@
$(BUILD)/$(1)/%.o: kernel/%.S $(HEADERS)
	@mkdir -p $$(dir $$@)
	$(CC) $(ASFLAGS) --target=$(2) -c $$< -o $$@
$(ESP)/$(4): $$($(1)_OBJS)
	@mkdir -p $$(dir $$@)
	$(LD) $(LDFLAGS) /machine:$(5) /out:$$@ $$^
all: $(ESP)/$(4)
endef

$(eval $(call ARCH_RULES,x86_64,x86_64-unknown-windows,-mno-red-zone,BOOTX64.EFI,x64))
$(eval $(call ARCH_RULES,aarch64,aarch64-unknown-windows,,BOOTAA64.EFI,arm64))

# The boot handoff reads every file in the ESP's \clara directory: what is
# in lisp/ now, and nothing that was there before and has gone since. The
# file that the evaluator's self-test loads goes with them.
$(BOOT_FILES): lisp $(wildcard lisp/*.lisp) kernel/lisp/self-test.lisp
	rm -rf $(BOOTDIR)
	mkdir -p $(BOOTDIR)
	cp lisp/*.lisp kernel/lisp/self-test.lisp $(BOOTDIR)/
	touch $@
all: $(BOOT_FILES)

run-%: all
	tools/run.sh $*

# The Lisp files, loaded under SBCL on top of a machine that lisp/host/
# makes up, and checked there: what the console sends, draws and reads,
# and what the listener answers.
host-test:
	$(SBCL) --script lisp/host/tests.lisp

# Then the boots. AArch64 boots twice, once for each version of its interrupt controller:
# version 3 as UTM runs it, accelerated where the host can, and version 2
# emulated, because QEMU's hvf has no version 2. Each of the three machines
# boots from a disk of its own kind, a volume of 32 bits behind a GUID
# partition table, one of 16 behind a table of partitions of old, and one
# of 12 that is the whole disk, and each boots twice: the session of the
# first boot writes files to the volume and ends by saving the world there
# (tools/session.txt), and the second boot, from a copy of that disk, has
# to find the image, start from it, and answer for what the first one
# defined (tools/resumed.txt). After every boot the host's own checker of
# FAT volumes looks at the disk. Then the user manual: what it shows of
# the prompt (site/manual.html) is typed at a machine, which saves its
# world, and at the same machine started again. Then AArch64 once more for
# tools/stress.txt, a session in which the collector runs at every safe
# point of the evaluator while boot.lisp is loaded again and the
# evaluator's self-test is repeated: whatever the evaluator fails to hold
# on to is gone at its next call. That takes three minutes where AArch64
# is emulated, on CI, and more as the world grows, so it is given ten. Its
# disk is the one with the saved world,
# with one byte of it changed: the kernel has to say so, and start from the
# files.
RESUME := SESSION=tools/resumed.txt EXPECT='^lisp: the heap is an image'
test: all host-test
	tools/boottest.sh x86_64
	NAME=x86_64-resumed DISK=$(BUILD)/boot-x86_64.img $(RESUME) tools/boottest.sh x86_64
	MKDISK="--fat 16 --table mbr" tools/boottest.sh aarch64 -machine gic-version=3
	NAME=aarch64-resumed DISK=$(BUILD)/boot-aarch64.img $(RESUME) tools/boottest.sh aarch64 -machine gic-version=3
	NAME=aarch64-gic2 NO_HVF=1 MKDISK="--fat 12 --table none" tools/boottest.sh aarch64 -machine gic-version=2
	NAME=aarch64-gic2-resumed NO_HVF=1 DISK=$(BUILD)/boot-aarch64-gic2.img $(RESUME) \
		tools/boottest.sh aarch64 -machine gic-version=2
	python3 -I site/build.py --sessions $(BUILD)
	NAME=manual SESSION=$(BUILD)/manual-first.txt tools/boottest.sh aarch64 -machine gic-version=3
	NAME=manual-again DISK=$(BUILD)/boot-manual.img SESSION=$(BUILD)/manual-again.txt \
		EXPECT='^lisp: the heap is an image' tools/boottest.sh aarch64 -machine gic-version=3
	NAME=aarch64-stress SESSION=tools/stress.txt TIMEOUT=600 DISK=$(BUILD)/boot-aarch64.img SPOIL=1 \
		EXPECT='^lisp: clara.image is not resumed: it is not what was saved' \
		tools/boottest.sh aarch64 -machine gic-version=3

image: all
	tools/mkimage.sh

# Regenerate kernel/font.c and lisp/font.lisp, the same glyphs for the two
# consoles, after changing the font or tools/bdf2c.py.
font:
	python3 -I tools/bdf2c.py fonts/spleen-8x16.bdf fonts/LICENSE.spleen kernel/font.c lisp/font.lisp

# The website, the way .github/workflows/site.yml builds it for GitHub Pages:
# the front page and the user manual, which is held against the kernel on
# the way, and stops the build when a name is defined that it has no word
# about.
site:
	python3 -I site/build.py $(BUILD)/site

clean:
	rm -rf $(BUILD)
