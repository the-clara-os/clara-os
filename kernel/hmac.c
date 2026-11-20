/* The three sums by one name, and HMAC: a sum that only somebody who has
 * a key can make, and so a way of saying "this is from me, and nobody has
 * changed it" between two who share the key (RFC 2104). TLS makes
 * everything of it that it makes of a secret: one key from another, and
 * the word at the end of a greeting that says both sides have heard the
 * same (RFC 5869, RFC 8446; lisp/tls.lisp).
 *
 * A sum is named by its number of bits, 256, 384 or 512, which is also
 * how Lisp asks for one (CLARA.UNSAFE:DIGEST, CLARA.UNSAFE:HMAC). */
#include "kernel.h"

/* How many bytes the sum of that many bits is, and 0 for a number that is none of the three. */
unsigned digest_bytes(unsigned bits)
{
    return bits == 256 ? 32 : bits == 384 ? 48 : bits == 512 ? 64 : 0;
}

void digest_begin(struct digest_state *state, unsigned bits)
{
    state->bits = bits;
    if (bits == 256)
        sha256_begin(&state->of.small);
    else if (bits == 384)
        sha384_begin(&state->of.large);
    else
        sha512_begin(&state->of.large);
}

void digest_add(struct digest_state *state, const void *data, uint64_t bytes)
{
    if (state->bits == 256)
        sha256_add(&state->of.small, data, bytes);
    else
        sha512_add(&state->of.large, data, bytes);
}

void digest_end(struct digest_state *state, uint8_t *sum)
{
    uint8_t whole[64];

    if (state->bits == 256)
        sha256_end(&state->of.small, whole);
    else
        sha512_end(&state->of.large, whole);
    memcpy(sum, whole, digest_bytes(state->bits));
}

/* The sum of that many bytes. It may be written where the bytes were. */
void digest(unsigned bits, const void *data, uint64_t bytes, uint8_t *sum)
{
    struct digest_state state;

    digest_begin(&state, bits);
    digest_add(&state, data, bytes);
    digest_end(&state, sum);
}

/* The sum of the key and the bytes together, in the way that makes it
 * nobody's to forge: the key is filled up with zeroes to a block of the
 * sum, 64 bytes or 128, a longer key being its own sum first; then
 * H(key ^ 5c.. | H(key ^ 36.. | bytes)). */
void hmac(unsigned bits, const void *key, uint64_t key_bytes, const void *data, uint64_t bytes, uint8_t *sum)
{
    struct digest_state state;
    uint8_t pad[128] = {0}, inner[64];
    unsigned block = bits == 256 ? 64 : 128, size = digest_bytes(bits);

    if (key_bytes > block)
        digest(bits, key, key_bytes, pad);
    else
        memcpy(pad, key, key_bytes);
    for (unsigned i = 0; i < block; i++)
        pad[i] ^= 0x36;
    digest_begin(&state, bits);
    digest_add(&state, pad, block);
    digest_add(&state, data, bytes);
    digest_end(&state, inner);
    for (unsigned i = 0; i < block; i++)
        pad[i] ^= 0x36 ^ 0x5c;
    digest_begin(&state, bits);
    digest_add(&state, pad, block);
    digest_add(&state, inner, size);
    digest_end(&state, sum);
    memset(pad, 0, sizeof pad);
}

/* The second and the sixth example of RFC 4231, for each of the three
 * sums: a short key, "Jefe", and one of 131 bytes, which is longer than
 * either block. */
void hmac_selftest(void)
{
    static const struct {
        unsigned bits, key;
        uint8_t first[8], longer[8];
    } known[] = {
        { 256, 4, { 0x5b, 0xdc, 0xc1, 0x46, 0xbf, 0x60, 0x75, 0x4e }, { 0x60, 0xe4, 0x31, 0x59, 0x1e, 0xe0, 0xb6, 0x7f } },
        { 384, 4, { 0xaf, 0x45, 0xd2, 0xe3, 0x76, 0x48, 0x40, 0x31 }, { 0x4e, 0xce, 0x08, 0x44, 0x85, 0x81, 0x3e, 0x90 } },
        { 512, 4, { 0x16, 0x4b, 0x7a, 0x7b, 0xfc, 0xf8, 0x19, 0xe2 }, { 0x80, 0xb2, 0x42, 0x63, 0xc7, 0xc1, 0xa3, 0xeb } },
    };
    static const char text[] = "what do ya want for nothing?", other[] = "Test Using Larger Than Block-Size Key - Hash Key First";
    uint8_t sum[64], key[131];

    memset(key, 0xaa, sizeof key);
    for (unsigned i = 0; i < sizeof known / sizeof known[0]; i++) {
        hmac(known[i].bits, "Jefe", known[i].key, text, sizeof text - 1, sum);
        if (memcmp(sum, known[i].first, 8))
            panic("hmac self-test: the HMAC of the RFC's second example with SHA-%u is not what the RFC has", known[i].bits);
        hmac(known[i].bits, key, sizeof key, other, sizeof other - 1, sum);
        if (memcmp(sum, known[i].longer, 8))
            panic("hmac self-test: the HMAC with a key that is longer than a block is wrong, with SHA-%u", known[i].bits);
    }
    /* A key that is exactly as long as a block is used as it is, and one that is a byte longer is its own sum first. */
    {
        static const uint8_t exact[8] = { 0x54, 0x31, 0xcc, 0x41, 0x83, 0x0b, 0xee, 0x78 };
        static const uint8_t over[8] = { 0xb8, 0x51, 0x0e, 0xc6, 0xc8, 0x6f, 0x16, 0xd7 };
        static const uint8_t large[8] = { 0x45, 0xa2, 0x35, 0x35, 0x53, 0xc2, 0x4e, 0xb6 };

        for (unsigned i = 0; i < sizeof key; i++)
            key[i] = (uint8_t)i;
        hmac(256, key, 64, text, sizeof text - 1, sum);
        if (memcmp(sum, exact, 8))
            panic("hmac self-test: a key that is as long as a block of SHA-256 is not used as it is");
        hmac(256, key, 65, text, sizeof text - 1, sum);
        if (memcmp(sum, over, 8))
            panic("hmac self-test: a key that is a byte longer than a block of SHA-256 is not summed first");
        hmac(512, key, 128, text, sizeof text - 1, sum);
        if (memcmp(sum, large, 8))
            panic("hmac self-test: a key that is as long as a block of SHA-512 is not used as it is");
    }
    if (digest_bytes(256) != 32 || digest_bytes(384) != 48 || digest_bytes(512) != 64 || digest_bytes(1) != 0)
        panic("hmac self-test: a sum is not as long as its name says");
}
