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

.PHONY: all test host-test image font site screenshot clean
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
# world, and at the same machine started again. That machine has a second
# disk, with a volume that has nothing on it, given to it the way
# tools/run.sh gives a user's machine a disk of the user's own (WORK=): the
# manual keeps a file there, and the machine that is started again has to
# find it. Then AArch64 once more,
# with the collector at every safe point of the evaluator: whatever the
# evaluator fails to hold on to is gone at its next call. Its disk is the
# one that the first session of that machine left, which has two things on
# it for this boot. The saved world, with one byte of it changed: the
# kernel has to say so, and start from the files. And a file \clara\stress,
# which asks the kernel to load boot.lisp again and to repeat the
# evaluator's self-test with such a collection, and then the compiler's,
# for what compiled code holds, before the rest of the world is in the heap
# for every collection to go through. tools/stress.txt
# then has the collector do the same for a few forms at the prompt, one of
# them typed on the keyboard. Where AArch64 is emulated, on CI, that boot
# takes minutes, so it is given ten. A world that was saved is compiled
# through and through, and the second boot of each machine has to say so:
# none of its functions is left for the evaluator to walk, and the machine
# runs the three that the first session compiled for it, and no other: the
# rest is the processor's. A disk of the user's own, which WORK= names for
# `make run-*`, stays out of all of them: a machine here has the disks that
# its line gives it.
test: export WORK :=
RESUME := SESSION=tools/resumed.txt EXPECT='^lisp: the heap is an image;;^lisp: and with it [0-9]* KiB of code for the processor;;^lisp:   of the functions .* and 0 are walked;;^lisp:   the processor runs [1-9][0-9]* of the compiled ones itself, .* and the machine 3[^0-9]*$$'
test: all host-test
	tools/boottest.sh x86_64
	NAME=x86_64-resumed DISK=$(BUILD)/boot-x86_64.img $(RESUME) tools/boottest.sh x86_64
	MKDISK="--fat 16 --table mbr" tools/boottest.sh aarch64 -machine gic-version=3
	NAME=aarch64-resumed DISK=$(BUILD)/boot-aarch64.img $(RESUME) tools/boottest.sh aarch64 -machine gic-version=3
	NAME=aarch64-gic2 NO_HVF=1 MKDISK="--fat 12 --table none" tools/boottest.sh aarch64 -machine gic-version=2
	NAME=aarch64-gic2-resumed NO_HVF=1 DISK=$(BUILD)/boot-aarch64-gic2.img $(RESUME) \
		tools/boottest.sh aarch64 -machine gic-version=2
	python3 -I site/build.py --sessions $(BUILD)
	rm -rf $(BUILD)/empty && mkdir -p $(BUILD)/empty && python3 -I tools/mkdisk.py $(BUILD)/empty $(BUILD)/work.img
	NAME=manual WORK=$(BUILD)/work.img SESSION=$(BUILD)/manual-first.txt tools/boottest.sh aarch64 -machine gic-version=3
	NAME=manual-again DISK=$(BUILD)/boot-manual.img WORK=$(BUILD)/work-manual.img SESSION=$(BUILD)/manual-again.txt \
		EXPECT='^lisp: the heap is an image;;^lisp:   of the functions .* and 0 are walked' \
		tools/boottest.sh aarch64 -machine gic-version=3
	NAME=aarch64-stress SESSION=tools/stress.txt TIMEOUT=600 DISK=$(BUILD)/boot-aarch64.img SPOIL=1 \
		EXPECT='^lisp: clara.image is not resumed: it is not what was saved;;^lisp: a collection at every safe point: boot.lisp once more in [0-9]\{4,\}, [0-9]* texts once more in [0-9]\{5,\};;^lisp: a collection at the safe points of compiled code, [0-9]* to a text: [0-9]* texts once more in [0-9]\{4,\};;^lisp: a collection at the safe points of code for the processor, [0-9]* to a text: [0-9]* texts in [0-9]\{3,\}' \
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

# The picture on the website's front page: what the screen of AArch64
# showed at the end of `make test`, in the world that came back, with the
# version that the machine itself named written into the file. `make site`
# refuses a picture of another version than the kernel's, so this goes
# with every change of version, after `make test`.
screenshot:
	python3 -I site/build.py --screenshot $(BUILD)/screen-aarch64-resumed.png $(BUILD)/boot-aarch64-resumed.log

clean:
	rm -rf $(BUILD)
