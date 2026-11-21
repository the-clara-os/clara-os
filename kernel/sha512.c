/* SHA-512: sixty-four bytes that stand for any number of bytes, so that
 * two files which have the same sixty-four are taken for the same file
 * (FIPS 180-4, the Secure Hash Standard). A system says what its files
 * have to be by this sum of each, and whoever takes a system from somewhere
 * else holds every file against its sum before anything is made of it
 * (lisp/system.lisp). It is here, in C, because a megabyte of it is a few
 * million rounds of sixty-four-bit arithmetic, where Lisp has integers of
 * sixty-one bits. */
#include "kernel.h"

/* The first sixty-four bits after the point of the cube roots of the first
 * eighty primes, and of the square roots of the first eight (4.2.3, 5.3.5). */
static const uint64_t K[80] = {
    0x428a2f98d728ae22ULL, 0x7137449123ef65cdULL, 0xb5c0fbcfec4d3b2fULL, 0xe9b5dba58189dbbcULL,
    0x3956c25bf348b538ULL, 0x59f111f1b605d019ULL, 0x923f82a4af194f9bULL, 0xab1c5ed5da6d8118ULL,
    0xd807aa98a3030242ULL, 0x12835b0145706fbeULL, 0x243185be4ee4b28cULL, 0x550c7dc3d5ffb4e2ULL,
    0x72be5d74f27b896fULL, 0x80deb1fe3b1696b1ULL, 0x9bdc06a725c71235ULL, 0xc19bf174cf692694ULL,
    0xe49b69c19ef14ad2ULL, 0xefbe4786384f25e3ULL, 0x0fc19dc68b8cd5b5ULL, 0x240ca1cc77ac9c65ULL,
    0x2de92c6f592b0275ULL, 0x4a7484aa6ea6e483ULL, 0x5cb0a9dcbd41fbd4ULL, 0x76f988da831153b5ULL,
    0x983e5152ee66dfabULL, 0xa831c66d2db43210ULL, 0xb00327c898fb213fULL, 0xbf597fc7beef0ee4ULL,
    0xc6e00bf33da88fc2ULL, 0xd5a79147930aa725ULL, 0x06ca6351e003826fULL, 0x142929670a0e6e70ULL,
    0x27b70a8546d22ffcULL, 0x2e1b21385c26c926ULL, 0x4d2c6dfc5ac42aedULL, 0x53380d139d95b3dfULL,
    0x650a73548baf63deULL, 0x766a0abb3c77b2a8ULL, 0x81c2c92e47edaee6ULL, 0x92722c851482353bULL,
    0xa2bfe8a14cf10364ULL, 0xa81a664bbc423001ULL, 0xc24b8b70d0f89791ULL, 0xc76c51a30654be30ULL,
    0xd192e819d6ef5218ULL, 0xd69906245565a910ULL, 0xf40e35855771202aULL, 0x106aa07032bbd1b8ULL,
    0x19a4c116b8d2d0c8ULL, 0x1e376c085141ab53ULL, 0x2748774cdf8eeb99ULL, 0x34b0bcb5e19b48a8ULL,
    0x391c0cb3c5c95a63ULL, 0x4ed8aa4ae3418acbULL, 0x5b9cca4f7763e373ULL, 0x682e6ff3d6b2b8a3ULL,
    0x748f82ee5defb2fcULL, 0x78a5636f43172f60ULL, 0x84c87814a1f0ab72ULL, 0x8cc702081a6439ecULL,
    0x90befffa23631e28ULL, 0xa4506cebde82bde9ULL, 0xbef9a3f7b2c67915ULL, 0xc67178f2e372532bULL,
    0xca273eceea26619cULL, 0xd186b8c721c0c207ULL, 0xeada7dd6cde0eb1eULL, 0xf57d4f7fee6ed178ULL,
    0x06f067aa72176fbaULL, 0x0a637dc5a2c898a6ULL, 0x113f9804bef90daeULL, 0x1b710b35131c471bULL,
    0x28db77f523047d84ULL, 0x32caab7b40c72493ULL, 0x3c9ebe0a15c9bebcULL, 0x431d67c49c100d4cULL,
    0x4cc5d4becb3e42b6ULL, 0x597f299cfc657e2aULL, 0x5fcb6fab3ad6faecULL, 0x6c44198c4a475817ULL,
};

static const uint64_t initial[8] = {
    0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL, 0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL,
    0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL, 0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL,
};

/* SHA-384 is the same sum from another beginning, of which the first
 * forty-eight bytes are kept: the square roots of the ninth to the
 * sixteenth prime (5.3.4). Certificates are signed over it as often as
 * over SHA-256. */
static const uint64_t initial_384[8] = {
    0xcbbb9d5dc1059ed8ULL, 0x629a292a367cd507ULL, 0x9159015a3070dd17ULL, 0x152fecd8f70e5939ULL,
    0x67332667ffc00b31ULL, 0x8eb44a8768581511ULL, 0xdb0c2e0d64f98fa7ULL, 0x47b5481dbefa4fa4ULL,
};

static uint64_t rotate(uint64_t x, unsigned n)
{
    return x >> n | x << (64 - n);
}

/* One block of 128 bytes goes into the eight words of the sum so far (6.4.2). */
static void block(uint64_t h[8], const uint8_t *p)
{
    uint64_t w[80], a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], last = h[7];

    for (unsigned i = 0; i < 16; i++, p += 8)
        w[i] = (uint64_t)p[0] << 56 | (uint64_t)p[1] << 48 | (uint64_t)p[2] << 40 | (uint64_t)p[3] << 32 |
               (uint64_t)p[4] << 24 | (uint64_t)p[5] << 16 | (uint64_t)p[6] << 8 | p[7];
    for (unsigned i = 16; i < 80; i++)
        w[i] = w[i - 16] + (rotate(w[i - 15], 1) ^ rotate(w[i - 15], 8) ^ w[i - 15] >> 7) + w[i - 7] +
               (rotate(w[i - 2], 19) ^ rotate(w[i - 2], 61) ^ w[i - 2] >> 6);
    for (unsigned i = 0; i < 80; i++) {
        uint64_t one = last + (rotate(e, 14) ^ rotate(e, 18) ^ rotate(e, 41)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
        uint64_t two = (rotate(a, 28) ^ rotate(a, 34) ^ rotate(a, 39)) + ((a & b) ^ (a & c) ^ (b & c));

        last = g, g = f, f = e, e = d + one, d = c, c = b, b = a, a = one + two;
    }
    h[0] += a, h[1] += b, h[2] += c, h[3] += d, h[4] += e, h[5] += f, h[6] += g, h[7] += last;
}

/* A sum can be taken of bytes that come in pieces: begun, added to as
 * often as there is more, and ended. What does not fill a block waits in
 * the state for the piece that does. */
void sha512_begin(struct sha512_state *state)
{
    memcpy(state->h, initial, sizeof state->h);
    state->bytes = 0;
    state->held = 0;
}

/* The beginning of SHA-384: what is added and how it ends are SHA-512's,
 * and whoever ends it keeps the first forty-eight bytes. */
void sha384_begin(struct sha512_state *state)
{
    memcpy(state->h, initial_384, sizeof state->h);
    state->bytes = 0;
    state->held = 0;
}

void sha512_add(struct sha512_state *state, const void *data, uint64_t bytes)
{
    const uint8_t *p = data;

    state->bytes += bytes;
    if (state->held) {
        uint64_t fits = sizeof state->rest - state->held;

        if (fits > bytes)
            fits = bytes;
        memcpy(state->rest + state->held, p, fits);
        state->held += (unsigned)fits, p += fits, bytes -= fits;
        if (state->held < sizeof state->rest)
            return;
        block(state->h, state->rest);
        state->held = 0;
    }
    for (; bytes >= 128; bytes -= 128, p += 128)
        block(state->h, p);
    memcpy(state->rest, p, bytes);
    state->held = (unsigned)bytes;
}

/* After the bytes comes a byte of 0x80, zeroes up to sixteen bytes short
 * of a block's end, and how many bits there were, in those sixteen bytes,
 * of which only the lower eight can be anything but zero here (5.1.2). */
void sha512_end(struct sha512_state *state, uint8_t sum[64])
{
    uint8_t end[256] = {0};
    unsigned left = state->held, length = left < 112 ? 128 : 256;

    memcpy(end, state->rest, left);
    end[left] = 0x80;
    for (unsigned i = 0; i < 8; i++)
        end[length - 1 - i] = (uint8_t)(state->bytes << 3 >> (8 * i));
    end[length - 9] = (uint8_t)(state->bytes >> 61);
    block(state->h, end);
    if (length == 256)
        block(state->h, end + 128);
    for (unsigned i = 0; i < 64; i++)
        sum[i] = (uint8_t)(state->h[i / 8] >> (56 - 8 * (i % 8)));
}

/* The sum of that many bytes. */
void sha512(const void *data, uint64_t bytes, uint8_t sum[64])
{
    struct sha512_state state;

    sha512_begin(&state);
    sha512_add(&state, data, bytes);
    sha512_end(&state, sum);
}

/* The sums that the standard's own examples have: of nothing, of "abc",
 * and of a text of 896 bits, which takes two blocks; and of a text that
 * ends a block exactly, and one that leaves no room in its last block for
 * the count. */
void sha512_selftest(void)
{
    static const struct {
        const char *text;
        uint8_t first[8];
    } known[] = {
        { "", { 0xcf, 0x83, 0xe1, 0x35, 0x7e, 0xef, 0xb8, 0xbd } },
        { "abc", { 0xdd, 0xaf, 0x35, 0xa1, 0x93, 0x61, 0x7a, 0xba } },
        { "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
          { 0x8e, 0x95, 0x9b, 0x75, 0xda, 0xe3, 0x13, 0xda } },
    };
    static const uint8_t ends[2][8] = { /* of 128 and of 120 bytes that are all 'a' */
        { 0xb7, 0x3d, 0x19, 0x29, 0xaa, 0x61, 0x59, 0x34 },
        { 0xf2, 0x41, 0xde, 0x61, 0x2b, 0x01, 0xaa, 0x2f },
    };
    uint8_t sum[64], many[128];

    for (unsigned i = 0; i < sizeof known / sizeof known[0]; i++) {
        sha512(known[i].text, strlen(known[i].text), sum);
        if (memcmp(sum, known[i].first, 8))
            panic("sha-512 self-test: the sum of \"%s\" is not what the standard has", known[i].text);
    }
    /* SHA-384 of "abc": its first eight bytes and its last, the forty-eighth among them. */
    {
        static const uint8_t first[8] = { 0xcb, 0x00, 0x75, 0x3f, 0x45, 0xa3, 0x5e, 0x8b }, last[8] = { 0x58, 0xba, 0xec, 0xa1, 0x34, 0xc8, 0x25, 0xa7 };
        struct sha512_state state;

        sha384_begin(&state);
        sha512_add(&state, "abc", 3);
        sha512_end(&state, sum);
        if (memcmp(sum, first, 8) || memcmp(sum + 40, last, 8))
            panic("sha-512 self-test: the SHA-384 of \"abc\" is not what the standard has");
    }
    memset(many, 'a', sizeof many);
    for (unsigned i = 0; i < 2; i++) {
        sha512(many, i ? 120 : 128, sum);
        if (memcmp(sum, ends[i], 8))
            panic("sha-512 self-test: the sum of %u bytes is wrong, where the padding goes into a block of its own",
                  i ? 120u : 128u);
    }
    /* Three hundred bytes, which are more than two blocks, in pieces that end before a block does,
     * at its end and after it: the sum is the one of all of them at once. */
    {
        static const unsigned pieces[] = { 1, 7, 100, 127, 128, 129, 200 };
        uint8_t all[300], whole[64];

        for (unsigned i = 0; i < sizeof all; i++)
            all[i] = (uint8_t)(i * 7 + 3);
        sha512(all, sizeof all, whole);
        for (unsigned k = 0; k < sizeof pieces / sizeof pieces[0]; k++) {
            struct sha512_state state;
            unsigned at = 0;

            sha512_begin(&state);
            sha512_add(&state, all, 5); /* so that every piece after this one finds something waiting */
            for (at = 5; at < sizeof all; at += pieces[k])
                sha512_add(&state, all + at, sizeof all - at < pieces[k] ? sizeof all - at : pieces[k]);
            sha512_end(&state, sum);
            if (memcmp(sum, whole, 64))
                panic("sha-512 self-test: the sum of 300 bytes in pieces of %u is not the sum of the 300", pieces[k]);
        }
    }
    /* The same bytes in pieces of every length, each from an empty piece to a block and some more. */
    for (unsigned piece = 1; piece < 131; piece += 13) {
        struct sha512_state state;
        const char *text = known[2].text;
        uint64_t left = strlen(text);

        sha512_begin(&state);
        sha512_add(&state, text, 0);
        for (; left; text += left < piece ? left : piece, left -= left < piece ? left : piece)
            sha512_add(&state, text, left < piece ? left : piece);
        sha512_end(&state, sum);
        if (memcmp(sum, known[2].first, 8))
            panic("sha-512 self-test: the sum of a text in pieces of %u bytes is not the sum of the text", piece);
    }
}
