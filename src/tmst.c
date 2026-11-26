/*
 * tmst.c - arithmetic on the gateway concentrator counter (tmst).
 */
#include "dls/tmst.h"

int32_t dls_tmst_diff(uint32_t later, uint32_t earlier)
{
    /* Unsigned subtraction is defined modulo 2^32 in C. */
    uint32_t d = later - earlier;

    /*
     * Map [0, 2^32) to [-2^31, 2^31) without an implementation-defined
     * conversion of a value above INT32_MAX.
     */
    if (d <= (uint32_t)INT32_MAX) {
        return (int32_t)d;
    }
    return -(int32_t)(UINT32_MAX - d) - 1;
}

uint32_t dls_tmst_add(uint32_t tmst, int32_t offset_us)
{
    if (offset_us >= 0) {
        return tmst + (uint32_t)offset_us;
    }
    /* -(offset + 1) + 1 avoids overflow for INT32_MIN. */
    return tmst - ((uint32_t)(-(offset_us + 1)) + 1U);
}
