/* Text console on the framebuffer: a grid of character cells drawn with an
 * 8x16 bitmap font. The grid is remembered in con.cells, so scrolling never
 * reads the framebuffer back and repaints only the cells that changed. */
#include "kernel.h"

#define MAX_COLS 256 /* fills a display up to 2048 pixels wide; a wider one gets a centred grid */
#define MAX_ROWS 128

struct cell {
    char    ch;
    uint8_t color; /* enum fbcon_color */
};

static struct {
    struct framebuffer fb;
    uint32_t cols, rows;        /* grid size in cells; 0 until fbcon_init finds a display */
    uint32_t x0, y0;            /* top-left pixel of the grid */
    uint32_t col, row;          /* where the next character goes; col == cols means wrap first */
    uint8_t  color;             /* colour of the next character */
    uint32_t paper;             /* background pixel */
    uint32_t ink[FBCON_COLORS]; /* foreground pixels */
    struct cell cells[MAX_ROWS][MAX_COLS];
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

static void draw_cell(uint32_t r, uint32_t c)
{
    const uint8_t *glyph = font_glyph(con.cells[r][c].ch);
    uint32_t ink = con.ink[con.cells[r][c].color];
    volatile uint32_t *line = con.fb.pixels +
                              (uint64_t)(con.y0 + r * FONT_HEIGHT) * con.fb.pitch +
                              con.x0 + c * FONT_WIDTH;

    for (int y = 0; y < FONT_HEIGHT; y++, line += con.fb.pitch)
        for (int x = 0; x < FONT_WIDTH; x++)
            line[x] = (glyph[y] & (0x80 >> x)) ? ink : con.paper;
}

static void set_cell(uint32_t r, uint32_t c, char ch, uint8_t color)
{
    struct cell *at = &con.cells[r][c];

    if (ch == ' ')
        color = FBCON_TEXT; /* all blanks look alike */
    if (at->ch == ch && at->color == color)
        return;
    at->ch = ch;
    at->color = color;
    draw_cell(r, c);
}

/* Move every line up by one and blank the last. */
static void scroll(void)
{
    for (uint32_t r = 0; r + 1 < con.rows; r++)
        for (uint32_t c = 0; c < con.cols; c++)
            set_cell(r, c, con.cells[r + 1][c].ch, con.cells[r + 1][c].color);
    for (uint32_t c = 0; c < con.cols; c++)
        set_cell(con.rows - 1, c, ' ', FBCON_TEXT);
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
    if (!con.cols)
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
        set_cell(con.row, con.col++, c, con.color);
    }
}

void fbcon_set_color(enum fbcon_color color)
{
    con.color = (uint8_t)color;
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
    con.col = con.row = 0;
    con.color = FBCON_TEXT;
    con.paper = pixel(0x1e1b2e);
    con.ink[FBCON_TEXT] = pixel(0xe8e3f4);
    con.ink[FBCON_ACCENT] = pixel(0xff79c6);
    con.ink[FBCON_ALERT] = pixel(0xff5555);

    for (uint32_t y = 0; y < fb->height; y++) {
        volatile uint32_t *line = fb->pixels + (uint64_t)y * fb->pitch;
        for (uint32_t x = 0; x < fb->width; x++)
            line[x] = con.paper;
    }
    for (uint32_t r = 0; r < con.rows; r++)
        for (uint32_t c = 0; c < con.cols; c++)
            con.cells[r][c] = (struct cell){ ' ', FBCON_TEXT };
}
