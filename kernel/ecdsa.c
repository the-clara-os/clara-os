/* ECDSA on the two curves that certificates are signed with: whether two
 * numbers are the signature that a key gives a sum (FIPS 186-5, the
 * Digital Signature Standard, 6.4.2; the curves are P-256 and P-384 of
 * NIST SP 800-186, 3.2.1). A certificate that is not signed with RSA is
 * signed this way, and so is what a server says at the end of its
 * greeting to show that the key in its certificate is its own
 * (lisp/tls.lisp).
 *
 * A curve is the points (x, y) with y*y = x*x*x - 3*x + b, modulo a prime
 * p, and a rule for adding two of them. A key is a point Q; the base
 * point G has the order n. The signature (r, s) of a sum e is good when
 * the point (e/s)*G + (r/s)*Q has an x that is r, modulo n.
 *
 * Points are kept as three numbers, X, Y and Z, of which x is X/(Z*Z) and
 * y is Y/(Z*Z*Z), so that adding needs no division until the very end;
 * the formulas are the ones that the Explicit-Formulas Database has as
 * dbl-2001-b and add-2007-bl without its shortcuts (Bernstein and Lange,
 * hyperelliptic.org/EFD). The numbers are bignum.c's, kept as themselves
 * times R. Only this half is here, as with Ed25519: a signature is
 * checked and never made, nothing in it is a secret, and nothing has to
 * take the same time whatever the numbers are.
 *
 * The numbers of the curves below were held against the standard in the
 * only way that does not need the standard at hand: Python's big numbers
 * say that p and n are primes, that G is on the curve, and that n times G
 * is no point at all. The examples at the end were signed by the same
 * Python, and OpenSSL 4.1 takes each of them for its key's. */
#include "kernel.h"

#define WORDS 12

struct point {
    uint32_t x[WORDS], y[WORDS], z[WORDS]; /* no point at all, the sum of a point and its opposite, has a Z of 0 */
};

static struct curve {
    unsigned bits;
    const char *p, *b, *x, *y, *n;
    int ready;
    unsigned words;
    struct big_modulus field, order;
    uint32_t b_inside[WORDS], field_less_two[WORDS], order_less_two[WORDS];
    struct point g;
} curves[] = {
    { 256, "ffffffff00000001000000000000000000000000ffffffffffffffffffffffff",
      "5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b",
      "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296",
      "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5",
      "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551", 0, 0, { 0 }, { 0 }, { 0 }, { 0 }, { 0 }, { { 0 }, { 0 }, { 0 } } },
    { 384, "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff",
      "b3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875ac656398d8a2ed19d2a85c8edd3ec2aef",
      "aa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7",
      "3617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f",
      "ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973", 0, 0, { 0 }, { 0 }, { 0 }, { 0 }, { 0 }, { { 0 }, { 0 }, { 0 } } },
};

static void bytes_of(uint8_t *bytes, const char *digits, unsigned count)
{
    for (unsigned i = 0; i < 2 * count; i++) {
        unsigned digit = digits[i] <= '9' ? (unsigned)(digits[i] - '0') : (unsigned)(digits[i] - 'a' + 10);

        bytes[i / 2] = (uint8_t)(i % 2 ? bytes[i / 2] | digit : digit << 4);
    }
}

/* The curve of that many bits, with its numbers worked out the first time it is asked for; or NULL. */
static struct curve *curve_of(unsigned bits)
{
    struct curve *c = bits == 256 ? &curves[0] : bits == 384 ? &curves[1] : NULL;

    if (c && !c->ready) {
        uint32_t t[WORDS], one[WORDS] = { 1 }, two[WORDS] = { 2 };
        unsigned size = bits / 8;
        uint8_t bytes[48];

        bytes_of(bytes, c->p, size);
        big_modulus(&c->field, bytes, size);
        bytes_of(bytes, c->n, size);
        big_modulus(&c->order, bytes, size);
        c->words = c->field.words;
        bytes_of(bytes, c->b, size);
        big_read(t, c->words, bytes, size);
        big_enter(c->b_inside, t, &c->field);
        bytes_of(bytes, c->x, size);
        big_read(t, c->words, bytes, size);
        big_enter(c->g.x, t, &c->field);
        bytes_of(bytes, c->y, size);
        big_read(t, c->words, bytes, size);
        big_enter(c->g.y, t, &c->field);
        big_enter(c->g.z, one, &c->field);
        big_subtract(c->field_less_two, c->field.n, two, c->words);
        big_subtract(c->order_less_two, c->order.n, two, c->words);
        c->ready = 1;
    }
    return c;
}

/* Sums and differences modulo the prime: of numbers below it, a number below it. */
static void plus(uint32_t *r, const uint32_t *a, const uint32_t *b, const struct big_modulus *m)
{
    if (big_add(r, a, b, m->words) || big_compare(r, m->n, m->words) >= 0)
        big_subtract(r, r, m->n, m->words);
}

static void minus(uint32_t *r, const uint32_t *a, const uint32_t *b, const struct big_modulus *m)
{
    if (big_subtract(r, a, b, m->words))
        big_add(r, r, m->n, m->words);
}

/* R becomes P + P. R may be P. */
static void twice(struct point *r, const struct point *p, const struct curve *c)
{
    const struct big_modulus *m = &c->field;
    uint32_t delta[WORDS], gamma[WORDS], beta[WORDS], alpha[WORDS], t[WORDS], z[WORDS];

    if (big_zero(p->z, c->words)) {
        *r = *p;
        return;
    }
    big_multiply(delta, p->z, p->z, m);
    big_multiply(gamma, p->y, p->y, m);
    big_multiply(beta, p->x, gamma, m);
    minus(t, p->x, delta, m);
    plus(z, p->x, delta, m);
    big_multiply(alpha, t, z, m);
    plus(t, alpha, alpha, m);
    plus(alpha, t, alpha, m); /* 3 * (x - delta) * (x + delta) */
    plus(t, p->y, p->z, m);
    big_multiply(t, t, t, m);
    minus(t, t, gamma, m);
    minus(z, t, delta, m); /* Z: (y + z)^2 - gamma - delta */
    plus(beta, beta, beta, m);
    plus(beta, beta, beta, m); /* 4 * beta */
    big_multiply(t, alpha, alpha, m);
    minus(t, t, beta, m);
    minus(t, t, beta, m); /* X: alpha^2 - 8 * beta */
    minus(beta, beta, t, m);
    big_multiply(beta, alpha, beta, m);
    big_multiply(gamma, gamma, gamma, m);
    plus(gamma, gamma, gamma, m);
    plus(gamma, gamma, gamma, m);
    plus(gamma, gamma, gamma, m);
    minus(r->y, beta, gamma, m); /* Y: alpha * (4 * beta - X) - 8 * gamma^2 */
    memcpy(r->x, t, sizeof t);
    memcpy(r->z, z, sizeof z);
}

/* R becomes P + Q. R may be either. */
static void add(struct point *r, const struct point *p, const struct point *q, const struct curve *c)
{
    const struct big_modulus *m = &c->field;
    uint32_t z1z1[WORDS], z2z2[WORDS], u1[WORDS], u2[WORDS], s1[WORDS], s2[WORDS], h[WORDS], slope[WORDS], hh[WORDS],
        hhh[WORDS], v[WORDS], z[WORDS];

    if (big_zero(p->z, c->words)) {
        *r = *q;
        return;
    }
    if (big_zero(q->z, c->words)) {
        *r = *p;
        return;
    }
    big_multiply(z1z1, p->z, p->z, m);
    big_multiply(z2z2, q->z, q->z, m);
    big_multiply(u1, p->x, z2z2, m);
    big_multiply(u2, q->x, z1z1, m);
    big_multiply(s1, p->y, q->z, m);
    big_multiply(s1, s1, z2z2, m);
    big_multiply(s2, q->y, p->z, m);
    big_multiply(s2, s2, z1z1, m);
    minus(h, u2, u1, m);
    minus(slope, s2, s1, m);
    if (big_zero(h, c->words)) {
        /* the same x: the same point, which is doubled, or a point and its opposite, whose sum is no point */
        if (big_zero(slope, c->words))
            twice(r, p, c);
        else
            memset(r, 0, sizeof *r);
        return;
    }
    big_multiply(hh, h, h, m);
    big_multiply(hhh, h, hh, m);
    big_multiply(v, u1, hh, m);
    big_multiply(z, p->z, q->z, m);
    big_multiply(z, z, h, m);
    big_multiply(u2, slope, slope, m);
    minus(u2, u2, hhh, m);
    minus(u2, u2, v, m);
    minus(u2, u2, v, m); /* X: slope^2 - h^3 - 2 * u1 * h^2 */
    minus(v, v, u2, m);
    big_multiply(v, slope, v, m);
    big_multiply(s1, s1, hhh, m);
    minus(r->y, v, s1, m); /* Y: slope * (u1 * h^2 - X) - s1 * h^3 */
    memcpy(r->x, u2, sizeof u2);
    memcpy(r->z, z, sizeof z);
}

/* Are R and S the signature that the key gives the sum? The key is the x
 * and the y of its point, each as many bytes as the curve has, the
 * highest first; the sum counts as far as the curve's order has bits,
 * from its beginning; R and S are bytes with the highest first, of
 * whatever length. 0 for a curve that is not here, a key that is no point
 * of the curve, and numbers that are not between 1 and the order. */
int ecdsa_verify(unsigned bits, const uint8_t *key, const uint8_t *sum, uint64_t sum_bytes, const uint8_t *r, uint64_t r_bytes,
                 const uint8_t *s, uint64_t s_bytes)
{
    struct curve *c = curve_of(bits);
    const struct big_modulus *f, *o;
    uint32_t rn[WORDS], sn[WORDS], e[WORDS], u1[WORDS], u2[WORDS], t[WORDS], x[WORDS], one[WORDS] = { 1 };
    struct point q, both, total;
    unsigned w, size = bits / 8;

    if (!c)
        return 0;
    f = &c->field, o = &c->order, w = c->words;
    big_read(t, w, key, size);
    big_read(x, w, key + size, size);
    if (big_compare(t, f->n, w) >= 0 || big_compare(x, f->n, w) >= 0)
        return 0;
    if (!big_read(rn, w, r, r_bytes) || !big_read(sn, w, s, s_bytes) || big_zero(rn, w) || big_zero(sn, w) ||
        big_compare(rn, o->n, w) >= 0 || big_compare(sn, o->n, w) >= 0)
        return 0;
    /* the key is a point of the curve: y*y is x*x*x - 3*x + b */
    big_enter(q.x, t, f);
    big_enter(q.y, x, f);
    big_enter(q.z, one, f);
    big_multiply(t, q.y, q.y, f);
    big_multiply(x, q.x, q.x, f);
    big_multiply(x, x, q.x, f);
    minus(x, x, q.x, f);
    minus(x, x, q.x, f);
    minus(x, x, q.x, f);
    plus(x, x, c->b_inside, f);
    if (big_compare(t, x, w))
        return 0;
    /* e, the sum as a number; 1/s, as s to the power n - 2; and e/s and r/s */
    big_read(e, w, sum, sum_bytes < size ? sum_bytes : size);
    if (big_compare(e, o->n, w) >= 0)
        big_subtract(e, e, o->n, w);
    big_enter(t, sn, o);
    big_power(t, t, c->order_less_two, w, o);
    big_enter(u1, e, o);
    big_multiply(u1, u1, t, o);
    big_leave(u1, u1, o);
    big_enter(u2, rn, o);
    big_multiply(u2, u2, t, o);
    big_leave(u2, u2, o);
    /* (e/s)*G + (r/s)*Q, both at once: for every bit of the two, from the highest, the total is doubled and G, Q or G + Q added */
    add(&both, &c->g, &q, c);
    memset(&total, 0, sizeof total);
    for (unsigned bit = bits; bit-- > 0;) {
        unsigned first = u1[bit / 32] >> (bit % 32) & 1, second = u2[bit / 32] >> (bit % 32) & 1;

        twice(&total, &total, c);
        if (first && second)
            add(&total, &total, &both, c);
        else if (first)
            add(&total, &total, &c->g, c);
        else if (second)
            add(&total, &total, &q, c);
    }
    if (big_zero(total.z, w))
        return 0;
    /* its x, as X / (Z*Z), with 1/Z as Z to the power p - 2; and that modulo n, which is below p and above half of it */
    big_power(t, total.z, c->field_less_two, w, f);
    big_multiply(t, t, t, f);
    big_multiply(x, total.x, t, f);
    big_leave(x, x, f);
    if (big_compare(x, o->n, w) >= 0)
        big_subtract(x, x, o->n, w);
    return big_compare(x, rn, w) == 0;
}

/* A key, a sum and its signature on each curve, good as they stand; and
 * bad with a bit of the sum, of either number or of the key another, with
 * a number that is zero or the order, and with a key that is not on the
 * curve. Also a sum that is longer than the curve, of which only the
 * beginning counts, and one that is shorter; keys that are the base point
 * and its opposite, where the sum of the two points that the checking
 * adds up first is a point doubled and no point at all; and sums that
 * are above the order, as a number. */
void ecdsa_selftest(void)
{
    static const struct {
        unsigned bits, sum_bytes;
        const char *key, *sum, *r, *s;
    } known[] = {
        { 256, 32,
          "5e247613ba8ed01ca47ffe036046edfa596517db67d04e7889e2bd3b39787dda"
          "9087d626af7f071353a7fb7219688d3b259b01693f322e87dfe580dee83f0027",
          "eb7a141a6b87768b1553d1ab173b78ffd3f66266165e11891ade3efab24a559d",
          "accf0106ef858fa2d919331346805a78b58bbad0b844e5c7892879146187dd26",
          "896d87cfae6b7550fd7159787977ac073f02f0248f831a5e37b82d9270e140c0" },
        { 384, 48,
          "debc60978c88574394f9d6fbcb25f2e1d637734d6d89c221c77bad54ab7cc79a5fc5f0a82d742b07af495e93ebee67fb"
          "dd1ab2173007f723c9decb1897c8df4870980e8213a9702b409c1d0c954ab584225e64062dcaa52dd12d56b22bbe78e7",
          "e4ef581e87bd73f6679c1bc8a65033a3169ee52e3a181260a4b79b0986a2aa234d5b6529270c7ef910e11410b30fe567",
          "766c51a7a385a522d0be3ccf1b907f6cdb592873b26aee1d03509fb1a7436445bde5cb25e81621844e5b8e41563af74c",
          "4d2c2c04cf7e9c5eb40673785c84c426752424965cda3540e0736725b7e5b744d7bf30816fd11f95986e4014bcedd88d" },
        { 256, 48,
          "30df9692883ec2d336c22917fa585ce04f8f48e206aaeba5aa5c511ad5dfadf3"
          "483a117ddb0f9380602575ac0a3cfaf0f75de095b29b7784fbdf5077493abe36",
          "660f6f5c9fed6068ef605e33b749274345c09216d0b6472e8c1afe0df6feedb451515b42d306a9bace8e4b572670f721",
          "3a2c21480c7a1b0931e0b4bf868f03ff0baa1527e776a2436685acb8bde37a48",
          "c308a19f61f1108f127fe109930274fa752579afa028cd8e35fec711d0f084a9" },
        { 384, 32,
          "5c4c979d4ee5475ae9d0327defa3e7e35159364c0066bc0be79f9ab7eefa5f6e2f2099a379f891b924a7ac14bbd092a4"
          "0dde70f443b2c931fdf623fa04eb62511fb42d28503d6c03117224ea5d30c66e73ba97733bf3d85fe9126f5385159de3",
          "ac81043a06e3dc3cb8ad0d4f554300578e4ec6109c0a1ba5a90453f07f0d50c8",
          "ec73ed4ed978c24bcf0d88a522374694bb9bc747a161d5a3a71160a55fe6480e146a71238638fe723181e646f6e9d162",
          "82b5df19212eeede208a62693ff3f2b0afebccb376bc6cc126be3b93a3ac67a2b00fa6e32d57f3e932f04afb92908ba3" },
        /* a key that is the base point itself, on each curve; one that is its opposite; and sums that are above the order */
        { 256, 32,
          "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296"
          "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5",
          "60aa9bd6a5a8edf5a1c22457281b44c1e1a6f1eb17f13b10ebcde15af49b5282",
          "3a2c21480c7a1b0931e0b4bf868f03ff0baa1527e776a2436685acb8bde37a48",
          "20629704b3c109e5711ddc029f7052fd01e7b8d8f2ffc436a4cef11dee107921" },
        { 256, 32,
          "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296"
          "b01cbd1c01e58065711814b583f061e9d431cca994cea1313449bf97c840ae0a",
          "cc4065dcc2fcda1ebbccf4f829c6aa53b2fab1fc233160723a56e5eb3c4cf960",
          "3a2c21480c7a1b0931e0b4bf868f03ff0baa1527e776a2436685acb8bde37a48",
          "45b1f29323f032cf5d03bb6104132a9ffe475425ae25e755ac50c8f1b025cb30" },
        { 256, 32,
          "5e247613ba8ed01ca47ffe036046edfa596517db67d04e7889e2bd3b39787dda"
          "9087d626af7f071353a7fb7219688d3b259b01693f322e87dfe580dee83f0027",
          "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
          "3a2c21480c7a1b0931e0b4bf868f03ff0baa1527e776a2436685acb8bde37a48",
          "79d36d118b5910a9673e6f33b92385a8fd50f4f070edddd407ff16a5c95c1bd4" },
        { 384, 48,
          "aa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7"
          "3617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f",
          "aba217b212d6286383e15b83b278577d312a66109d933aa932ada1eaed52b8422b72a12849315318dbc2b59ac0704277",
          "2239116e39bfb7245a8f7c6694f30e65b50e994db99dc305b5e30293ec33622d20e459a359abf19c411aeaf8e5871568",
          "d80b397826e66ef8510266210d8f09b3071b0728bd4856d1b77eb19e3285a4acbc7027a9c7e789d419eaa3f898adba2e" },
        { 384, 48,
          "debc60978c88574394f9d6fbcb25f2e1d637734d6d89c221c77bad54ab7cc79a5fc5f0a82d742b07af495e93ebee67fb"
          "dd1ab2173007f723c9decb1897c8df4870980e8213a9702b409c1d0c954ab584225e64062dcaa52dd12d56b22bbe78e7",
          "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
          "2239116e39bfb7245a8f7c6694f30e65b50e994db99dc305b5e30293ec33622d20e459a359abf19c411aeaf8e5871568",
          "1a406fd6daad4c1390199e831b656945115ddb4d886d107025ad0fa226791734c931d32576eb9937d348359d278b18d7" },
    };

    for (unsigned i = 0; i < sizeof known / sizeof known[0]; i++) {
        unsigned bits = known[i].bits, size = bits / 8, sum_bytes = known[i].sum_bytes;
        uint8_t key[96], sum[64], r[48], s[48], other[48];

        bytes_of(key, known[i].key, 2 * size);
        bytes_of(sum, known[i].sum, sum_bytes);
        bytes_of(r, known[i].r, size);
        bytes_of(s, known[i].s, size);
        if (!ecdsa_verify(bits, key, sum, sum_bytes, r, size, s, size))
            panic("ecdsa self-test: the signature of example %u, on P-%u, is not taken for its key's", i + 1, bits);
        sum[0] ^= 1;
        if (ecdsa_verify(bits, key, sum, sum_bytes, r, size, s, size))
            panic("ecdsa self-test: a signature is taken for that of another sum, in example %u", i + 1);
        sum[0] ^= 1;
        r[size - 1] ^= 2;
        if (ecdsa_verify(bits, key, sum, sum_bytes, r, size, s, size))
            panic("ecdsa self-test: a signature with a bit of its first number changed is taken for good, in example %u", i + 1);
        r[size - 1] ^= 2;
        s[3] ^= 0x40;
        if (ecdsa_verify(bits, key, sum, sum_bytes, r, size, s, size))
            panic("ecdsa self-test: a signature with a bit of its second number changed is taken for good, in example %u", i + 1);
        s[3] ^= 0x40;
        key[size + 5] ^= 8;
        if (ecdsa_verify(bits, key, sum, sum_bytes, r, size, s, size))
            panic("ecdsa self-test: a key that is no point of the curve is taken, in example %u", i + 1);
        key[size + 5] ^= 8;
        memset(other, 0, sizeof other);
        if (ecdsa_verify(bits, key, sum, sum_bytes, other, size, s, size) || ecdsa_verify(bits, key, sum, sum_bytes, r, size, other, size))
            panic("ecdsa self-test: a signature with a number that is zero is taken, in example %u", i + 1);
        bytes_of(other, bits == 256 ? curves[0].n : curves[1].n, size);
        if (ecdsa_verify(bits, key, sum, sum_bytes, other, size, s, size) || ecdsa_verify(bits, key, sum, sum_bytes, r, size, other, size))
            panic("ecdsa self-test: a signature with a number that is the order is taken, in example %u", i + 1);
        /* a number with a zero before it is the same number, which is how a certificate writes one whose highest bit is set */
        {
            uint8_t longer[49] = { 0 };

            memcpy(longer + 1, r, size);
            if (!ecdsa_verify(bits, key, sum, sum_bytes, longer, size + 1, s, size))
                panic("ecdsa self-test: a number with a zero before it is taken for another, in example %u", i + 1);
            longer[0] = 1;
            if (ecdsa_verify(bits, key, sum, sum_bytes, longer, size + 1, s, size))
                panic("ecdsa self-test: a number that is longer than the curve is taken, in example %u", i + 1);
        }
        /* of a sum that is longer than the curve only the beginning counts */
        if (sum_bytes > size) {
            sum[sum_bytes - 1] ^= 0xff;
            if (!ecdsa_verify(bits, key, sum, sum_bytes, r, size, s, size))
                panic("ecdsa self-test: the end of a sum that is longer than the curve counts, in example %u", i + 1);
        }
    }
    if (ecdsa_verify(521, (const uint8_t *)"", (const uint8_t *)"", 0, (const uint8_t *)"", 0, (const uint8_t *)"", 0))
        panic("ecdsa self-test: a curve that is not here is taken");
    /* Two signatures on each curve that were made up for what they show. In the first the second number is 5, so
     * that it and the order together still fit in the curve's bytes: that is the same number modulo the order, and
     * no signature, since a signature is one pair of numbers and not several. In the second the key's x is a
     * little above the order, the sum is zeroes and both numbers are that little: it is the key's signature, and
     * is seen to be only when the x that was worked out is taken modulo the order. */
    {
        static const struct {
            unsigned kind, bits;
            const char *key, *sum, *r, *s;
        } made[] = {
        { 1, 256,
          "5e247613ba8ed01ca47ffe036046edfa596517db67d04e7889e2bd3b39787dda"
          "9087d626af7f071353a7fb7219688d3b259b01693f322e87dfe580dee83f0027",
          "78318dd45746a312c399212e129aaf6354261711905e95b32bbd57497d1c6661",
          "3a2c21480c7a1b0931e0b4bf868f03ff0baa1527e776a2436685acb8bde37a48",
          "0000000000000000000000000000000000000000000000000000000000000005" },
        { 2, 256,
          "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632554"
          "484f0c0fda434ef0a808458914f328715d7a545e198ac7eee31dffe861b5d23f",
          "0000000000000000000000000000000000000000000000000000000000000000",
          "0000000000000000000000000000000000000000000000000000000000000003",
          "0000000000000000000000000000000000000000000000000000000000000003" },
        { 1, 384,
          "5b011a9776291b71e4927b902147b8fb4fbcc4d2da75a54f5ef59a15fa458ebec936720a4845fbd2647c1a24d49796f7"
          "1191839e0b77fe9dd11adbbcc85802290f5f3bbcca79b68908b181c69fae736e5e6079170923e5827e3087ca321ffd7f",
          "50fea6a4feb804d2414aa8f32447b3e199cfa7a2f62e5e60a4cc69e176144348567ac75b892730806154e0c2e99ccc39",
          "2239116e39bfb7245a8f7c6694f30e65b50e994db99dc305b5e30293ec33622d20e459a359abf19c411aeaf8e5871568",
          "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005" },
        { 2, 384,
          "ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52975"
          "674db71d55d1948b3c7d4c562474ad137465f9605bc7c67cb9fab6bf9f3ca2ef87d56a8d920568aa26f7eaf13ee70a45",
          "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
          "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002",
          "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002" },
        };

        for (unsigned i = 0; i < sizeof made / sizeof made[0]; i++) {
            unsigned bits = made[i].bits, size = bits / 8, more = 0;
            uint8_t key[96], sum[48], r[48], s[48], order[48];

            bytes_of(key, made[i].key, 2 * size);
            bytes_of(sum, made[i].sum, size);
            bytes_of(r, made[i].r, size);
            bytes_of(s, made[i].s, size);
            if (!ecdsa_verify(bits, key, sum, size, r, size, s, size))
                panic("ecdsa self-test: the signature that was made up as example %u, on P-%u, is not taken for its key's", i + 1,
                      bits);
            if (made[i].kind != 1)
                continue;
            bytes_of(order, bits == 256 ? curves[0].n : curves[1].n, size);
            for (unsigned j = size; j-- > 0;) {
                more += (unsigned)s[j] + order[j];
                s[j] = (uint8_t)more;
                more >>= 8;
            }
            if (more || ecdsa_verify(bits, key, sum, size, r, size, s, size))
                panic("ecdsa self-test: a signature whose second number is not below the order is taken, on P-%u", bits);
        }
    }
}
