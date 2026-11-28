/* fontcheck.c: what FreeType makes of a font file
 *
 * usage: fontcheck facts <file>...
 *        fontcheck shades <file> <size> <first code> <last code>
 *        fontcheck points <file> [<glyph>]
 *        fontcheck colours <file>...
 *
 * lisp/type.lisp reads TrueType files and makes pictures of their glyphs,
 * and nobody here wrote FreeType, which does the same: this is the second
 * opinion. It is a program for the computer that ClaraOS is built on, not
 * a part of the build and not run by `make test`:
 *
 *     cc -o build/fontcheck tools/fontcheck.c $(pkg-config --cflags --libs freetype2)
 *     build/fontcheck facts fonts/Go-Regular.ttf fonts/Go-Bold.ttf
 *
 * `facts` prints, for each file, a row of the table FONT-FACTS in
 * lisp/host/tests.lisp: what the file says of itself, and three sums, over
 * the glyph of every character from 0 to 65535, over how far every glyph
 * moves on, and over every point of every outline, each counted the way
 * `sum` below counts. The host tests work the same sums out from what
 * lisp/type.lisp reads, so a new file in fonts/ gets its row from here, and
 * a row that the tests do not come to means that the two readers disagree
 * about some glyph of that file.
 *
 * `shades` prints the picture of each glyph as FreeType draws it at a
 * size, with nothing fitted to the pixels: where its upper left corner
 * lies from the place of the character on the baseline, how large it is,
 * how far the glyph moves on in 64ths of a pixel, and its shades, a row to
 * the line. That is for holding the pictures of lisp/type.lisp against,
 * pixel by pixel, by hand (ROADMAP.md says what came of it).
 *
 * `points` is for finding the glyph that the two disagree about: the
 * outline of one glyph, a contour to the line, each point as it is across
 * and up and whether the contour goes through it; or, without a glyph, the
 * sum over the points of each glyph by itself.
 *
 * `colours` prints, for each file, a row of the table FONT-COLOURS in
 * lisp/host/tests.lisp: how many of its glyphs are pictures in colours,
 * how many layers those have between them, and a sum over every such glyph
 * in the order of their numbers: its number, then for each of its layers
 * the layer's glyph, the number of its colour, and unless that is 65535,
 * the colour of the text, the colour itself, its red, green and blue as
 * one number, and how much of it shows. The colours are those of the
 * file's first palette.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_TRUETYPE_TABLES_H
#include FT_COLOR_H

#define MODULUS 1000000007ULL

/* One more number in a sum: what there was times 1000003, and the number,
 * which may be negative, with 100000 added. */
static unsigned long long sum(unsigned long long so_far, long number)
{
    return (so_far * 1000003ULL + (unsigned long long)(number + 100000)) % MODULUS;
}

static void facts(FT_Library library, const char *file)
{
    FT_Face face;
    const char *name = strrchr(file, '/');
    TT_HoriHeader *hhea;
    TT_Postscript *post;
    TT_OS2 *os2;
    unsigned long long characters = 0, advances = 0, outlines = 0;

    if (FT_New_Face(library, file, 0, &face)) {
        fprintf(stderr, "fontcheck: %s is no font to FreeType\n", file);
        exit(1);
    }
    hhea = FT_Get_Sfnt_Table(face, FT_SFNT_HHEA);
    post = FT_Get_Sfnt_Table(face, FT_SFNT_POST);
    os2 = FT_Get_Sfnt_Table(face, FT_SFNT_OS2);
    for (FT_ULong code = 0; code < 65536; code++)
        characters = sum(characters, (long)FT_Get_Char_Index(face, code));
    for (FT_Long glyph = 0; glyph < face->num_glyphs; glyph++) {
        FT_Outline *outline;
        int first = 0;

        if (FT_Load_Glyph(face, (FT_UInt)glyph, FT_LOAD_NO_SCALE | FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP)) {
            fprintf(stderr, "fontcheck: FreeType does not load the glyph %ld of %s\n", glyph, file);
            exit(1);
        }
        advances = sum(advances, face->glyph->metrics.horiAdvance);
        outline = &face->glyph->outline;
        outlines = sum(outlines, outline->n_contours);
        for (int c = 0; c < outline->n_contours; c++) {
            int last = outline->contours[c];

            outlines = sum(outlines, last + 1 - first);
            for (int p = first; p <= last; p++) {
                outlines = sum(outlines, outline->points[p].x);
                outlines = sum(outlines, outline->points[p].y);
                outlines = sum(outlines, outline->tags[p] & 1);
            }
            first = last + 1;
        }
    }
    printf("    (\"%s\" %d %ld %d %d %d %d %d %d %d %llu %llu %llu)\n", name ? name + 1 : file, face->units_per_EM,
           face->num_glyphs, hhea->Ascender, hhea->Descender, hhea->Line_Gap, post ? post->underlinePosition : 0,
           post ? post->underlineThickness : 0, os2 ? os2->yStrikeoutPosition : 0, os2 ? os2->yStrikeoutSize : 0,
           characters, advances, outlines);
    FT_Done_Face(face);
}

static void shades(FT_Library library, const char *file, int size, long first, long last)
{
    FT_Face face;

    if (FT_New_Face(library, file, 0, &face) || FT_Set_Pixel_Sizes(face, 0, (FT_UInt)size)) {
        fprintf(stderr, "fontcheck: FreeType cannot have %s at %d pixels\n", file, size);
        exit(1);
    }
    for (long code = first; code <= last; code++) {
        FT_GlyphSlot slot = face->glyph;

        if (FT_Load_Char(face, (FT_ULong)code, FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP | FT_LOAD_RENDER)) {
            fprintf(stderr, "fontcheck: FreeType does not draw the character %ld of %s\n", code, file);
            exit(1);
        }
        printf("%ld %d %d %u %u %ld\n", code, slot->bitmap_left, -slot->bitmap_top, slot->bitmap.width, slot->bitmap.rows,
               (long)slot->advance.x);
        for (unsigned y = 0; y < slot->bitmap.rows; y++) {
            for (unsigned x = 0; x < slot->bitmap.width; x++)
                printf("%s%u", x ? " " : "", slot->bitmap.buffer[y * (unsigned)slot->bitmap.pitch + x]);
            printf("\n");
        }
    }
    FT_Done_Face(face);
}

static void points(FT_Library library, const char *file, long only)
{
    FT_Face face;

    if (FT_New_Face(library, file, 0, &face)) {
        fprintf(stderr, "fontcheck: %s is no font to FreeType\n", file);
        exit(1);
    }
    for (FT_Long glyph = only < 0 ? 0 : only; glyph < (only < 0 ? face->num_glyphs : only + 1); glyph++) {
        FT_Outline *outline;
        unsigned long long outlines = 0;
        int first = 0;

        if (FT_Load_Glyph(face, (FT_UInt)glyph, FT_LOAD_NO_SCALE | FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP)) {
            fprintf(stderr, "fontcheck: FreeType does not load the glyph %ld of %s\n", glyph, file);
            exit(1);
        }
        outline = &face->glyph->outline;
        outlines = sum(outlines, outline->n_contours);
        for (int c = 0; c < outline->n_contours; c++) {
            int last = outline->contours[c];

            outlines = sum(outlines, last + 1 - first);
            for (int p = first; p <= last; p++) {
                outlines = sum(outlines, outline->points[p].x);
                outlines = sum(outlines, outline->points[p].y);
                outlines = sum(outlines, outline->tags[p] & 1);
                if (only >= 0)
                    printf("%s(%ld %ld %s)", p > first ? " " : "", outline->points[p].x, outline->points[p].y,
                           outline->tags[p] & 1 ? "T" : "NIL");
            }
            if (only >= 0)
                printf("\n");
            first = last + 1;
        }
        if (only < 0)
            printf("%ld %llu\n", glyph, outlines);
    }
    FT_Done_Face(face);
}

static void colours(FT_Library library, const char *file)
{
    FT_Face face;
    const char *name = strrchr(file, '/');
    FT_Color *palette = NULL;
    unsigned long long total = 0;
    long pictures = 0, layers = 0;

    if (FT_New_Face(library, file, 0, &face)) {
        fprintf(stderr, "fontcheck: FreeType cannot read %s\n", file);
        exit(1);
    }
    if (FT_Palette_Select(face, 0, &palette))
        palette = NULL;
    for (FT_UInt glyph = 0; glyph < (FT_UInt)face->num_glyphs; glyph++) {
        FT_LayerIterator iterator;
        FT_UInt layer, colour;
        int first = 1;

        iterator.p = NULL;
        while (FT_Get_Color_Glyph_Layer(face, glyph, &layer, &colour, &iterator)) {
            if (first) {
                total = sum(total, (long)glyph);
                pictures++;
                first = 0;
            }
            total = sum(total, (long)layer);
            total = sum(total, (long)colour);
            if (colour != 0xFFFF && palette) {
                total = sum(total, ((long)palette[colour].red << 16) | ((long)palette[colour].green << 8) | palette[colour].blue);
                total = sum(total, palette[colour].alpha);
            }
            layers++;
        }
    }
    printf("    (\"%s\" %ld %ld %llu)\n", name ? name + 1 : file, pictures, layers, total);
    FT_Done_Face(face);
}

int main(int argc, char **argv)
{
    FT_Library library;

    if (FT_Init_FreeType(&library))
        return 1;
    if (argc >= 3 && !strcmp(argv[1], "facts"))
        for (int i = 2; i < argc; i++)
            facts(library, argv[i]);
    else if (argc >= 3 && !strcmp(argv[1], "colours"))
        for (int i = 2; i < argc; i++)
            colours(library, argv[i]);
    else if (argc == 6 && !strcmp(argv[1], "shades"))
        shades(library, argv[2], atoi(argv[3]), atol(argv[4]), atol(argv[5]));
    else if ((argc == 3 || argc == 4) && !strcmp(argv[1], "points"))
        points(library, argv[2], argc == 4 ? atol(argv[3]) : -1);
    else {
        fprintf(stderr, "usage: fontcheck facts <file>...\n       fontcheck shades <file> <size> <first code> <last code>\n"
                        "       fontcheck points <file> [<glyph>]\n       fontcheck colours <file>...\n");
        return 2;
    }
    return 0;
}
