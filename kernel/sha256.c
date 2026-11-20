/* SHA-256: thirty-two bytes that stand for any number of bytes (FIPS
 * 180-4, the Secure Hash Standard), the smaller brother of the sum in
 * sha512.c. A connection that TLS keeps closed is made of it: the two
 * sides agree on their keys by sums of what they have said to each other,
 * and most certificates are signed over such a sum (lisp/tls.lisp). It is
 * in C for the reason that the other one is. */
#include "kernel.h"

/* The first thirty-two bits after the point of the cube roots of the first
 * sixty-four primes, and of the square roots of the first eight (4.2.2, 5.3.3). */
static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

static const uint32_t initial[8] = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
};

static uint32_t rotate(uint32_t x, unsigned n)
{
    return x >> n | x << (32 - n);
}

/* One block of 64 bytes goes into the eight words of the sum so far (6.2.2). */
static void block(uint32_t h[8], const uint8_t *p)
{
    uint32_t w[64], a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], last = h[7];

    for (unsigned i = 0; i < 16; i++, p += 4)
        w[i] = (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
    for (unsigned i = 16; i < 64; i++)
        w[i] = w[i - 16] + (rotate(w[i - 15], 7) ^ rotate(w[i - 15], 18) ^ w[i - 15] >> 3) + w[i - 7] +
               (rotate(w[i - 2], 17) ^ rotate(w[i - 2], 19) ^ w[i - 2] >> 10);
    for (unsigned i = 0; i < 64; i++) {
        uint32_t one = last + (rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
        uint32_t two = (rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));

        last = g, g = f, f = e, e = d + one, d = c, c = b, b = a, a = one + two;
    }
    h[0] += a, h[1] += b, h[2] += c, h[3] += d, h[4] += e, h[5] += f, h[6] += g, h[7] += last;
}

/* A sum of bytes that come in pieces, as in sha512.c: begun, added to, and
 * ended. */
void sha256_begin(struct sha256_state *state)
{
    memcpy(state->h, initial, sizeof state->h);
    state->bytes = 0;
    state->held = 0;
}

void sha256_add(struct sha256_state *state, const void *data, uint64_t bytes)
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
    for (; bytes >= 64; bytes -= 64, p += 64)
        block(state->h, p);
    memcpy(state->rest, p, bytes);
    state->held = (unsigned)bytes;
}

/* After the bytes comes a byte of 0x80, zeroes up to eight bytes short of
 * a block's end, and how many bits there were, in those eight (5.1.1). */
void sha256_end(struct sha256_state *state, uint8_t sum[32])
{
    uint8_t end[128] = {0};
    unsigned left = state->held, length = left < 56 ? 64 : 128;

    memcpy(end, state->rest, left);
    end[left] = 0x80;
    for (unsigned i = 0; i < 8; i++)
        end[length - 1 - i] = (uint8_t)(state->bytes << 3 >> (8 * i));
    block(state->h, end);
    if (length == 128)
        block(state->h, end + 64);
    for (unsigned i = 0; i < 32; i++)
        sum[i] = (uint8_t)(state->h[i / 4] >> (24 - 8 * (i % 4)));
}

/* The sum of that many bytes. */
void sha256(const void *data, uint64_t bytes, uint8_t sum[32])
{
    struct sha256_state state;

    sha256_begin(&state);
    sha256_add(&state, data, bytes);
    sha256_end(&state, sum);
}

/* The sums that the standard's examples have: of nothing, of "abc", and of
 * a text of 448 bits, which takes two blocks; of texts that end a block
 * exactly and that leave room for the count or none; and of bytes that
 * come in pieces. */
void sha256_selftest(void)
{
    static const struct {
        const char *text;
        uint8_t first[8];
    } known[] = {
        { "", { 0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14 } },
        { "abc", { 0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea } },
        { "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", { 0x24, 0x8d, 0x6a, 0x61, 0xd2, 0x06, 0x38, 0xb8 } },
    };
    static const struct {
        unsigned bytes;
        uint8_t first[8];
    } ends[] = { /* that many bytes that are all 'a' */
        { 64, { 0xff, 0xe0, 0x54, 0xfe, 0x7a, 0xe0, 0xcb, 0x6d } },
        { 55, { 0x9f, 0x43, 0x90, 0xf8, 0xd3, 0x0c, 0x2d, 0xd9 } },
        { 56, { 0xb3, 0x54, 0x39, 0xa4, 0xac, 0x6f, 0x09, 0x48 } },
    };
    static const unsigned pieces[] = { 1, 7, 50, 63, 64, 65, 130 };
    uint8_t sum[32], many[64], all[200], whole[32];

    for (unsigned i = 0; i < sizeof known / sizeof known[0]; i++) {
        sha256(known[i].text, strlen(known[i].text), sum);
        if (memcmp(sum, known[i].first, 8))
            panic("sha-256 self-test: the sum of \"%s\" is not what the standard has", known[i].text);
    }
    memset(many, 'a', sizeof many);
    for (unsigned i = 0; i < sizeof ends / sizeof ends[0]; i++) {
        sha256(many, ends[i].bytes, sum);
        if (memcmp(sum, ends[i].first, 8))
            panic("sha-256 self-test: the sum of %u bytes is wrong, where the count ends a block or does not fit in it",
                  ends[i].bytes);
    }
    for (unsigned i = 0; i < sizeof all; i++)
        all[i] = (uint8_t)(i * 7 + 3);
    sha256(all, sizeof all, whole);
    for (unsigned k = 0; k < sizeof pieces / sizeof pieces[0]; k++) {
        struct sha256_state state;

        sha256_begin(&state);
        sha256_add(&state, all, 5); /* so that every piece after this one finds something waiting */
        for (unsigned at = 5; at < sizeof all; at += pieces[k])
            sha256_add(&state, all + at, sizeof all - at < pieces[k] ? sizeof all - at : pieces[k]);
        sha256_end(&state, sum);
        if (memcmp(sum, whole, 32))
            panic("sha-256 self-test: the sum of 200 bytes in pieces of %u is not the sum of the 200", pieces[k]);
    }
}
