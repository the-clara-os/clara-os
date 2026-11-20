/* What this system is called: its version and eight digits that are worked
 * out from its sources, which the build hands over (the Makefile,
 * tools/system.py). The Lisp files of a system are on the boot volume in a
 * directory of this name, \clara\<name>, and that is where the handoff
 * looks for them (boot.c): a kernel only ever starts with the files that
 * it was built with, whatever else the volume holds, and a newer system
 * can be put beside the one that is running. */
#include "kernel.h"

const char clara_system[] = CLARA_SYSTEM;
