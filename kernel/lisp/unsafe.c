/* The package CLARA.UNSAFE: what a driver written in Lisp needs and no
 * other program should have. Memory by its address, the I/O ports of the
 * machines that have them, page frames of its own, and the facts about
 * the machine that the firmware gave the substrate at boot.
 *
 * Lisp cannot make a pointer of an integer, and that is what keeps one
 * program out of another's objects, there being no page tables between
 * them (DESIGN.md). These functions are the exception, all of it in one
 * package, so that who uses it can be found by looking for its name. A
 * mistake here is a mistake in the kernel: a write through a wrong address
 * lands wherever that address is, in an object or in a page table.
 *
 * One mistake is caught, because it is the commonest and costs little to
 * look for: an address where nothing is mapped is an error, not a fault
 * that stops the machine. A write to memory that is mapped read-only still
 * is one.
 *
 * Interrupts reach Lisp as events (thread.c): INTERRUPT-EVENT gives the
 * event that a source of interrupts signals, and a thread waits for it
 * like for any other. */
#include "acpi.h"
#include "lisp.h"

#define NIL LISP_NIL
#define T   lisp_roots.t

static const struct framebuffer *g_screen;

void lisp_unsafe_init(const struct framebuffer *fb)
{
    g_screen = fb;
}

/* An address, a count or a port from Lisp: an integer that is not
 * negative. Says 0 after failing. */
static int number(lisp x, uint64_t *n)
{
    if (!lisp_is_fixnum(x) || lisp_fixnum_value(x) < 0) {
        lisp_wants("an integer that is not negative", x);
        return 0;
    }
    *n = (uint64_t)lisp_fixnum_value(x);
    return 1;
}

/* Is something mapped at every one of that many bytes from addr on? Says
 * 0 after failing. Whether it can be written is not looked at. */
static int mapped(uint64_t addr, uint64_t bytes)
{
    uint64_t page = addr & ~(PAGE_SIZE - 1);

    if (!bytes)
        return 1;
    if (addr + bytes < addr || addr + bytes > 1ULL << 48) {
        lisp_fail("there is no memory at ~X: an address has 48 bits", lisp_fixnum((int64_t)addr));
        return 0;
    }
    for (; page < addr + bytes; page += PAGE_SIZE)
        if (!vm_lookup(page)) {
            lisp_fail("nothing is mapped at ~X", lisp_fixnum((int64_t)(page > addr ? page : addr)));
            return 0;
        }
    return 1;
}

/* An address for an access of that many bytes: it has to be a multiple
 * of them, as a device's registers and the processor's own tables are. */
static int place(lisp x, unsigned size, uint64_t *addr)
{
    if (!number(x, addr))
        return 0;
    if (*addr % size) {
        lisp_fail("~X is not the address of ~A bytes: it is not a multiple of ~A", x, lisp_fixnum(size),
                  lisp_fixnum(size));
        return 0;
    }
    return mapped(*addr, size);
}

/* Raw memory, read. What is there is taken for an integer that is not
 * negative; 64 bits that do not fit in a fixnum are an error. */
static lisp peek(lisp x, unsigned size)
{
    uint64_t addr, value;

    if (!place(x, size, &addr))
        return NIL;
    switch (size) {
    case 1:
        value = *(volatile uint8_t *)(uintptr_t)addr;
        break;
    case 2:
        value = *(volatile uint16_t *)(uintptr_t)addr;
        break;
    case 4:
        value = *(volatile uint32_t *)(uintptr_t)addr;
        break;
    default:
        value = *(volatile uint64_t *)(uintptr_t)addr;
    }
    if (value > (uint64_t)LISP_FIXNUM_MAX)
        return lisp_fail_as("ARITHMETIC-ERROR", NULL, 0,
                            "the 64 bits at ~X are an integer too large for a fixnum: read them as two halves", x);
    return lisp_fixnum((int64_t)value);
}

/* An integer that fits in that many bytes, as it stands or as the two's
 * complement of a negative one. Says 0 after failing. */
static int fits(lisp x, unsigned size, uint64_t *value)
{
    int64_t n = lisp_fixnum_value(x);

    if (!lisp_is_fixnum(x) || (size < 8 && (n >= (int64_t)1 << (8 * size) || n < -((int64_t)1 << (8 * size - 1))))) {
        lisp_fail("~S is not an integer that fits in ~A bits", x, lisp_fixnum(8 * size));
        return 0;
    }
    *value = (uint64_t)n;
    return 1;
}

static lisp poke(lisp x, lisp new, unsigned size)
{
    uint64_t addr, value;

    if (!fits(new, size, &value) || !place(x, size, &addr))
        return NIL;
    switch (size) {
    case 1:
        *(volatile uint8_t *)(uintptr_t)addr = (uint8_t)value;
        break;
    case 2:
        *(volatile uint16_t *)(uintptr_t)addr = (uint16_t)value;
        break;
    case 4:
        *(volatile uint32_t *)(uintptr_t)addr = (uint32_t)value;
        break;
    default:
        *(volatile uint64_t *)(uintptr_t)addr = value;
    }
    return new;
}

#define ACCESS(bits) \
    LISP_PRIMITIVE(lisp_p_memory_##bits) \
    { \
        (void)argc; \
        return peek(argv[0], bits / 8); \
    } \
    LISP_PRIMITIVE(lisp_p_set_memory_##bits) \
    { \
        (void)argc; \
        return poke(argv[0], argv[1], bits / 8); \
    }
ACCESS(8)
ACCESS(16)
ACCESS(32)
ACCESS(64)

/* (fill-memory-32 address count value): that many 32-bit words, all the same. */
LISP_PRIMITIVE(lisp_p_fill_memory_32)
{
    uint64_t addr, count, value;
    volatile uint32_t *at;

    (void)argc;
    if (!number(argv[1], &count) || !fits(argv[2], 4, &value) || !place(argv[0], 4, &addr) ||
        !mapped(addr, count * 4))
        return NIL;
    at = (volatile uint32_t *)(uintptr_t)addr;
    while (count--)
        *at++ = (uint32_t)value;
    return NIL;
}

/* (copy-memory to from bytes): the two may overlap. Eight bytes at a time
 * where the addresses allow it, which is what scrolling a screen wants. */
LISP_PRIMITIVE(lisp_p_copy_memory)
{
    uint64_t to, from, bytes;

    (void)argc;
    if (!number(argv[0], &to) || !number(argv[1], &from) || !number(argv[2], &bytes) || !mapped(to, bytes) ||
        !mapped(from, bytes))
        return NIL;
    if ((to | from | bytes) % 8 || (to > from && to < from + bytes))
        memmove((void *)(uintptr_t)to, (const void *)(uintptr_t)from, bytes);
    else {
        uint64_t *d = (uint64_t *)(uintptr_t)to;
        const uint64_t *s = (const uint64_t *)(uintptr_t)from;

        for (bytes /= 8; bytes--;)
            *d++ = *s++;
    }
    return NIL;
}

/* (expand-bits-32 address pitch bits start rows width one zero): a bitmap
 * of one bit to the pixel becomes 32-bit pixels. The rows of the bitmap
 * are items of the vector bits, from start on, each an integer whose
 * lowest width bits are the row, the leftmost pixel in the highest of
 * them. A row of pixels begins pitch bytes after the one before. A pixel
 * is the word one where the bit is set and the word zero where it is not.
 * This is how a character of a bitmap font gets on the screen in one call. */
LISP_PRIMITIVE(lisp_p_expand_bits_32)
{
    uint64_t addr, pitch, start, rows, width, one, zero;
    const struct lisp_vector *bits = lisp_as_vector(argv[2]);

    (void)argc;
    if (!lisp_is(argv[2], LISP_VECTOR))
        return lisp_wants("a vector of the rows of a bitmap", argv[2]);
    if (!number(argv[1], &pitch) || !number(argv[3], &start) || !number(argv[4], &rows) ||
        !number(argv[5], &width) || !fits(argv[6], 4, &one) || !fits(argv[7], 4, &zero) || !place(argv[0], 4, &addr))
        return NIL;
    if (width > 62 || pitch % 4 || pitch < width * 4)
        return lisp_fail("a row of ~A pixels does not fit in a fixnum, or in ~A bytes", argv[5], argv[1]);
    if (start + rows > lisp_length(bits->header))
        return lisp_fail("the bitmap has ~A rows, not the ~A from ~A on", lisp_fixnum((int64_t)lisp_length(bits->header)),
                         argv[4], argv[3]);
    if (rows && !mapped(addr, (rows - 1) * pitch + width * 4))
        return NIL;
    for (uint64_t r = 0; r < rows; r++) {
        volatile uint32_t *at = (volatile uint32_t *)(uintptr_t)(addr + r * pitch);
        uint64_t row = (uint64_t)lisp_fixnum_value(bits->items[start + r]);

        for (uint64_t x = 0; x < width; x++)
            at[x] = (uint32_t)(row >> (width - 1 - x) & 1 ? one : zero);
    }
    return NIL;
}

/* (allocate-memory pages): page frames side by side, all zeroes, for a
 * driver to share with its device; their address, which is their physical
 * address too. (free-memory address pages) gives them back, and trusts
 * that they came from here. */
LISP_PRIMITIVE(lisp_p_allocate_memory)
{
    uint64_t pages, memory;

    (void)argc;
    if (!number(argv[0], &pages))
        return NIL;
    if (!pages || pages > 1 << 20 || !lisp_heap_room(pages * PAGE_SIZE / sizeof(lisp)) || !(memory = pmm_alloc(pages)))
        return lisp_fail_as("STORAGE-CONDITION", NULL, 0, "there are no ~A page frames side by side to be had", argv[0]);
    memset(phys_ptr(memory), 0, pages * PAGE_SIZE);
    return lisp_fixnum((int64_t)memory);
}

LISP_PRIMITIVE(lisp_p_free_memory)
{
    uint64_t addr, pages;

    (void)argc;
    if (!number(argv[0], &addr) || !number(argv[1], &pages))
        return NIL;
    if (addr % PAGE_SIZE || !pages || !mapped(addr, pages * PAGE_SIZE))
        return lisp_fail("~X is not the address of ~A page frames", argv[0], argv[1]);
    pmm_free(addr, pages);
    return NIL;
}

/* I/O ports. */
static lisp port_in(lisp x, unsigned size)
{
    uint64_t port;
    uint32_t value;

    if (!number(x, &port))
        return NIL;
    if (port > 0xffff)
        return lisp_wants("the number of a port, which has 16 bits", x);
    if (!arch_port_read((uint16_t)port, size, &value))
        return lisp_fail("this machine has no I/O ports");
    return lisp_fixnum(value);
}

static lisp port_out(lisp x, lisp new, unsigned size)
{
    uint64_t port, value;

    if (!number(x, &port) || !fits(new, size, &value))
        return NIL;
    if (port > 0xffff)
        return lisp_wants("the number of a port, which has 16 bits", x);
    if (!arch_port_write((uint16_t)port, size, (uint32_t)value))
        return lisp_fail("this machine has no I/O ports");
    return new;
}

#define PORT(bits) \
    LISP_PRIMITIVE(lisp_p_port_##bits) \
    { \
        (void)argc; \
        return port_in(argv[0], bits / 8); \
    } \
    LISP_PRIMITIVE(lisp_p_set_port_##bits) \
    { \
        (void)argc; \
        return port_out(argv[0], argv[1], bits / 8); \
    }
PORT(8)
PORT(16)
PORT(32)

/* What the firmware said about the machine. (framebuffer): the address of
 * the screen's pixels, 32 bits each, its width and height in pixels, how
 * many bytes one row of them takes, and the bits of a pixel that hold red,
 * green and blue; or NIL when the machine has no screen. */
LISP_PRIMITIVE(lisp_p_framebuffer)
{
    (void)argc;
    (void)argv;
    if (!g_screen || !g_screen->pixels)
        return NIL;
    lisp_values.count = 7;
    lisp_values.value[0] = lisp_fixnum((int64_t)(uintptr_t)g_screen->pixels);
    lisp_values.value[1] = lisp_fixnum(g_screen->width);
    lisp_values.value[2] = lisp_fixnum(g_screen->height);
    lisp_values.value[3] = lisp_fixnum((int64_t)g_screen->pitch * 4);
    lisp_values.value[4] = lisp_fixnum(g_screen->red_mask);
    lisp_values.value[5] = lisp_fixnum(g_screen->green_mask);
    lisp_values.value[6] = lisp_fixnum(g_screen->blue_mask);
    return lisp_values.value[0];
}

/* (serial-device): what the serial port is, a keyword, and where: the
 * first of its I/O ports, or the address of its registers. */
LISP_PRIMITIVE(lisp_p_serial_device)
{
    (void)argc;
    (void)argv;
    lisp_values.count = 2;
    lisp_values.value[0] = lisp_symbol_in(lisp_roots.keyword, arch_serial_kind, 1);
    lisp_values.value[1] = lisp_fixnum((int64_t)arch_serial_base);
    return lisp_values.value[0];
}

/* (serial-byte): the next byte that was typed on the serial port, or NIL
 * when there is none. The timer's interrupt takes them in (console.c), and
 * signals the event of the source :SERIAL when it has. */
LISP_PRIMITIVE(lisp_p_serial_byte)
{
    int c = console_getc();

    (void)argc;
    (void)argv;
    return c < 0 ? NIL : lisp_fixnum(c);
}

/* (take-screen): the console in Lisp draws on the screen from now on, and
 * the substrate's own leaves it alone; the row and the column where that
 * one left off, or NIL when there is no screen. (give-screen row column)
 * hands it back, for the substrate's last line. Should the kernel have to
 * report a fault meanwhile, it takes the screen without asking. */
LISP_PRIMITIVE(lisp_p_take_screen)
{
    uint32_t row, column;

    (void)argc;
    (void)argv;
    if (!fbcon_lend(&row, &column))
        return NIL;
    lisp_values.count = 2;
    lisp_values.value[0] = lisp_fixnum(row);
    lisp_values.value[1] = lisp_fixnum(column);
    return lisp_values.value[0];
}

LISP_PRIMITIVE(lisp_p_give_screen)
{
    uint64_t row, column;

    (void)argc;
    if (!number(argv[0], &row) || !number(argv[1], &column))
        return NIL;
    fbcon_return((uint32_t)row, (uint32_t)column);
    return NIL;
}

/* (map-memory address bytes): the registers of a device, which the
 * firmware or the device's own configuration says are at that address, can
 * be read and written there from now on. The kernel maps a device where it
 * is, like everything else, so three places are refused: memory, which is
 * mapped already and is nobody's registers; the first megabyte; and what
 * lies where the heap of Lisp has its addresses. What is mapped already is
 * left as it is. */
LISP_PRIMITIVE(lisp_p_map_memory)
{
    uint64_t addr, bytes, first, end;

    (void)argc;
    if (!number(argv[0], &addr) || !number(argv[1], &bytes))
        return NIL;
    first = addr & ~(PAGE_SIZE - 1);
    end = (addr + bytes + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    if (!bytes || bytes > 256 << 20)
        return lisp_fail("~A bytes are not the registers of a device: there are some, and no more than 256 MiB", argv[1]);
    if (addr < LOW_LIMIT || end > VM_HEAP_BASE)
        return lisp_fail("the ~A bytes at ~X cannot be mapped: the kernel maps nothing below ~X, and from ~X on"
                         " the addresses are the heap's",
                         argv[1], argv[0], lisp_fixnum(LOW_LIMIT), lisp_fixnum((int64_t)VM_HEAP_BASE));
    for (uint64_t page = first; page < end; page += PAGE_SIZE)
        if (pmm_is_ram(page))
            return lisp_fail("~X is memory, not the registers of a device", lisp_fixnum((int64_t)page));
    for (uint64_t page = first; page < end; page += PAGE_SIZE)
        if (!vm_lookup(page))
            vm_map(page, page, 1, VM_WRITE | VM_DEVICE);
    return argv[0];
}

/* (pci-configuration): where the configuration space of the PCI devices is
 * in memory, by the firmware's table of it (ACPI MCFG). Three values: the
 * address at which bus 0 would begin, and the first and the last bus that
 * are there; each bus has a megabyte, each of its 32 devices 32 KiB, and
 * each of a device's 8 functions a page. NIL when the firmware names no
 * such place. Of several, this is the first of segment 0. */
LISP_PRIMITIVE(lisp_p_pci_configuration)
{
    const struct acpi_mcfg *mcfg = acpi_table("MCFG");
    uint64_t entries = mcfg && mcfg->header.length > sizeof *mcfg
                           ? (mcfg->header.length - sizeof *mcfg) / sizeof mcfg->entries[0]
                           : 0;

    (void)argc;
    (void)argv;
    for (uint64_t i = 0; i < entries; i++) {
        if (mcfg->entries[i].segment)
            continue;
        lisp_values.count = 3;
        lisp_values.value[0] = lisp_fixnum((int64_t)mcfg->entries[i].base);
        lisp_values.value[1] = lisp_fixnum(mcfg->entries[i].first_bus);
        lisp_values.value[2] = lisp_fixnum(mcfg->entries[i].last_bus);
        return lisp_values.value[0];
    }
    return NIL;
}

/* (keyboard-break): Ctrl-C has been typed on a keyboard. The driver of a
 * keyboard is a thread in Lisp, and this is how it does what the serial
 * port's Ctrl-C does: it stops what the thread that reads from the console
 * is computing, or the wait it is in. */
LISP_PRIMITIVE(lisp_p_keyboard_break)
{
    (void)argc;
    (void)argv;
    console_break_now();
    return NIL;
}

/* (memory-string address bytes): the text that those bytes of memory are,
 * as a string. Text outside the heap is UTF-8 (DESIGN.md), a file's on a
 * disk for one, and this is how its driver hands it to Lisp in one piece.
 * Bytes that are not UTF-8 are an error, which says where they stop being
 * it. */
LISP_PRIMITIVE(lisp_p_memory_string)
{
    uint64_t addr, bytes, text;

    (void)argc;
    if (!number(argv[0], &addr) || !number(argv[1], &bytes) || !mapped(addr, bytes))
        return NIL;
    text = lisp_utf8_length((const void *)(uintptr_t)addr, bytes);
    if (text != bytes)
        return lisp_fail("the ~A bytes at ~X are not text: after ~A of them they are no longer UTF-8", argv[1], argv[0],
                         lisp_fixnum((int64_t)text));
    if (!lisp_heap_room(1 + (bytes + 1) / 2)) /* a character to the byte at most */
        return lisp_fail_as("STORAGE-CONDITION", NULL, 0, "the heap is full: there is no room for ~A bytes of text",
                            argv[1]);
    return lisp_string_from_utf8((const void *)(uintptr_t)addr, bytes);
}
