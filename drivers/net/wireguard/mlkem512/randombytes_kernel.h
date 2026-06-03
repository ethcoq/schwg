#include <linux/random.h>

static inline void randombytes(uint8_t *out, size_t outlen) {
	get_random_bytes(out, outlen);
}