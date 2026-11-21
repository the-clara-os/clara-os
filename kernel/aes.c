/* AES-128 in Galois/Counter Mode: what keeps a connection closed once TLS
 * has made its keys (lisp/tls.lisp). Sixteen bytes of key and twelve that
 * no other record under that key has had turn any number of bytes into as
 * many that say nothing to whoever lacks the key, and sixteen more, the
 * tag, by which the one who has it sees that nothing was changed on the
 * way: not those bytes, and not the bytes that went beside them in the
 * clear (FIPS 197, the Advanced Encryption Standard; NIST SP 800-38D, the
 * mode; RFC 5116, how the two are used). It is the one cipher that every
 * TLS 1.3 has to have (RFC 8446, 9.1), and the only one here.
 *
 * The cipher is written with its table of 256 bytes, as the standard has
 * it. So how long a block takes depends, a little, on the key and on the
 * bytes: somebody who shares this processor's cache could measure that,
 * and learn about the key. Nobody shares it: the machine runs one world,
 * and whoever is in the world has the key anyway. The multiplication of
 * the tag takes the same time whatever it multiplies. */
#include "kernel.h"

/* The table of substitutions: for each byte its inverse in the field of 256 elements, with its bits mixed (5.1.1). */
static const uint8_t S[256] = {
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
};

/* The eleven keys of the rounds, 176 bytes, of which the first is the key itself (5.2). */
static void expand(uint8_t w[176], const uint8_t key[16])
{
    uint8_t round = 1;

    memcpy(w, key, 16);
    for (unsigned i = 16; i < 176; i += 4) {
        uint8_t t[4] = { w[i - 4], w[i - 3], w[i - 2], w[i - 1] };

        if (i % 16 == 0) {
            uint8_t first = t[0];

            t[0] = S[t[1]] ^ round, t[1] = S[t[2]], t[2] = S[t[3]], t[3] = S[first];
            round = (uint8_t)(round << 1 ^ (round >> 7) * 0x1b);
        }
        for (unsigned j = 0; j < 4; j++)
            w[i + j] = w[i - 16 + j] ^ t[j];
    }
}

/* A byte times two, in the field. */
static uint8_t twice(uint8_t x)
{
    return (uint8_t)(x << 1 ^ (x >> 7) * 0x1b);
}

/* One block of sixteen bytes, enciphered (5.1): the bytes are four
 * columns of four, and a round substitutes each byte, shifts the row r by
 * r columns, mixes each column, and adds the round's key. The last round
 * does not mix. Only this direction is ever needed: the mode makes a
 * stream of blocks of the cipher and adds it to the bytes, both ways. */
static void encipher(const uint8_t w[176], const uint8_t in[16], uint8_t out[16])
{
    uint8_t s[16], t[16];

    for (unsigned i = 0; i < 16; i++)
        s[i] = in[i] ^ w[i];
    for (unsigned round = 1; round <= 10; round++) {
        for (unsigned c = 0; c < 4; c++)
            for (unsigned r = 0; r < 4; r++)
                t[4 * c + r] = S[s[4 * ((c + r) & 3) + r]];
        if (round < 10)
            for (unsigned c = 0; c < 4; c++) {
                uint8_t a = t[4 * c], b = t[4 * c + 1], d = t[4 * c + 2], e = t[4 * c + 3];

                s[4 * c] = twice(a) ^ twice(b) ^ b ^ d ^ e;
                s[4 * c + 1] = a ^ twice(b) ^ twice(d) ^ d ^ e;
                s[4 * c + 2] = a ^ b ^ twice(d) ^ twice(e) ^ e;
                s[4 * c + 3] = twice(a) ^ a ^ b ^ d ^ twice(e);
            }
        else
            memcpy(s, t, 16);
        for (unsigned i = 0; i < 16; i++)
            s[i] ^= w[16 * round + i];
    }
    memcpy(out, s, 16);
}

/* A block as a number of 128 bits, for the tag: its first byte is the highest. */
struct block {
    uint64_t high, low;
};

static struct block block_of(const uint8_t *p, uint64_t bytes)
{
    uint8_t whole[16] = {0};
    struct block b = { 0, 0 };

    memcpy(whole, p, bytes < 16 ? bytes : 16);
    for (unsigned i = 0; i < 8; i++) {
        b.high = b.high << 8 | whole[i];
        b.low = b.low << 8 | whole[8 + i];
    }
    return b;
}

/* X becomes X times H, as the mode multiplies (SP 800-38D, 6.3): bit by
 * bit, and without a branch, so that it takes the same time whatever the
 * numbers are. */
static void multiply(struct block *x, const struct block *h)
{
    struct block z = { 0, 0 }, v = *h;

    for (unsigned i = 0; i < 128; i++) {
        uint64_t take = 0 - (i < 64 ? x->high >> (63 - i) & 1 : x->low >> (127 - i) & 1);
        uint64_t odd = 0 - (v.low & 1);

        z.high ^= v.high & take;
        z.low ^= v.low & take;
        v.low = v.low >> 1 | v.high << 63;
        v.high = v.high >> 1 ^ (0xe100000000000000ULL & odd);
    }
    *x = z;
}

/* Some bytes go into the tag, a block at a time, the last one filled up with zeroes. */
static void gather(struct block *y, const struct block *h, const uint8_t *p, uint64_t bytes)
{
    for (; bytes; p += bytes < 16 ? bytes : 16, bytes -= bytes < 16 ? bytes : 16) {
        struct block b = block_of(p, bytes);

        y->high ^= b.high;
        y->low ^= b.low;
        multiply(y, h);
    }
}

/* BYTES bytes at FROM are closed or opened with the key and the twelve
 * bytes NONCE, into TO, which may be the same place; BESIDE are bytes that
 * are not closed and that the tag covers as well. Closing writes the tag;
 * opening holds the bytes against it first, says 0 when it is not theirs,
 * and has then written nothing. */
int aes128_gcm(int opening, const uint8_t key[16], const uint8_t nonce[12], const uint8_t *beside, uint64_t beside_bytes,
               const uint8_t *from, uint64_t bytes, uint8_t *to, uint8_t tag[16])
{
    uint8_t w[176], counter[16], stream[16], first[16], zero[16] = {0};
    struct block h, y = { 0, 0 }, lengths = { beside_bytes << 3, bytes << 3 };
    unsigned wrong = 0;

    expand(w, key);
    encipher(w, zero, stream);
    h = block_of(stream, 16);
    memcpy(counter, nonce, 12);
    counter[12] = counter[13] = counter[14] = 0, counter[15] = 1;
    encipher(w, counter, first);
    if (opening) {
        gather(&y, &h, beside, beside_bytes);
        gather(&y, &h, from, bytes);
        y.high ^= lengths.high, y.low ^= lengths.low;
        multiply(&y, &h);
        for (unsigned i = 0; i < 16; i++)
            wrong |= (unsigned)(tag[i] ^ first[i] ^ (uint8_t)((i < 8 ? y.high : y.low) >> (56 - 8 * (i % 8))));
        if (wrong) {
            memset(w, 0, sizeof w);
            return 0;
        }
    }
    for (uint64_t at = 0, number = 2; at < bytes; at += 16, number++) {
        counter[12] = (uint8_t)(number >> 24), counter[13] = (uint8_t)(number >> 16);
        counter[14] = (uint8_t)(number >> 8), counter[15] = (uint8_t)number;
        encipher(w, counter, stream);
        for (uint64_t i = at; i < bytes && i < at + 16; i++)
            to[i] = from[i] ^ stream[i - at];
    }
    if (!opening) {
        gather(&y, &h, beside, beside_bytes);
        gather(&y, &h, to, bytes);
        y.high ^= lengths.high, y.low ^= lengths.low;
        multiply(&y, &h);
        for (unsigned i = 0; i < 16; i++)
            tag[i] = first[i] ^ (uint8_t)((i < 8 ? y.high : y.low) >> (56 - 8 * (i % 8)));
    }
    memset(w, 0, sizeof w);
    return 1;
}

/* The standard's own example of a block (FIPS 197, C.1); the second and
 * the fourth of the examples that the mode was published with (McGrew and
 * Viega, The Galois/Counter Mode of Operation, appendix B), of which the
 * fourth has bytes beside it and does not end a block; and a thousand
 * bytes, closed and opened where they lie, and not opened when a bit of
 * them, of the tag, or of what went beside them is another. */
void aes_selftest(void)
{
    static const uint8_t plain[16] = { 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
    static const uint8_t cipher[16] = { 0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30, 0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a };
    static const uint8_t second[32] = { 0x03, 0x88, 0xda, 0xce, 0x60, 0xb6, 0xa3, 0x92, 0xf3, 0x28, 0xc2, 0xb9, 0x71, 0xb2, 0xfe, 0x78, 0xab, 0x6e, 0x47, 0xd4, 0x2c, 0xec, 0x13, 0xbd, 0xf5, 0x3a, 0x67, 0xb2, 0x12, 0x57, 0xbd, 0xdf };
    static const uint8_t key4[16] = { 0xfe, 0xff, 0xe9, 0x92, 0x86, 0x65, 0x73, 0x1c, 0x6d, 0x6a, 0x8f, 0x94, 0x67, 0x30, 0x83, 0x08 }, nonce4[12] = { 0xca, 0xfe, 0xba, 0xbe, 0xfa, 0xce, 0xdb, 0xad, 0xde, 0xca, 0xf8, 0x88 }, beside4[20] = { 0xfe, 0xed, 0xfa, 0xce, 0xde, 0xad, 0xbe, 0xef, 0xfe, 0xed, 0xfa, 0xce, 0xde, 0xad, 0xbe, 0xef, 0xab, 0xad, 0xda, 0xd2 };
    static const uint8_t plain4[60] = { 0xd9, 0x31, 0x32, 0x25, 0xf8, 0x84, 0x06, 0xe5, 0xa5, 0x59, 0x09, 0xc5, 0xaf, 0xf5, 0x26, 0x9a, 0x86, 0xa7, 0xa9, 0x53, 0x15, 0x34, 0xf7, 0xda, 0x2e, 0x4c, 0x30, 0x3d, 0x8a, 0x31, 0x8a, 0x72, 0x1c, 0x3c, 0x0c, 0x95, 0x95, 0x68, 0x09, 0x53, 0x2f, 0xcf, 0x0e, 0x24, 0x49, 0xa6, 0xb5, 0x25, 0xb1, 0x6a, 0xed, 0xf5, 0xaa, 0x0d, 0xe6, 0x57, 0xba, 0x63, 0x7b, 0x39 };
    static const uint8_t cipher4[60] = { 0x42, 0x83, 0x1e, 0xc2, 0x21, 0x77, 0x74, 0x24, 0x4b, 0x72, 0x21, 0xb7, 0x84, 0xd0, 0xd4, 0x9c, 0xe3, 0xaa, 0x21, 0x2f, 0x2c, 0x02, 0xa4, 0xe0, 0x35, 0xc1, 0x7e, 0x23, 0x29, 0xac, 0xa1, 0x2e, 0x21, 0xd5, 0x14, 0xb2, 0x54, 0x66, 0x93, 0x1c, 0x7d, 0x8f, 0x6a, 0x5a, 0xac, 0x84, 0xaa, 0x05, 0x1b, 0xa3, 0x0b, 0x39, 0x6a, 0x0a, 0xac, 0x97, 0x3d, 0x58, 0xe0, 0x91 };
    static const uint8_t tag4[16] = { 0x5b, 0xc9, 0x4f, 0xbc, 0x32, 0x21, 0xa5, 0xdb, 0x94, 0xfa, 0xe9, 0x5a, 0xe7, 0x12, 0x1a, 0x47 };
    static const uint8_t tag1000[16] = { 0xa2, 0x6f, 0x1f, 0x41, 0x96, 0xba, 0x76, 0xd4, 0x61, 0x0d, 0x37, 0x65, 0x84, 0x0a, 0xdd, 0x5d };
    uint8_t w[176], key[16], nonce[12] = {0}, out[64], tag[16], many[1000];

    for (unsigned i = 0; i < 16; i++)
        key[i] = (uint8_t)i;
    expand(w, key);
    encipher(w, plain, out);
    if (memcmp(out, cipher, 16))
        panic("aes self-test: the block of the standard's example is not enciphered as the standard has it");
    memset(key, 0, sizeof key);
    memset(out, 0, sizeof out);
    aes128_gcm(0, key, nonce, NULL, 0, out, 16, out, tag);
    if (memcmp(out, second, 16) || memcmp(tag, second + 16, 16))
        panic("aes self-test: sixteen zeroes under a key of zeroes are not closed as the mode's second example has it");
    aes128_gcm(0, key4, nonce4, beside4, sizeof beside4, plain4, sizeof plain4, out, tag);
    if (memcmp(out, cipher4, sizeof cipher4) || memcmp(tag, tag4, 16))
        panic("aes self-test: the mode's fourth example, with bytes beside it, is not closed as it is published");
    if (!aes128_gcm(1, key4, nonce4, beside4, sizeof beside4, cipher4, sizeof cipher4, out, tag) || memcmp(out, plain4, sizeof plain4))
        panic("aes self-test: the mode's fourth example is not opened again");
    for (unsigned i = 0; i < sizeof many; i++)
        many[i] = (uint8_t)(i * 7 + 3);
    for (unsigned i = 0; i < 16; i++)
        key[i] = (uint8_t)(i * 11 + 5);
    for (unsigned i = 0; i < 12; i++)
        nonce[i] = (uint8_t)(i * 13 + 1);
    memcpy(out, many, 13); /* what goes beside them: their own first thirteen, from another place */
    aes128_gcm(0, key, nonce, out, 13, many, sizeof many, many, tag);
    if (memcmp(tag, tag1000, 16))
        panic("aes self-test: a thousand bytes, closed where they lie, do not have the tag that they should");
    many[999] ^= 1;
    if (aes128_gcm(1, key, nonce, out, 13, many, sizeof many, many, tag))
        panic("aes self-test: bytes of which a bit was changed are opened all the same");
    many[999] ^= 1;
    tag[0] ^= 0x80;
    if (aes128_gcm(1, key, nonce, out, 13, many, sizeof many, many, tag))
        panic("aes self-test: bytes are opened with a tag that is not theirs");
    tag[0] ^= 0x80;
    out[12] ^= 4;
    if (aes128_gcm(1, key, nonce, out, 13, many, sizeof many, many, tag))
        panic("aes self-test: bytes are opened though what went beside them was changed");
    out[12] ^= 4;
    if (!aes128_gcm(1, key, nonce, out, 13, many, sizeof many, many, tag))
        panic("aes self-test: a thousand bytes are not opened with their own tag");
    for (unsigned i = 0; i < sizeof many; i++)
        if (many[i] != (uint8_t)(i * 7 + 3))
            panic("aes self-test: a thousand bytes, closed and opened, are not what they were, at the byte %u", i);
}
