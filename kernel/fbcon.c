/* Text console on the framebuffer: a grid of character cells drawn with an
 * 8x16 bitmap font. It prints the boot report, and the kernel's last words
 * when something goes wrong. In between the screen belongs to the console
 * that is written in Lisp (lisp/console.lisp), which draws the same cells
 * in the same places: all that the two hand each other is where the next
 * character goes. So neither remembers what is on the screen, and both
 * scroll by moving the pixels up. */
#include "kernel.h"

#define MAX_COLS 256 /* fills a display up to 2048 pixels wide; a wider one gets a centred grid */
#define MAX_ROWS 128

static struct {
    struct framebuffer fb;
    uint32_t cols, rows;        /* grid size in cells; 0 until fbcon_init finds a display */
    uint32_t x0, y0;            /* top-left pixel of the grid */
    uint32_t col, row;          /* where the next character goes; col == cols means wrap first */
    uint8_t  color;             /* colour of the next character */
    int      lent;              /* somebody else draws on the screen for now */
    uint32_t paper;             /* background pixel */
    uint32_t ink[FBCON_COLORS]; /* foreground pixels */
} con;

/* An 8-bit colour channel, moved to the bits of a pixel that `mask` selects. */
static uint32_t channel(uint32_t mask, uint8_t value)
{
    unsigned shift = 0, bits = 0;

    if (!mask)
        return 0;
    while (!((mask >> shift) & 1))
        shift++;
    while (shift + bits < 32 && ((mask >> (shift + bits)) & 1))
        bits++;
    uint32_t v = bits >= 8 ? (uint32_t)value << (bits - 8) : (uint32_t)value >> (8 - bits);
    return v << shift;
}

static uint32_t pixel(uint32_t rgb) /* 0xRRGGBB */
{
    return channel(con.fb.red_mask, (uint8_t)(rgb >> 16)) |
           channel(con.fb.green_mask, (uint8_t)(rgb >> 8)) |
           channel(con.fb.blue_mask, (uint8_t)rgb);
}

static void draw_cell(uint32_t r, uint32_t c, char ch)
{
    const uint8_t *glyph = font_glyph(ch);
    uint32_t ink = con.ink[con.color];
    volatile uint32_t *line = con.fb.pixels +
                              (uint64_t)(con.y0 + r * FONT_HEIGHT) * con.fb.pitch +
                              con.x0 + c * FONT_WIDTH;

    for (int y = 0; y < FONT_HEIGHT; y++, line += con.fb.pitch)
        for (int x = 0; x < FONT_WIDTH; x++)
            line[x] = (glyph[y] & (0x80 >> x)) ? ink : con.paper;
}

/* Move every line up by one and blank the last: the scanlines of the grid,
 * each as wide as the screen. */
static void scroll(void)
{
    volatile uint32_t *top = con.fb.pixels + (uint64_t)con.y0 * con.fb.pitch;
    uint64_t line = (uint64_t)FONT_HEIGHT * con.fb.pitch, kept = (con.rows - 1) * line;

    for (uint64_t i = 0; i < kept; i++)
        top[i] = top[i + line];
    for (uint64_t i = kept; i < kept + line; i++)
        top[i] = con.paper;
}

static void newline(void)
{
    con.col = 0;
    if (con.row + 1 < con.rows)
        con.row++;
    else
        scroll();
}

void fbcon_putc(char c)
{
    if (!con.cols || con.lent)
        return;
    switch (c) {
    case '\n':
        newline();
        break;
    case '\r':
        con.col = 0;
        break;
    case '\b':
        if (con.col)
            con.col--;
        break;
    case '\t':
        do
            fbcon_putc(' ');
        while (con.col % 8 && con.col < con.cols);
        break;
    default:
        if (con.col == con.cols)
            newline();
        draw_cell(con.row, con.col++, c);
    }
}

static void clear(void)
{
    for (uint32_t y = 0; y < con.fb.height; y++) {
        volatile uint32_t *line = con.fb.pixels + (uint64_t)y * con.fb.pitch;
        for (uint32_t x = 0; x < con.fb.width; x++)
            line[x] = con.paper;
    }
    con.col = con.row = 0;
}

/* The alert colour is for the kernel's last words, a panic or the report
 * of a fault. If the screen is lent just then, it is taken back, and
 * cleared, because nobody here knows where the other console has left
 * off. */
void fbcon_set_color(enum fbcon_color color)
{
    con.color = (uint8_t)color;
    if (color == FBCON_ALERT && con.lent && con.cols) {
        con.lent = 0;
        clear();
    }
}

/* Somebody else draws on the screen from now on: where the next character
 * would have gone. Says 0 when there is no screen to lend. */
int fbcon_lend(uint32_t *row, uint32_t *column)
{
    if (!con.cols)
        return 0;
    con.lent = 1;
    *row = con.row;
    *column = con.col;
    return 1;
}

/* And has finished: the next character goes there. */
void fbcon_return(uint32_t row, uint32_t column)
{
    if (!con.cols)
        return;
    con.row = row < con.rows ? row : con.rows - 1;
    con.col = column < con.cols ? column : con.cols;
    con.lent = 0;
}

void fbcon_init(const struct framebuffer *fb)
{
    uint32_t cols = fb->width / FONT_WIDTH, rows = fb->height / FONT_HEIGHT;

    if (!fb->pixels || !cols || !rows)
        return;
    con.fb = *fb;
    con.cols = cols < MAX_COLS ? cols : MAX_COLS;
    con.rows = rows < MAX_ROWS ? rows : MAX_ROWS;
    con.x0 = (fb->width - con.cols * FONT_WIDTH) / 2;
    con.y0 = (fb->height - con.rows * FONT_HEIGHT) / 2;
    con.color = FBCON_TEXT;
    con.paper = pixel(0x1e1b2e);
    con.ink[FBCON_TEXT] = pixel(0xe8e3f4);
    con.ink[FBCON_ACCENT] = pixel(0xff79c6);
    con.ink[FBCON_ALERT] = pixel(0xff5555);
    clear();
}
