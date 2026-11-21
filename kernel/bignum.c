/* Numbers of thousands of bits, as far as checking a signature takes: a
 * number to a power, modulo another. A certificate is signed by whoever
 * vouches for it, and most are signed with RSA, where the signature to
 * the power of a small number, modulo the signer's number of 2048 bits or
 * more, has to be the sum of the certificate (RFC 8017, 5.2.2). The two
 * curves of ecdsa.c need the same multiplication, with numbers of 256
 * and 384 bits.
 *
 * A number is pieces of thirty-two bits, the lowest first. Products are
 * taken the way Montgomery found (Modular Multiplication Without Trial
 * Division, 1985), which needs no division: a number x is kept as x times
 * R, with R one more than what the pieces can hold, and the product of
 * two such numbers, divided by R, is one again; dividing by R is a shift
 * once enough of the modulus has been added to make the low pieces zero.
 * The loop is the one that Koc, Acar and Kaliski call CIOS (Analyzing and
 * Comparing Montgomery Multiplication Algorithms, 1996).
 *
 * Nothing here is a secret: a signature is checked and never made. So
 * nothing takes care to take the same time whatever the numbers are. */
#include "kernel.h"

/* Bytes, the highest first, as a number of that many pieces: 0 when it does not fit in them. */
int big_read(uint32_t *words, unsigned count, const uint8_t *bytes, uint64_t length)
{
    memset(words, 0, count * sizeof words[0]);
    for (uint64_t i = 0; i < length; i++) {
        uint8_t byte = bytes[length - 1 - i];

        if (i / 4 < count)
            words[i / 4] |= (uint32_t)byte << (8 * (i % 4));
        else if (byte)
            return 0;
    }
    return 1;
}

/* The other way: the number as that many bytes, the highest first. */
void big_write(uint8_t *bytes, uint64_t length, const uint32_t *words, unsigned count)
{
    for (uint64_t i = 0; i < length; i++)
        bytes[length - 1 - i] = i / 4 < count ? (uint8_t)(words[i / 4] >> (8 * (i % 4))) : 0;
}

/* Below zero when A is the smaller, above when it is the larger. */
int big_compare(const uint32_t *a, const uint32_t *b, unsigned words)
{
    for (unsigned i = words; i-- > 0;)
        if (a[i] != b[i])
            return a[i] < b[i] ? -1 : 1;
    return 0;
}

int big_zero(const uint32_t *a, unsigned words)
{
    uint32_t any = 0;

    for (unsigned i = 0; i < words; i++)
        any |= a[i];
    return !any;
}

/* The sum and the difference, in place if wanted; what is carried out of the highest piece, or borrowed for it. */
uint32_t big_add(uint32_t *r, const uint32_t *a, const uint32_t *b, unsigned words)
{
    uint64_t carry = 0;

    for (unsigned i = 0; i < words; i++) {
        carry += (uint64_t)a[i] + b[i];
        r[i] = (uint32_t)carry;
        carry >>= 32;
    }
    return (uint32_t)carry;
}

uint32_t big_subtract(uint32_t *r, const uint32_t *a, const uint32_t *b, unsigned words)
{
    uint64_t borrow = 0;

    for (unsigned i = 0; i < words; i++) {
        uint64_t d = (uint64_t)a[i] - b[i] - borrow;

        r[i] = (uint32_t)d;
        borrow = d >> 63;
    }
    return (uint32_t)borrow;
}

/* A modulus, from its bytes, with what the multiplication wants to know
 * of it: one over it, negative, modulo 2^32, which is found by guessing
 * and getting twice as many bits right at each turn; and R times R,
 * which is 1 doubled as often as R times R has bits. 0 for a number that
 * is even, that is 1 or nothing, or that has more than BIG_WORDS pieces. */
int big_modulus(struct big_modulus *m, const uint8_t *bytes, uint64_t count)
{
    uint32_t x;

    while (count && !*bytes)
        bytes++, count--;
    if (!count || count > BIG_WORDS * 4 || !(bytes[count - 1] & 1) || (count == 1 && bytes[0] == 1))
        return 0;
    m->words = (unsigned)((count + 3) / 4);
    big_read(m->n, m->words, bytes, count);
    x = m->n[0];
    for (unsigned i = 0; i < 5; i++)
        x *= 2 - m->n[0] * x;
    m->inverse = 0 - x;
    memset(m->square, 0, sizeof m->square);
    m->square[0] = 1;
    for (unsigned i = 0; i < 64 * m->words; i++)
        if (big_add(m->square, m->square, m->square, m->words) || big_compare(m->square, m->n, m->words) >= 0)
            big_subtract(m->square, m->square, m->n, m->words);
    return 1;
}

/* R becomes A times B divided by R, modulo the modulus: the product of
 * two numbers that are kept as themselves times R. Any of the three may
 * be the same. */
void big_multiply(uint32_t *r, const uint32_t *a, const uint32_t *b, const struct big_modulus *m)
{
    uint32_t t[BIG_WORDS + 2];
    unsigned s = m->words;

    memset(t, 0, (s + 2) * sizeof t[0]);
    for (unsigned i = 0; i < s; i++) {
        uint64_t carry = 0, sum;
        uint32_t q;

        for (unsigned j = 0; j < s; j++) {
            sum = (uint64_t)a[j] * b[i] + t[j] + carry;
            t[j] = (uint32_t)sum;
            carry = sum >> 32;
        }
        sum = (uint64_t)t[s] + carry;
        t[s] = (uint32_t)sum;
        t[s + 1] = (uint32_t)(sum >> 32);
        q = t[0] * m->inverse; /* that much of the modulus makes the lowest piece zero */
        carry = ((uint64_t)q * m->n[0] + t[0]) >> 32;
        for (unsigned j = 1; j < s; j++) {
            sum = (uint64_t)q * m->n[j] + t[j] + carry;
            t[j - 1] = (uint32_t)sum;
            carry = sum >> 32;
        }
        sum = (uint64_t)t[s] + carry;
        t[s - 1] = (uint32_t)sum;
        t[s] = t[s + 1] + (uint32_t)(sum >> 32);
    }
    if (t[s] || big_compare(t, m->n, s) >= 0)
        big_subtract(t, t, m->n, s);
    memcpy(r, t, s * sizeof t[0]);
}

/* A number becomes itself times R, and comes back. */
void big_enter(uint32_t *r, const uint32_t *a, const struct big_modulus *m)
{
    big_multiply(r, a, m->square, m);
}

void big_leave(uint32_t *r, const uint32_t *a, const struct big_modulus *m)
{
    uint32_t one[BIG_WORDS] = { 1 };

    big_multiply(r, a, one, m);
}

/* R becomes A to the power of the exponent, which is a plain number of
 * that many pieces; A and R are kept as themselves times R. A square for
 * every bit of the exponent from its highest, and A once more for every
 * bit that is set. */
void big_power(uint32_t *r, const uint32_t *a, const uint32_t *exponent, unsigned exponent_words, const struct big_modulus *m)
{
    uint32_t result[BIG_WORDS], one[BIG_WORDS] = { 1 };
    unsigned bit = exponent_words * 32;

    big_enter(result, one, m);
    while (bit && !(exponent[(bit - 1) / 32] >> ((bit - 1) % 32) & 1))
        bit--;
    while (bit--) {
        big_multiply(result, result, result, m);
        if (exponent[bit / 32] >> (bit % 32) & 1)
            big_multiply(result, result, a, m);
    }
    memcpy(r, result, m->words * sizeof result[0]);
}

/* OUT, as many bytes as the modulus is, becomes the base to the power of
 * the exponent, modulo the modulus; all of them bytes with the highest
 * first. 0, and nothing written, when it is not to be had: a modulus that
 * begins with a zero, since what comes out is as long as the modulus, one
 * that is even or longer than 4096 bits, or a base that is not below the
 * modulus. */
int power_mod(uint8_t *out, const uint8_t *base, uint64_t base_bytes, uint64_t exponent, const uint8_t *modulus,
              uint64_t modulus_bytes)
{
    struct big_modulus m;
    uint32_t a[BIG_WORDS], e[2] = { (uint32_t)exponent, (uint32_t)(exponent >> 32) };

    if (!modulus_bytes || !modulus[0] || !big_modulus(&m, modulus, modulus_bytes))
        return 0;
    if (!big_read(a, m.words, base, base_bytes) || big_compare(a, m.n, m.words) >= 0)
        return 0;
    big_enter(a, a, &m);
    big_power(a, a, e, 2, &m);
    big_leave(a, a, &m);
    big_write(out, modulus_bytes, a, m.words);
    return 1;
}

/* Numbers that a rule makes, of 2048 bits and of 4096, and a small one,
 * each to a power: what comes out is what Python's big numbers make of
 * the same (the comment in ecdsa.c says how). And the numbers that are
 * refused. */
void bignum_selftest(void)
{
    static const struct {
        unsigned bytes;
        uint64_t exponent;
        uint8_t first[8], last[8];
    } known[] = {
        { 256, 65537, { 0x80, 0x52, 0xee, 0x47, 0x99, 0xe0, 0x49, 0x78 }, { 0x95, 0xab, 0x5f, 0xee, 0xc0, 0x5d, 0xd6, 0x54 } },
        { 512, 65537, { 0x2b, 0x4e, 0xf7, 0x44, 0xcb, 0x89, 0x84, 0x99 }, { 0x91, 0x9f, 0xfd, 0x7e, 0x18, 0x62, 0x78, 0x2d } },
        { 256, 3, { 0x04, 0x22, 0x09, 0x30, 0x52, 0x00, 0xdc, 0x1a }, { 0xaa, 0x9b, 0x23, 0xb4, 0x5a, 0x96, 0x11, 0x18 } },
        { 384, 65537, { 0x7b, 0xd2, 0xe7, 0x31, 0x50, 0xe5, 0x74, 0x82 }, { 0x58, 0x2c, 0x6f, 0x3b, 0xa4, 0xb6, 0x7e, 0xfe } },
        { 33, 65537, { 0x04, 0xa2, 0xc0, 0xd0, 0xef, 0x0f, 0x84, 0x94 }, { 0x76, 0x6f, 0x70, 0x82, 0x81, 0x58, 0x10, 0xe4 } },
    };
    static uint8_t modulus[512], base[512], out[512];

    for (unsigned k = 0; k < sizeof known / sizeof known[0]; k++) {
        unsigned bytes = known[k].bytes;

        for (unsigned i = 0; i < bytes; i++) {
            modulus[i] = (uint8_t)(i * 37 + 129);
            base[i] = (uint8_t)(i * 91 + 7);
        }
        modulus[0] |= 0x80, modulus[bytes - 1] |= 1, base[0] &= 0x7f;
        if (!power_mod(out, base, bytes, known[k].exponent, modulus, bytes))
            panic("bignum self-test: a number of %u bits is not taken to a power", bytes * 8);
        if (memcmp(out, known[k].first, 8) || memcmp(out + bytes - 8, known[k].last, 8))
            panic("bignum self-test: a number of %u bits to the power %llu is not what it should be", bytes * 8,
                  (unsigned long long)known[k].exponent);
        if (k == 0) {
            /* the same with the base written longer than it is, and then what is refused */
            static uint8_t longer[300];

            memset(longer, 0, sizeof longer);
            memcpy(longer + sizeof longer - bytes, base, bytes);
            memset(out, 0, sizeof out);
            if (!power_mod(out, longer, sizeof longer, known[k].exponent, modulus, bytes) || memcmp(out, known[k].first, 8))
                panic("bignum self-test: a base with zeroes before it is another number");
            modulus[bytes - 1] ^= 1;
            if (power_mod(out, base, bytes, 3, modulus, bytes))
                panic("bignum self-test: an even modulus is taken");
            modulus[bytes - 1] ^= 1;
            if (power_mod(out, modulus, bytes, 3, modulus, bytes))
                panic("bignum self-test: a base that is the modulus is taken");
            base[0] |= 0xc0;
            if (power_mod(out, base, bytes, 3, modulus, bytes))
                panic("bignum self-test: a base above the modulus is taken");
            memset(longer, 0, sizeof longer);
            memcpy(longer + 1, modulus, bytes);
            if (power_mod(out, base + 1, bytes - 1, 3, longer, bytes + 1))
                panic("bignum self-test: a modulus that begins with a zero is taken");
            if (power_mod(out, base, 1, 3, modulus, 0) || power_mod(out, base, 1, 3, (const uint8_t *)"\x01", 1))
                panic("bignum self-test: a modulus of nothing, or of 1, is taken");
        }
    }
    /* Numbers just below what their pieces can hold, to powers: a product of such numbers is the one that needs the
     * topmost piece of the multiplication, which next to no other does. */
    {
        static const struct {
            unsigned bytes;
            uint64_t exponent;
            uint8_t modulus_last, base_last;
            const char *result;
        } near[] = {
            { 16, 17, 0x61, 0x5c, "ffffffffffffffffffffff4e5d43d09c" },
            { 32, 5, 0x43, 0x40, "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe50" },
        };

        for (unsigned k = 0; k < sizeof near / sizeof near[0]; k++) {
            unsigned bytes = near[k].bytes;

            memset(modulus, 0xff, bytes);
            memset(base, 0xff, bytes);
            modulus[bytes - 1] = near[k].modulus_last, base[bytes - 1] = near[k].base_last;
            if (!power_mod(out, base, bytes, near[k].exponent, modulus, bytes))
                panic("bignum self-test: a number just below %u bits is not taken to a power", bytes * 8);
            for (unsigned i = 0; i < bytes; i++) {
                const char *digits = near[k].result + 2 * i;
                unsigned byte = (unsigned)((digits[0] <= '9' ? digits[0] - '0' : digits[0] - 'a' + 10) * 16 +
                                           (digits[1] <= '9' ? digits[1] - '0' : digits[1] - 'a' + 10));

                if (out[i] != byte)
                    panic("bignum self-test: a number just below %u bits to the power %llu is not what it should be", bytes * 8,
                          (unsigned long long)near[k].exponent);
            }
        }
    }
    /* small numbers, which anybody can check: 4 to the power 13 is 67108864, and modulo 497 that is 445; and anything to the power 0 is 1 */
    {
        static const uint8_t four[1] = { 4 }, small[2] = { 0x01, 0xf1 };

        if (!power_mod(out, four, 1, 13, small, 2) || out[0] != 0x01 || out[1] != 0xbd)
            panic("bignum self-test: 4 to the power 13 modulo 497 is not 445");
        if (!power_mod(out, four, 1, 0, small, 2) || out[0] != 0 || out[1] != 1)
            panic("bignum self-test: 4 to the power 0 is not 1");
    }
}
