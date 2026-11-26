/*
 * tmst.h - arithmetic on the gateway concentrator counter (tmst).
 *
 * tmst is a free-running 32-bit counter in microseconds. It wraps to zero
 * every 2^32 us (about 71.6 minutes). All differences must use modular
 * arithmetic, or results near a wrap are wrong.
 */
#ifndef DLS_TMST_H
#define DLS_TMST_H

#include <stdint.h>

/* Microseconds in one second. */
#define DLS_US_PER_S 1000000U

/*
 * Signed difference (later - earlier) in microseconds, modulo 2^32.
 * The result is correct when the real distance is less than 2^31 us
 * (about 35.8 minutes) in either direction.
 */
int32_t dls_tmst_diff(uint32_t later, uint32_t earlier);

/* Add a signed offset in microseconds to a tmst value, modulo 2^32. */
uint32_t dls_tmst_add(uint32_t tmst, int32_t offset_us);

#endif /* DLS_TMST_H */
