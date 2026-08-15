/*
 * SPDX-License-Identifier: LGPL-2.1-or-later
 *
 * Standalone Unit Tests for ChromeOS Match-on-Chip (crfpmoc) Driver
 *
 * Copyright (C) 2026 Samson <https://github.com/samson1357924>
 * Copyright (C) 2026 HP Pro c640 Linux Enablement Contributors
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, see <https://www.gnu.org/licenses/>.
 */

#include <glib.h>
#include <stdint.h>
#include <string.h>

#include "mock-libfprint.h"

/* ChromeOS EC MoC Protocol Definitions */
#define CRFPMOC_EC_COMMAND_PROTOCOL_3  3
#define CRFPMOC_EC_COMMAND_PROTOCOL_1  1

#define CRFPMOC_EC_MAX_PACKET_SIZE     544
#define CRFPMOC_FP_ENC_STATUS_SEED_SET BIT(0)

#pragma pack(push, 1)
struct crfpmoc_ec_host_response {
    uint8_t  struct_version;
    uint8_t  checksum;
    uint16_t result;
    uint16_t data_len;
    uint16_t reserved;
};

struct crfpmoc_ec_response_fp_info_v3 {
    /* Sensor Information */
    uint32_t sensor_id;
    uint16_t width;
    uint16_t height;
    uint16_t bpp;
    uint16_t errors;
    /* Template Information */
    uint16_t version;
    uint16_t num_templates;
    /* Frame Parameters */
    uint32_t frame_size;
    uint16_t pixel_format;
    uint16_t flags;
};

struct crfpmoc_ec_response_fp_info_v1 {
    uint32_t vendor_id;
    uint32_t product_id;
    uint32_t model_id;
    uint32_t version;
    uint32_t frame_size;
    uint32_t pixel_format;
    uint16_t width;
    uint16_t height;
    uint16_t bpp;
    uint16_t errors;
};
#pragma pack(pop)

/* Test 1: Verify struct sizes and packed alignments for Protocol v3 */
static void test_crfpmoc_fp_info_v3(void) {
    g_assert_cmpuint(sizeof(struct crfpmoc_ec_host_response), ==, 8);
    g_assert_cmpuint(sizeof(struct crfpmoc_ec_response_fp_info_v3), ==, 24);

    struct crfpmoc_ec_response_fp_info_v3 info;
    memset(&info, 0, sizeof(info));
    info.sensor_id = GUINT32_TO_LE(0x1025); /* FPC1025 */
    info.width = GUINT16_TO_LE(160);
    info.height = GUINT16_TO_LE(160);
    info.bpp = GUINT16_TO_LE(8);
    info.num_templates = GUINT16_TO_LE(5);

    g_assert_cmpuint(GUINT32_FROM_LE(info.sensor_id), ==, 0x1025);
    g_assert_cmpuint(GUINT16_FROM_LE(info.width), ==, 160);
    g_assert_cmpuint(GUINT16_FROM_LE(info.height), ==, 160);
    g_assert_cmpuint(GUINT16_FROM_LE(info.num_templates), ==, 5);
}

/* Test 2: Verify struct sizes and packed alignments for Protocol v1 legacy fallback */
static void test_crfpmoc_fp_info_v1(void) {
    g_assert_cmpuint(sizeof(struct crfpmoc_ec_response_fp_info_v1), ==, 32);

    struct crfpmoc_ec_response_fp_info_v1 info1;
    memset(&info1, 0, sizeof(info1));
    info1.vendor_id = GUINT32_TO_LE(0x18d1); /* Google */
    info1.product_id = GUINT32_TO_LE(0x5002);
    info1.width = GUINT16_TO_LE(160);
    info1.height = GUINT16_TO_LE(160);

    g_assert_cmpuint(GUINT32_FROM_LE(info1.vendor_id), ==, 0x18d1);
    g_assert_cmpuint(GUINT32_FROM_LE(info1.product_id), ==, 0x5002);
    g_assert_cmpuint(GUINT16_FROM_LE(info1.width), ==, 160);
    g_assert_cmpuint(GUINT16_FROM_LE(info1.height), ==, 160);
}

/* Test 3: Encryption Status Bitmask */
static void test_crfpmoc_enc_status_bitmask(void) {
    uint32_t enc_flags = 0;
    g_assert_false(enc_flags & CRFPMOC_FP_ENC_STATUS_SEED_SET);

    enc_flags |= CRFPMOC_FP_ENC_STATUS_SEED_SET;
    g_assert_true(enc_flags & CRFPMOC_FP_ENC_STATUS_SEED_SET);
}

/* Test 4: Maximum Payload calculation bounds */
static void test_crfpmoc_payload_bounds(void) {
    size_t max_payload = CRFPMOC_EC_MAX_PACKET_SIZE - sizeof(struct crfpmoc_ec_host_response);
    g_assert_cmpuint(max_payload, ==, 536);
    g_assert_cmpuint(max_payload, >, sizeof(struct crfpmoc_ec_response_fp_info_v3));
}

int main(int argc, char *argv[]) {
    g_test_init(&argc, &argv, NULL);

    g_test_add_func("/crfpmoc/fp_info_v3_packed", test_crfpmoc_fp_info_v3);
    g_test_add_func("/crfpmoc/fp_info_v1_packed", test_crfpmoc_fp_info_v1);
    g_test_add_func("/crfpmoc/encryption_flags", test_crfpmoc_enc_status_bitmask);
    g_test_add_func("/crfpmoc/payload_bounds", test_crfpmoc_payload_bounds);

    return g_test_run();
}
