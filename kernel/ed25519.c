/* Ed25519: whether sixty-four bytes are the signature that a key gives a
 * message (RFC 8032, Edwards-Curve Digital Signature Algorithm). A release
 * of ClaraOS is signed by whoever publishes it, and a system that fetches
 * one holds the list of its files against that signature, with the public
 * half of the key, before it makes anything of them (lisp/system.lisp). So
 * a release can come by any road, and nothing here has to trust the road.
 *
 * Only this half is here: a signature is checked and never made, and
 * nothing in it is a secret, so nothing has to take the same time whatever
 * the numbers are. Making one is tools/release.py's, on the host.
 *
 * It is in C for the reason that SHA-512 is: the arithmetic is on numbers
 * of 255 bits, where Lisp has integers of sixty-one. A number is sixteen
 * pieces of sixteen bits in sixty-four-bit words, the lowest first, with
 * room in each word for the sums and products to gather before they are
 * carried on; the way of it is the one that TweetNaCl made known
 * (Bernstein, van Gastel, Janssen, Lange, Schwabe, Smetsers, 2013, in the
 * public domain), written out again here. tools/release.py works out the
 * constants below and the examples at the end by other means, big numbers
 * in Python: `python3 tools/release.py constants`. */
#include "kernel.h"

typedef int64_t field[16];

static const field zero, one = {1};
/* -121665/121666, twice that, the base point, and a square root of -1, all modulo 2^255 - 19 (5.1) */
static const field D = {0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070,
                        0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203};
static const field D2 = {0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0,
                         0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406};
static const field X = {0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c,
                        0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169};
static const field Y = {0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
                        0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666};
static const field I = {0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43,
                        0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83};
/* The order of the base point, 2^252 + 27742317777372353535851937790883648493, a byte at a time, the lowest first. */
static const int64_t L[32] = {0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
                              0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0x10};

static void set(field r, const field a)
{
    for (unsigned i = 0; i < 16; i++)
        r[i] = a[i];
}

/* What has gathered above sixteen bits in each piece goes on to the next,
 * and from the last one round to the first, times 38: 2^256 is 38. */
static void carry(field o)
{
    for (unsigned i = 0; i < 16; i++) {
        int64_t c;

        o[i] += 1 << 16;
        c = o[i] >> 16;
        o[i < 15 ? i + 1 : 0] += c - 1 + (i == 15 ? 37 * (c - 1) : 0);
        o[i] -= c * 65536;
    }
}

/* P and Q change places when B is 1. */
static void swap(field p, field q, int b)
{
    int64_t mask = ~((int64_t)b - 1);

    for (unsigned i = 0; i < 16; i++) {
        int64_t t = mask & (p[i] ^ q[i]);

        p[i] ^= t;
        q[i] ^= t;
    }
}

/* A number as its thirty-two bytes: the one of its kind that is below
 * 2^255 - 19, which is found by taking that away twice and keeping each
 * time what did not go below zero. */
static void pack(uint8_t o[32], const field n)
{
    field m, t;

    set(t, n);
    carry(t);
    carry(t);
    carry(t);
    for (unsigned j = 0; j < 2; j++) {
        int b;

        m[0] = t[0] - 0xffed;
        for (unsigned i = 1; i < 15; i++) {
            m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1);
            m[i - 1] &= 0xffff;
        }
        m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
        b = (int)((m[15] >> 16) & 1);
        m[14] &= 0xffff;
        swap(t, m, 1 - b);
    }
    for (unsigned i = 0; i < 16; i++) {
        o[2 * i] = (uint8_t)(t[i] & 0xff);
        o[2 * i + 1] = (uint8_t)(t[i] >> 8);
    }
}

static int differ(const field a, const field b)
{
    uint8_t c[32], d[32];

    pack(c, a);
    pack(d, b);
    return memcmp(c, d, 32) != 0;
}

static int parity(const field a)
{
    uint8_t d[32];

    pack(d, a);
    return d[0] & 1;
}

static void unpack(field o, const uint8_t n[32])
{
    for (unsigned i = 0; i < 16; i++)
        o[i] = n[2 * i] + ((int64_t)n[2 * i + 1] << 8);
    o[15] &= 0x7fff;
}

static void sum(field o, const field a, const field b)
{
    for (unsigned i = 0; i < 16; i++)
        o[i] = a[i] + b[i];
}

static void difference(field o, const field a, const field b)
{
    for (unsigned i = 0; i < 16; i++)
        o[i] = a[i] - b[i];
}

static void product(field o, const field a, const field b)
{
    int64_t t[31] = {0};

    for (unsigned i = 0; i < 16; i++)
        for (unsigned j = 0; j < 16; j++)
            t[i + j] += a[i] * b[j];
    for (unsigned i = 0; i < 15; i++)
        t[i] += 38 * t[i + 16];
    for (unsigned i = 0; i < 16; i++)
        o[i] = t[i];
    carry(o);
    carry(o);
}

static void square(field o, const field a)
{
    product(o, a, a);
}

/* 1/i, as i to the power 2^255 - 21. */
static void inverse(field o, const field i)
{
    field c;

    set(c, i);
    for (int a = 253; a >= 0; a--) {
        square(c, c);
        if (a != 2 && a != 4)
            product(c, c, i);
    }
    set(o, c);
}

/* i to the power 2^252 - 3, which is what a square root is made of. */
static void power(field o, const field i)
{
    field c;

    set(c, i);
    for (int a = 250; a >= 0; a--) {
        square(c, c);
        if (a != 1)
            product(c, c, i);
    }
    set(o, c);
}

/* A point of the curve is four numbers, X, Y, Z and T, of which x is X/Z,
 * y is Y/Z and x times y is T/Z (5.1.4). P becomes P + Q. */
static void add(field p[4], field q[4])
{
    field a, b, c, d, t, e, f, g, h;

    difference(a, p[1], p[0]);
    difference(t, q[1], q[0]);
    product(a, a, t);
    sum(b, p[0], p[1]);
    sum(t, q[0], q[1]);
    product(b, b, t);
    product(c, p[3], q[3]);
    product(c, c, D2);
    product(d, p[2], q[2]);
    sum(d, d, d);
    difference(e, b, a);
    difference(f, d, c);
    sum(g, d, c);
    sum(h, b, a);
    product(p[0], e, f);
    product(p[1], h, g);
    product(p[2], g, f);
    product(p[3], e, h);
}

static void swap_points(field p[4], field q[4], int b)
{
    for (unsigned i = 0; i < 4; i++)
        swap(p[i], q[i], b);
}

/* A point as its thirty-two bytes: its y, and in the highest bit whether its x is odd (5.1.2). */
static void pack_point(uint8_t r[32], field p[4])
{
    field tx, ty, zi;

    inverse(zi, p[2]);
    product(tx, p[0], zi);
    product(ty, p[1], zi);
    pack(r, ty);
    r[31] ^= (uint8_t)(parity(tx) << 7);
}

/* P becomes S times Q, S being thirty-two bytes, the lowest first. Q is used up. */
static void multiply(field p[4], field q[4], const uint8_t *s)
{
    set(p[0], zero);
    set(p[1], one);
    set(p[2], one);
    set(p[3], zero);
    for (int i = 255; i >= 0; i--) {
        int b = (s[i / 8] >> (i & 7)) & 1;

        swap_points(p, q, b);
        add(q, p);
        add(p, p);
        swap_points(p, q, b);
    }
}

static void multiply_base(field p[4], const uint8_t *s)
{
    field q[4];

    set(q[0], X);
    set(q[1], Y);
    set(q[2], one);
    product(q[3], X, Y);
    multiply(p, q, s);
}

/* Sixty-four bytes, as one number, modulo L: into the thirty-two bytes of R. */
static void modulo(uint8_t r[32], int64_t x[64])
{
    int64_t more;

    for (int i = 63; i >= 32; i--) {
        int j;

        more = 0;
        for (j = i - 32; j < i - 12; j++) {
            x[j] += more - 16 * x[i] * L[j - (i - 32)];
            more = (x[j] + 128) >> 8;
            x[j] -= more * 256;
        }
        x[j] += more;
        x[i] = 0;
    }
    more = 0;
    for (int j = 0; j < 32; j++) {
        x[j] += more - (x[31] >> 4) * L[j];
        more = x[j] >> 8;
        x[j] &= 255;
    }
    for (int j = 0; j < 32; j++)
        x[j] -= more * L[j];
    for (int i = 0; i < 32; i++) {
        x[i + 1] += x[i] >> 8;
        r[i] = (uint8_t)(x[i] & 255);
    }
}

/* The point that thirty-two bytes stand for, with its x negated, which is
 * what a signature is checked with; or 0 when they stand for none (5.1.3). */
static int unpack_negative(field r[4], const uint8_t p[32])
{
    field t, check, top, bottom, bottom2, bottom4, bottom6;

    set(r[2], one);
    unpack(r[1], p);
    square(top, r[1]);
    product(bottom, top, D);
    difference(top, top, r[2]);
    sum(bottom, r[2], bottom);

    square(bottom2, bottom);
    square(bottom4, bottom2);
    product(bottom6, bottom4, bottom2);
    product(t, bottom6, top);
    product(t, t, bottom);

    power(t, t);
    product(t, t, top);
    product(t, t, bottom);
    product(t, t, bottom);
    product(r[0], t, bottom);

    square(check, r[0]);
    product(check, check, bottom);
    if (differ(check, top))
        product(r[0], r[0], I);

    square(check, r[0]);
    product(check, check, bottom);
    if (differ(check, top))
        return 0;

    if (parity(r[0]) == (p[31] >> 7))
        difference(r[0], zero, r[0]);
    product(r[3], r[0], r[1]);
    return 1;
}

/* Is SIGNATURE the signature that the key gives those bytes? A signature
 * is a point R and a number S, thirty-two bytes each; it is good when S
 * times the base point is R plus the key's point times the sum of R, the
 * key and the message (5.1.7). S has to be below L: a signature is one
 * string of bytes and not several. */
int ed25519_verify(const uint8_t key[32], const void *message, uint64_t bytes, const uint8_t signature[64])
{
    struct sha512_state state;
    uint8_t h[64], t[32];
    int64_t x[64];
    field p[4], q[4];

    for (int i = 31; i >= 0; i--) {
        if (signature[32 + i] < L[i])
            break;
        if (signature[32 + i] > L[i] || i == 0)
            return 0;
    }
    if (!unpack_negative(q, key))
        return 0;
    sha512_begin(&state);
    sha512_add(&state, signature, 32);
    sha512_add(&state, key, 32);
    sha512_add(&state, message, bytes);
    sha512_end(&state, h);
    for (unsigned i = 0; i < 64; i++)
        x[i] = h[i];
    modulo(h, x);
    multiply(p, q, h);
    multiply_base(q, signature + 32);
    add(p, q);
    pack_point(t, p);
    return memcmp(signature, t, 32) == 0;
}

static void bytes_of(uint8_t *bytes, const char *digits, unsigned count)
{
    for (unsigned i = 0; i < 2 * count; i++) {
        unsigned digit = digits[i] <= '9' ? (unsigned)(digits[i] - '0') : (unsigned)(digits[i] - 'a' + 10);

        bytes[i / 2] = (uint8_t)(i % 2 ? bytes[i / 2] | digit : digit << 4);
    }
}

/* The first three examples of the RFC (7.1): a message of no bytes, of one
 * and of two, each with the key and the signature that go with it. Each is
 * good as it stands, and bad with one bit of the message, of the signature
 * or of the key another: the last of those is what a release that somebody
 * else signed looks like. */
void ed25519_selftest(void)
{
    static const struct {
        const char *key, *message, *signature;
    } known[] = {
        { "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
          "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
          "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b" },
        { "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
          "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
          "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00" },
        { "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025", "af82",
          "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac"
          "18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a" },
    };

    for (unsigned i = 0; i < sizeof known / sizeof known[0]; i++) {
        uint8_t key[32], message[2], signature[64];
        uint64_t bytes = strlen(known[i].message) / 2;

        bytes_of(key, known[i].key, 32);
        bytes_of(message, known[i].message, (unsigned)bytes);
        bytes_of(signature, known[i].signature, 64);
        if (!ed25519_verify(key, message, bytes, signature))
            panic("ed25519 self-test: the signature of the RFC's example %u is not taken for its key's", i + 1);
        signature[40] ^= 1;
        if (ed25519_verify(key, message, bytes, signature))
            panic("ed25519 self-test: a signature with a bit changed is taken for good, in example %u", i + 1);
        signature[40] ^= 1;
        signature[3] ^= 0x10;
        if (ed25519_verify(key, message, bytes, signature))
            panic("ed25519 self-test: a signature with a bit of its point changed is taken for good, in example %u", i + 1);
        signature[3] ^= 0x10;
        key[7] ^= 4;
        if (ed25519_verify(key, message, bytes, signature))
            panic("ed25519 self-test: a signature is taken for that of another key, in example %u", i + 1);
        key[7] ^= 4;
        if (bytes) {
            message[0] ^= 0x80;
            if (ed25519_verify(key, message, bytes, signature))
                panic("ed25519 self-test: a signature is taken for that of another message, in example %u", i + 1);
        } else if (ed25519_verify(key, "x", 1, signature))
            panic("ed25519 self-test: the signature of nothing is taken for that of a byte");
        /* The same S with the order of the base point added is the same point and no signature. */
        if (i == 0) {
            unsigned more = 0;

            bytes_of(signature, known[i].signature, 64);
            for (unsigned j = 0; j < 32; j++) {
                more += signature[32 + j] + (unsigned)L[j];
                signature[32 + j] = (uint8_t)more;
                more >>= 8;
            }
            if (ed25519_verify(key, message, bytes, signature))
                panic("ed25519 self-test: a signature whose number is not below the order of the base point is taken for good");
        }
    }
}
