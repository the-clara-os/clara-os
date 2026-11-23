# ClaraOS build. Needs clang, lld and qemu with EDK2 firmware, SBCL for the
# tests of the Lisp files on the host, Python for the disks that the
# machines boot from and for the web server that one of them fetches a
# signed release from, and the host's checker of FAT volumes for what a
# kernel has written to one: macOS has it, fsck_msdos, and elsewhere it is
# fsck.fat of the dosfstools. QEMU is 8.2 or newer: that is the first to
# have the sound card that every machine of the tests is given.
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

CFLAGS := -std=c11 -O2 -g -Wall -Wextra -Werror \
          -ffreestanding -fno-builtin -fno-stack-protector -fno-stack-check \
          -mno-stack-arg-probe -mgeneral-regs-only -fshort-wchar -Ikernel
LDFLAGS := /nologo /subsystem:efi_application /entry:efi_main /nodefaultlib /debug:dwarf

ASFLAGS := -g -Ikernel -Wa,--fatal-warnings

COMMON_SRCS := $(filter-out kernel/system.c,$(wildcard kernel/*.c kernel/lisp/*.c))
HEADERS     := $(wildcard kernel/*.h kernel/lisp/*.h kernel/arch/*/*.h)
BOOT_FILES  := $(BUILD)/boot-files.stamp

# What this build is called: its version, and eight digits that are worked
# out from every source that goes into it (tools/system.py), so that the
# same sources are the same system wherever they are built, and a change to
# any of them is another one. Both kernels have the name in them
# (kernel/system.c), and the Lisp files of the system, with a copy of the
# kernels and a list of what there is, are in the directory of that name
# on the boot volume, \clara\<name>: a kernel starts with the files that it
# was built with, and a newer system can be put beside the one that runs
# (lisp/system.lisp).
VERSION     := $(shell sed -n 's/^\#define CLARA_VERSION "\(.*\)"/\1/p' kernel/kernel.h)
FONTS       := $(wildcard fonts/*.ttf)
SYSTEM_SRCS := $(sort kernel/system.c $(COMMON_SRCS) $(HEADERS) kernel/lisp/self-test.lisp \
                 $(wildcard kernel/arch/*/*.c kernel/arch/*/*.S lisp/*.lisp) lisp/roots.pem $(FONTS))
SYSTEM      := $(VERSION)-$(shell python3 -I tools/system.py id $(SYSTEM_SRCS))
BOOTDIR     := $(BUILD)/esp/clara/$(SYSTEM)

.PHONY: all test host-test image font site screenshot release release-test clean FORCE
all:

# The name of this build, in a file that is written when the name is not
# the one that the file says, and left alone otherwise. The object that
# has the name in it is made again when the file is newer, and the kernels
# are linked again then. Without it a build went wrong whose sources had
# gone back to what they were at an earlier build, a change to a Lisp file
# that was taken out again: the object of that name was still there, and
# older than the kernels of the build in between, so they were not linked
# again, kept that build's name, and looked for their files in a directory
# that was no longer there.
$(BUILD)/system.name: FORCE
	@mkdir -p $(BUILD)
	@[ "$$(cat $@ 2> /dev/null)" = "$(SYSTEM)" ] || echo "$(SYSTEM)" > $@
FORCE:

# $(1) arch  $(2) clang target  $(3) extra CFLAGS  $(4) EFI file name  $(5) lld machine
define ARCH_RULES
$(1)_OBJS := $$(patsubst kernel/%,$(BUILD)/$(1)/%.o,$$(basename $(COMMON_SRCS) $$(wildcard kernel/arch/$(1)/*.c kernel/arch/$(1)/*.S)))
$(BUILD)/$(1)/%.o: kernel/%.c $(HEADERS)
	@mkdir -p $$(dir $$@)
	$(CC) $(CFLAGS) --target=$(2) $(3) -c $$< -o $$@
$(BUILD)/$(1)/%.o: kernel/%.S $(HEADERS)
	@mkdir -p $$(dir $$@)
	$(CC) $(ASFLAGS) --target=$(2) -c $$< -o $$@
$(BUILD)/$(1)/system-%.o: kernel/system.c $(HEADERS) $(BUILD)/system.name
	@mkdir -p $$(dir $$@)
	$(CC) $(CFLAGS) --target=$(2) $(3) -DCLARA_SYSTEM='"$$*"' -c $$< -o $$@
$(ESP)/$(4): $$($(1)_OBJS) $(BUILD)/$(1)/system-$(SYSTEM).o
	@mkdir -p $$(dir $$@)
	$(LD) $(LDFLAGS) /machine:$(5) /out:$$@ $$^
$(BUILD)/system-%/esp/EFI/BOOT/$(4): $$($(1)_OBJS) $(BUILD)/$(1)/system-$(VERSION)-%.o
	@mkdir -p $$(dir $$@)
	$(LD) $(LDFLAGS) /machine:$(5) /out:$$@ $$^
all: $(ESP)/$(4)
endef

$(eval $(call ARCH_RULES,x86_64,x86_64-unknown-windows,-mno-red-zone,BOOTX64.EFI,x64))
$(eval $(call ARCH_RULES,aarch64,aarch64-unknown-windows,,BOOTAA64.EFI,arm64))

# The boot handoff reads the files in the system's directory on the ESP:
# what is in lisp/ now, and nothing that was there before and has gone
# since. The file that the evaluator's self-test loads goes with them, and
# so do the two kernels, a second time: a system is its directory, which is
# what another machine takes when it is given this disk to upgrade from.
# The manifest is written last, and is what says that a system is whole.
# A kernel that names another system than the directory it is put in would
# look for its files somewhere else, and find none: the build stops there.
$(BOOT_FILES): lisp $(wildcard lisp/*.lisp) lisp/roots.pem $(FONTS) kernel/lisp/self-test.lisp $(ESP)/BOOTX64.EFI $(ESP)/BOOTAA64.EFI tools/system.py
	rm -rf $(BUILD)/esp/clara
	mkdir -p $(BOOTDIR)
	cp lisp/*.lisp lisp/roots.pem $(FONTS) kernel/lisp/self-test.lisp $(ESP)/BOOTX64.EFI $(ESP)/BOOTAA64.EFI $(BOOTDIR)/
	@for kernel in $(ESP)/BOOTX64.EFI $(ESP)/BOOTAA64.EFI; do \
		LC_ALL=C grep -q -F "$(SYSTEM)" $$kernel || { \
			echo "make: $$kernel was linked as another system than $(SYSTEM), which is what this build is: remove it, and make again" >&2; \
			exit 1; }; done
	python3 -I tools/system.py manifest $(BOOTDIR) $(SYSTEM)
	touch $@
all: $(BOOT_FILES)

# Another system, for the tests of upgrades, which need a system to upgrade
# to: the same sources under another name, the version and what the % is,
# as build/system-%/esp. Its kernels are this build's with the other name
# in them, which costs two links. One whose name begins with "broken" has
# a boot.lisp that is no Lisp: a system that does not come to its prompt.
$(BUILD)/system-%/stamp: $(BUILD)/system-%/esp/EFI/BOOT/BOOTX64.EFI $(BUILD)/system-%/esp/EFI/BOOT/BOOTAA64.EFI $(BOOT_FILES)
	rm -rf $(BUILD)/system-$*/esp/clara
	mkdir -p $(BUILD)/system-$*/esp/clara/$(VERSION)-$*
	cp lisp/*.lisp $(FONTS) kernel/lisp/self-test.lisp $(BUILD)/system-$*/esp/EFI/BOOT/BOOTX64.EFI \
		$(BUILD)/system-$*/esp/EFI/BOOT/BOOTAA64.EFI $(BUILD)/system-$*/esp/clara/$(VERSION)-$*/
	case $* in broken*) echo '(this is no Lisp' > $(BUILD)/system-$*/esp/clara/$(VERSION)-$*/boot.lisp;; esac
	python3 -I tools/system.py manifest $(BUILD)/system-$*/esp/clara/$(VERSION)-$* $(VERSION)-$*
	touch $@

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
# FAT volumes looks at the disk. Then each of the three machines once more
# from that disk, with the devices that UTM gives a machine in place of
# virtio's (UTM=1, tools/utm.txt): a USB controller with a tablet, a mouse
# and a keyboard at its ports, and Intel's sound card. What is typed on
# that keyboard has to reach the REPL's window, Ctrl-C has to stop a
# form there, the mouse has to drag the window, and a tone has to be
# played, which is held to what it is like, and not to every frame, since
# that card plays by the clock. Then each kind of processor once more, from
# the disk that its first session left, for what is done to a machine and
# not in it (tools/power.txt): it is asked to shut down while Emma has
# a text that is not saved, and has to refuse; it is told to start again,
# and has to come up in the world that it saved on the way; and its power
# button is pressed, as a host does to stop a machine, after which it has
# to save the world once more and be gone by itself, with its volume in
# order. Then upgrades (lisp/system.lisp), for which the build makes two
# more systems of the same sources, each under a name of its own, and a
# disk of each. One machine starts from the disk of its first session with
# the disk of the other system beside it (tools/upgrade.txt): it is told
# to take that system, starts again, and has to come up as the other
# system, by way of the old kernel, with the files that were written
# before; and after one more start it has to be that system from the
# firmware on. A machine of the other kind of processor, whose firmware is
# another program, starts from a new disk with a second one that says "at
# once", which is how `make run-*` hands a machine a newer build
# (tools/at-once.txt): it has to take the system without being told, start
# again by itself, and come to its first prompt as the other system. And
# one machine is given a system that does not
# come to its prompt (tools/trial.txt): it has to be the system from
# before again when it is started the next time, and say so; and then it
# saves a world that stands still before its prompt, which the start
# after that one has to pass over, and the one after that, the second
# time, has to replace. One more machine has no second disk and fetches:
# the other system is laid out as a release, signed with a key that is
# made for the run (tools/release.py), and handed out by a web server on
# this computer, which also knows names (tools/serve.py, SERVE=), by HTTP
# and, with certificates that are made for the run as well
# (tools/certs.py, CERTS=), by HTTPS. The machine asks for its address,
# looks a name up, fetches files both ways, is given the root of those
# certificates on a disk and told to trust it, has to refuse a server
# whose certificate is too old, is for another name or was signed by
# nobody it knows, and the release while it has no key or another one,
# and then takes it, by HTTPS, and comes up as the other system
# (tools/network.txt). Then the user
# manual: what it shows of
# the prompt (site/manual.html) is typed at a machine, which saves its
# world, and at the same machine started again. That machine has a second
# disk, with a volume that has nothing on it, given to it the way
# tools/run.sh gives a user's machine a disk of the user's own (WORK=): the
# manual keeps a file there, and the machine that is started again has to
# find it. Then the object system (lisp/clos.lisp): a machine is typed
# tools/objects.txt, the transcript that the host tests have answered by
# that file under SBCL and by SBCL's own object system, and has to give
# the same answers a third time. Then AArch64 once more,
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
# takes minutes, so it is given fifteen. A world that was saved is compiled
# through and through, and the second boot of each machine has to say so:
# none of its functions is left for the evaluator to walk, and the machine
# runs the three that the first session compiled for it, and no other: the
# rest is the processor's. A disk of the user's own, which WORK= names for
# `make run-*`, stays out of all of them: a machine here has the disks that
# its line gives it.
test: export WORK :=
test: export SOUND := capture
test: export UTM :=
SECOND = -drive if=none,id=second,format=raw,readonly=on,file=$(BUILD)/$(1).img -device virtio-blk-pci,drive=second
UPGRADED := EXPECT='^ClaraOS: starting the system that is to be tried;;^system: .*-other has come to its prompt;;^world: made anew by ClaraOS .*-other;;^home: /home/init.lisp is loaded, 1 form of it, and 3 were passed over:;;^home:     the stack is full;;^home:     /home/init.lisp is loaded into a new world by itself;;^home: /home/defined.lisp is loaded, [0-9]* forms[^ ]*$$;;^world:   .*\*JOBS\*;;^world:   .*\*WINDOW\*;;^world:   .*NOT-WRITTEN-DOWN;;^world: it is saved as it is now;;^home: /home/defined.lisp has 1 form that this world did not have, which is loaded now'
POWER :=SESSION=tools/power.txt MARKER='^clara: turning the machine off' EXPECT='^lisp: the heap is an image'
AS_UTM := UTM=1 SESSION=tools/utm.txt EXPECT='^lisp: the heap is an image;;^usb: .* is a USB controller: 8 ports, and at them 3 devices;;^input: .* is a tablet, QEMU USB Tablet;;^input: .* is a mouse, QEMU USB Mouse;;^input: .* is a keyboard, QEMU USB Keyboard;;^sound: .* is a sound card of Intel.s kind: 48000 frames a second'
RESUME := SESSION=tools/resumed.txt EXPECT='^lisp: the heap is an image;;^type: 8 files of outlines came with the system;;^lisp: and with it [0-9]* KiB of code for the processor;;^lisp:   of the functions .* and 0 are walked;;^lisp:   the processor runs [1-9][0-9]* of the compiled ones itself, .* and the machine 3[^0-9]*$$'
test: all host-test release-test $(BUILD)/system-other/stamp $(BUILD)/system-broken/stamp
	tools/boottest.sh x86_64
	NAME=x86_64-resumed DISK=$(BUILD)/boot-x86_64.img $(RESUME) tools/boottest.sh x86_64
	MKDISK="--fat 16 --table mbr" tools/boottest.sh aarch64 -machine gic-version=3
	NAME=aarch64-resumed DISK=$(BUILD)/boot-aarch64.img $(RESUME) tools/boottest.sh aarch64 -machine gic-version=3
	NAME=aarch64-gic2 NO_HVF=1 MKDISK="--fat 12 --table none" tools/boottest.sh aarch64 -machine gic-version=2
	NAME=aarch64-gic2-resumed NO_HVF=1 DISK=$(BUILD)/boot-aarch64-gic2.img $(RESUME) \
		tools/boottest.sh aarch64 -machine gic-version=2
	NAME=x86_64-utm DISK=$(BUILD)/boot-x86_64.img $(AS_UTM) tools/boottest.sh x86_64
	NAME=aarch64-utm DISK=$(BUILD)/boot-aarch64.img $(AS_UTM) tools/boottest.sh aarch64 -machine gic-version=3
	NAME=aarch64-gic2-utm NO_HVF=1 DISK=$(BUILD)/boot-aarch64-gic2.img $(AS_UTM) \
		tools/boottest.sh aarch64 -machine gic-version=2
	NAME=x86_64-power DISK=$(BUILD)/boot-x86_64.img $(POWER) tools/boottest.sh x86_64
	NAME=aarch64-power DISK=$(BUILD)/boot-aarch64.img $(POWER) tools/boottest.sh aarch64 -machine gic-version=3
	python3 -I tools/mkdisk.py $(BUILD)/system-other/esp $(BUILD)/other.img
	python3 -I tools/mkdisk.py $(BUILD)/system-broken/esp $(BUILD)/broken.img
	NAME=x86_64-upgrade DISK=$(BUILD)/boot-x86_64.img SESSION=tools/upgrade.txt TIMEOUT=300 $(UPGRADED) \
		tools/boottest.sh x86_64 $(call SECOND,other)
	rm -rf $(BUILD)/at-once
	cp -R $(BUILD)/system-other/esp $(BUILD)/at-once
	touch $(BUILD)/at-once/clara/at-once
	python3 -I tools/mkdisk.py $(BUILD)/at-once $(BUILD)/at-once.img
	NAME=aarch64-at-once SESSION=tools/at-once.txt TIMEOUT=300 \
		EXPECT='^system: .*-other is taken from another disk;;^ClaraOS: starting the system that is to be tried;;^system: .*-other has come to its prompt;;^world: every function and every variable that the world before had is defined in this one;;^world: it is saved as it is now' \
		tools/boottest.sh aarch64 -machine gic-version=3 $(call SECOND,at-once)
	NAME=aarch64-trial DISK=$(BUILD)/boot-aarch64.img SESSION=tools/trial.txt TIMEOUT=300 PANICS=1 \
		EXPECT='^system: .*-broken was tried and did not come to its prompt;;^lisp: clara.image is passed over;;^world:   It is kept, and the next start tries it once more;;^world: the world that was saved did not come to its prompt a second time' \
		tools/boottest.sh aarch64 -machine gic-version=3 $(call SECOND,broken)
	rm -rf $(BUILD)/releases $(BUILD)/release-key $(BUILD)/certs $(BUILD)/trusted
	python3 -I tools/release.py key $(BUILD)/release-key > $(BUILD)/release-key.public
	python3 -I tools/release.py make $(BUILD)/system-other/esp/clara/$(VERSION)-other $(BUILD)/releases $(BUILD)/release-key
	python3 -I tools/certs.py $(BUILD)/certs releases.test rsa.test:rsa large.test:large old.test:old six.test
	mkdir -p $(BUILD)/trusted && cp $(BUILD)/certs/root.pem $(BUILD)/trusted/ && python3 -I tools/mkdisk.py $(BUILD)/trusted $(BUILD)/trusted.img
	NAME=aarch64-network SERVE=$(BUILD)/releases CERTS=$(BUILD)/certs WORK=$(BUILD)/trusted.img KEY=$$(cat $(BUILD)/release-key.public) \
		SESSION=tools/network.txt TIMEOUT=300 \
		EXPECT='^random: .* makes numbers that nobody can guess;;^ClaraOS: starting the system that is to be tried;;^system: .*-other has come to its prompt;;^world: 1 variable has the value that it had come to;;^world: it is saved as it is now' \
		tools/boottest.sh aarch64 -machine gic-version=3
	python3 -I site/build.py --sessions $(BUILD)
	rm -rf $(BUILD)/empty && mkdir -p $(BUILD)/empty && python3 -I tools/mkdisk.py $(BUILD)/empty $(BUILD)/work.img
	NAME=manual WORK=$(BUILD)/work.img SESSION=$(BUILD)/manual-first.txt tools/boottest.sh aarch64 -machine gic-version=3
	NAME=manual-again DISK=$(BUILD)/boot-manual.img WORK=$(BUILD)/work-manual.img SESSION=$(BUILD)/manual-again.txt \
		EXPECT='^lisp: the heap is an image;;^lisp:   of the functions .* and 0 are walked' \
		tools/boottest.sh aarch64 -machine gic-version=3
	NAME=x86_64-objects SESSION=tools/objects.txt tools/boottest.sh x86_64
	NAME=aarch64-stress SESSION=tools/stress.txt TIMEOUT=900 DISK=$(BUILD)/boot-aarch64.img SPOIL=1 \
		EXPECT='^lisp: clara.image is not resumed: it is not what was saved;;^lisp: a collection at every safe point: boot.lisp once more in [0-9]\{4,\}, [0-9]* texts once more in [0-9]\{5,\};;^lisp: a collection at the safe points of compiled code, [0-9]* to a text: [0-9]* texts once more in [0-9]\{4,\};;^lisp: a collection at the safe points of code for the processor, [0-9]* to a text: [0-9]* texts in [0-9]\{3,\}' \
		tools/boottest.sh aarch64 -machine gic-version=3

image: all
	tools/mkimage.sh

# This build as a release: the system's directory laid out the way a web
# server hands it out (tools/release.py), as the newest release of the
# directory that RELEASES= names, and signed with the key in the file that
# KEY= names. It is what the website's workflow publishes at
# https://claraos.org/releases/ (.github/workflows/site.yml), which is
# where a ClaraOS looks for a newer one (lisp/system.lisp). The key has
# to be the one whose public half the system has in it, or nothing is laid
# out: no ClaraOS would take a release that another key signed, so there
# must be none to publish. And what was laid out is held against that half
# once more, the way a machine will hold it. PUBLIC= names another public
# half, for a key that was made for a test, which `make test` does.
PUBLIC := $(shell sed -n 's/^(defvar \*release-key\* "\([0-9a-f]*\)").*/\1/p' lisp/system.lisp)
release: all
	@[ -n "$(KEY)" ] && [ -n "$(RELEASES)" ] || { \
		echo "usage: make release KEY=<the file that holds the secret half of the key> RELEASES=<a directory>" >&2; exit 1; }
	@[ $$(printf %s "$(PUBLIC)" | wc -c) -eq 64 ] || { \
		echo "make release: lisp/system.lisp has no public half of a key where the Makefile reads it, 64 digits, so there is nothing to hold the key against" >&2; exit 1; }
	python3 -I tools/release.py make $(BOOTDIR) $(RELEASES) $(KEY) "$(PUBLIC)"
	python3 -I tools/release.py verify "$(PUBLIC)" $(RELEASES)/$(SYSTEM)/manifest $(RELEASES)/$(SYSTEM)/manifest.sig

# `make release` as the website's workflow runs it, with a key that is made
# for the purpose, since the workflow has its key from an environment that
# only main deploys to and so cannot be tried anywhere else. Told that the
# public half of that key is the one to go by, it has to lay the build out
# as a release that names this system. Left to read the half that the
# system has, it has to refuse the key for not being that one, and to lay
# nothing out. `make test` begins with it. The make that it calls has
# another name here than the one that make knows its own by: a line with
# that name in it is run even when make was asked to run nothing and to
# say what it would (-n), and what these lines look at is not there then.
AGAIN = $(MAKE) --no-print-directory
release-test: all
	rm -rf $(BUILD)/try-key $(BUILD)/published $(BUILD)/refused
	python3 -I tools/release.py key $(BUILD)/try-key > $(BUILD)/try-key.public
	$(AGAIN) release KEY=$(BUILD)/try-key PUBLIC=$$(cat $(BUILD)/try-key.public) RELEASES=$(BUILD)/published
	[ "$$(cat $(BUILD)/published/latest)" = "$(SYSTEM)" ]
	if $(AGAIN) release KEY=$(BUILD)/try-key RELEASES=$(BUILD)/refused > $(BUILD)/release-refused.log 2>&1 \
		|| ! grep -q "and not \"$(PUBLIC)\", which is the one to hold it against" $(BUILD)/release-refused.log \
		|| [ -e $(BUILD)/refused ]; then \
		cat $(BUILD)/release-refused.log; \
		echo "make release: a key that is not the one which the system has was not refused for being that, or something was laid out with it"; \
		exit 1; fi

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
