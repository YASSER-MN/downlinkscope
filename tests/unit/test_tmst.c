/*
 * test_tmst.c - unit tests for the tmst counter arithmetic.
 */
#include "dls/tmst.h"
#include "unity.h"

void setUp(void) {}
void tearDown(void) {}

static void test_diff_without_wrap(void)
{
    TEST_ASSERT_EQUAL_INT32(1000000, dls_tmst_diff(3000000U, 2000000U));
    TEST_ASSERT_EQUAL_INT32(-1000000, dls_tmst_diff(2000000U, 3000000U));
    TEST_ASSERT_EQUAL_INT32(0, dls_tmst_diff(42U, 42U));
}

static void test_diff_across_wrap(void)
{
    /* Uplink 0.5 s before the wrap, order 0.5 s after it: 1 s later. */
    uint32_t up = UINT32_MAX - 499999U;
    uint32_t order = 500000U;
    TEST_ASSERT_EQUAL_INT32(1000000, dls_tmst_diff(order, up));
    TEST_ASSERT_EQUAL_INT32(-1000000, dls_tmst_diff(up, order));
}

static void test_diff_limits(void)
{
    TEST_ASSERT_EQUAL_INT32(INT32_MAX, dls_tmst_diff((uint32_t)INT32_MAX, 0U));
    TEST_ASSERT_EQUAL_INT32(INT32_MIN, dls_tmst_diff(0x80000000U, 0U));
    TEST_ASSERT_EQUAL_INT32(-1, dls_tmst_diff(0U, 1U));
}

static void test_add_wraps(void)
{
    /* RX1 target 1 s after an uplink that ends 0.5 s before the wrap. */
    TEST_ASSERT_EQUAL_UINT32(500000U, dls_tmst_add(UINT32_MAX - 499999U, 1000000));
    TEST_ASSERT_EQUAL_UINT32(UINT32_MAX - 499999U, dls_tmst_add(500000U, -1000000));
    TEST_ASSERT_EQUAL_UINT32(0x80000000U, dls_tmst_add(0U, INT32_MIN));
}

static void test_add_then_diff_round_trip(void)
{
    const uint32_t bases[] = {0U, 1U, 123456789U, 0x7FFFFFFFU, 0x80000000U, UINT32_MAX};
    const int32_t offsets[] = {0, 1, -1, 1000000, -2000000, INT32_MAX, INT32_MIN};
    for (size_t i = 0; i < sizeof bases / sizeof bases[0]; i++) {
        for (size_t j = 0; j < sizeof offsets / sizeof offsets[0]; j++) {
            uint32_t later = dls_tmst_add(bases[i], offsets[j]);
            TEST_ASSERT_EQUAL_INT32(offsets[j], dls_tmst_diff(later, bases[i]));
        }
    }
}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_diff_without_wrap);
    RUN_TEST(test_diff_across_wrap);
    RUN_TEST(test_diff_limits);
    RUN_TEST(test_add_wraps);
    RUN_TEST(test_add_then_diff_round_trip);
    return UNITY_END();
}
