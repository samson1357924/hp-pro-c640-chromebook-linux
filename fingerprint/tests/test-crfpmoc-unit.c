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
 *
 * These tests exercise the real protocol parsing code
 * (crfpmoc-proto.c / crfpmoc-proto-structs.h) rather than duplicated
 * test-only definitions.
 */

#include <glib.h>
#include <stdint.h>
#include <string.h>

#include "crfpmoc-proto.h"

/* Test 1: Verify real struct sizes and packed alignments */
static void
test_crfpmoc_proto_struct_sizes (void)
{
  g_assert_cmpuint (sizeof (struct crfpmoc_ec_host_response), ==, 8);
  g_assert_cmpuint (sizeof (struct crfpmoc_ec_host_request), ==, 8);
  g_assert_cmpuint (sizeof (struct crfpmoc_ec_response_fp_sensor_info), ==, 20);
  g_assert_cmpuint (sizeof (struct crfpmoc_ec_response_fp_info_v0), ==, 32);
  g_assert_cmpuint (sizeof (struct crfpmoc_ec_response_fp_template_info), ==, 16);
  g_assert_cmpuint (sizeof (struct crfpmoc_ec_response_fp_frame_params_v2), ==, 16);
  g_assert_cmpuint (sizeof (struct crfpmoc_ec_response_fp_frame_params_v3), ==, 20);
  g_assert_cmpuint (sizeof (struct crfpmoc_ec_response_get_protocol_info), ==, 12);
  g_assert_cmpuint (offsetof (struct crfpmoc_ec_params_fp_template, data), ==, 8);
}

/* Test 2: Template info block offset per version */
static void
test_crfpmoc_proto_template_info_offset (void)
{
  g_assert_cmpuint (crfpmoc_proto_template_info_offset (0), ==, 0);
  g_assert_cmpuint (crfpmoc_proto_template_info_offset (1), ==, 0);
  g_assert_cmpuint (crfpmoc_proto_template_info_offset (2),
                    ==, sizeof (struct crfpmoc_ec_response_fp_sensor_info));
  g_assert_cmpuint (crfpmoc_proto_template_info_offset (3),
                    ==, sizeof (struct crfpmoc_ec_response_fp_sensor_info));
}

/* Test 3: v1 legacy flat layout parsing (sensor + frame fields, no
 * template info). Also guards the historical bug where v1 was parsed as
 * sensor_info + frame_params_v2, producing garbage width/height and
 * reading past the 32-byte v1 response. */
static void
test_crfpmoc_proto_parse_fp_info_v1 (void)
{
  struct crfpmoc_ec_response_fp_info_v0 raw;
  CrfpMocFpInfoParsed parsed;
  g_autoptr(GError) error = NULL;

  memset (&raw, 0, sizeof (raw));
  raw.vendor_id = GUINT32_TO_LE (0x18d1);
  raw.product_id = GUINT32_TO_LE (0x5002);
  raw.model_id = GUINT32_TO_LE (0x1025);
  raw.version = GUINT32_TO_LE (1);
  raw.frame_size = GUINT32_TO_LE (25600);
  raw.pixel_format = GUINT32_TO_LE (0x31303130);
  raw.width = GUINT16_TO_LE (160);
  raw.height = GUINT16_TO_LE (160);
  raw.bpp = GUINT16_TO_LE (8);
  raw.errors = GUINT16_TO_LE (0);

  g_assert_true (crfpmoc_proto_parse_fp_info (&raw, sizeof (raw), 1, &parsed, &error));
  g_assert_no_error (error);
  g_assert_cmpuint (parsed.vendor_id, ==, 0x18d1);
  g_assert_cmpuint (parsed.product_id, ==, 0x5002);
  g_assert_cmpuint (parsed.model_id, ==, 0x1025);
  g_assert_cmpuint (parsed.frame_size, ==, 25600);
  g_assert_cmpuint (parsed.pixel_format, ==, 0x31303130);
  g_assert_cmpuint (parsed.width, ==, 160);
  g_assert_cmpuint (parsed.height, ==, 160);
  g_assert_cmpuint (parsed.bpp, ==, 8);
  g_assert_false (parsed.has_template_info);
}

/* Test 4: v2 layout parsing */
static void
test_crfpmoc_proto_parse_fp_info_v2 (void)
{
  guint8 buf[52];
  CrfpMocFpInfoParsed parsed;
  g_autoptr(GError) error = NULL;

  struct crfpmoc_ec_response_fp_sensor_info *sensor = (void *) buf;
  struct crfpmoc_ec_response_fp_template_info *tinfo = (void *) (buf + sizeof (*sensor));
  struct crfpmoc_ec_response_fp_frame_params_v2 *frame = (void *) (buf + sizeof (*sensor) + sizeof (*tinfo));

  memset (buf, 0, sizeof (buf));
  sensor->vendor_id = GUINT32_TO_LE (0x1025);
  sensor->model_id = GUINT32_TO_LE (0x210);
  tinfo->template_size = GUINT32_TO_LE (1960);
  tinfo->template_max = GUINT16_TO_LE (5);
  tinfo->template_valid = GUINT16_TO_LE (2);
  tinfo->template_dirty = GUINT32_TO_LE (0x3);
  tinfo->template_version = GUINT32_TO_LE (4);
  frame->frame_size = GUINT32_TO_LE (25600);
  frame->pixel_format = GUINT32_TO_LE (0x31303130);
  frame->width = GUINT16_TO_LE (160);
  frame->height = GUINT16_TO_LE (160);
  frame->bpp = GUINT16_TO_LE (8);

  g_assert_true (crfpmoc_proto_parse_fp_info (buf, sizeof (buf), 2, &parsed, &error));
  g_assert_no_error (error);
  g_assert_true (parsed.has_template_info);
  g_assert_cmpuint (parsed.vendor_id, ==, 0x1025);
  g_assert_cmpuint (parsed.template_size, ==, 1960);
  g_assert_cmpuint (parsed.template_max, ==, 5);
  g_assert_cmpuint (parsed.template_valid, ==, 2);
  g_assert_cmpuint (parsed.template_dirty, ==, 0x3);
  g_assert_cmpuint (parsed.template_version, ==, 4);
  g_assert_cmpuint (parsed.frame_size, ==, 25600);
  g_assert_cmpuint (parsed.pixel_format, ==, 0x31303130);
  g_assert_cmpuint (parsed.width, ==, 160);
  g_assert_cmpuint (parsed.height, ==, 160);
  g_assert_cmpuint (parsed.bpp, ==, 8);
}

/* Test 5: v3 layout parsing (20-byte frame params with
 * image_data_offset_bytes) */
static void
test_crfpmoc_proto_parse_fp_info_v3 (void)
{
  guint8 buf[56];
  CrfpMocFpInfoParsed parsed;
  g_autoptr(GError) error = NULL;

  struct crfpmoc_ec_response_fp_sensor_info *sensor = (void *) buf;
  struct crfpmoc_ec_response_fp_template_info *tinfo = (void *) (buf + sizeof (*sensor));
  struct crfpmoc_ec_response_fp_frame_params_v3 *frame = (void *) (buf + sizeof (*sensor) + sizeof (*tinfo));

  memset (buf, 0, sizeof (buf));
  sensor->vendor_id = GUINT32_TO_LE (0x1025);
  frame->frame_size = GUINT32_TO_LE (51200);
  frame->image_data_offset_bytes = GUINT32_TO_LE (16);
  frame->pixel_format = GUINT32_TO_LE (0x31303130);
  frame->width = GUINT16_TO_LE (160);
  frame->height = GUINT16_TO_LE (160);
  frame->bpp = GUINT16_TO_LE (8);
  tinfo->template_size = GUINT32_TO_LE (1960);

  g_assert_true (crfpmoc_proto_parse_fp_info (buf, sizeof (buf), 3, &parsed, &error));
  g_assert_no_error (error);
  g_assert_true (parsed.has_template_info);
  g_assert_cmpuint (parsed.frame_size, ==, 51200);
  g_assert_cmpuint (parsed.pixel_format, ==, 0x31303130);
  g_assert_cmpuint (parsed.width, ==, 160);
  g_assert_cmpuint (parsed.height, ==, 160);
  g_assert_cmpuint (parsed.bpp, ==, 8);
  g_assert_cmpuint (parsed.template_size, ==, 1960);
}

/* Test 6: truncated responses and unknown versions must fail closed */
static void
test_crfpmoc_proto_parse_fp_info_bounds (void)
{
  guint8 buf[64];
  CrfpMocFpInfoParsed parsed;
  g_autoptr(GError) error = NULL;

  memset (buf, 0, sizeof (buf));

  /* v1 truncated below its 32-byte layout */
  g_assert_false (crfpmoc_proto_parse_fp_info (buf, 31, 1, &parsed, &error));
  g_assert_error (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_PROTO);
  g_clear_error (&error);

  /* v2 truncated below 52 bytes */
  g_assert_false (crfpmoc_proto_parse_fp_info (buf, 51, 2, &parsed, &error));
  g_assert_error (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_PROTO);
  g_clear_error (&error);

  /* v3 truncated below 56 bytes */
  g_assert_false (crfpmoc_proto_parse_fp_info (buf, 55, 3, &parsed, &error));
  g_assert_error (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_PROTO);
  g_clear_error (&error);

  /* Unknown versions are rejected, not parsed with a guessed layout */
  g_assert_false (crfpmoc_proto_parse_fp_info (buf, sizeof (buf), 0, &parsed, &error));
  g_assert_error (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_PROTO);
  g_clear_error (&error);

  g_assert_false (crfpmoc_proto_parse_fp_info (buf, sizeof (buf), 4, &parsed, &error));
  g_assert_error (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_PROTO);
  g_clear_error (&error);
}

/* Test 7: max payload size parsing and clamping */
static void
test_crfpmoc_proto_parse_max_size (void)
{
  struct crfpmoc_ec_response_get_protocol_info info;
  guint16 in_size, out_size;
  g_autoptr(GError) error = NULL;

  memset (&info, 0, sizeof (info));

  /* Protocol 3: reported packet sizes clamp to the driver's cap */
  info.protocol_versions = GUINT32_TO_LE (1 << 3);
  info.max_request_packet_size = GUINT16_TO_LE (2000);
  info.max_response_packet_size = GUINT16_TO_LE (2000);
  g_assert_true (crfpmoc_proto_parse_max_size (&info, &in_size, &out_size, &error));
  g_assert_no_error (error);
  g_assert_cmpuint (in_size, ==, CROS_EC_PROTO3_MAX_PAYLOAD_SIZE);
  g_assert_cmpuint (out_size, ==, CROS_EC_PROTO3_MAX_PAYLOAD_SIZE);

  /* Protocol 2: cap is the smaller legacy limit */
  info.protocol_versions = GUINT32_TO_LE (0);
  g_assert_true (crfpmoc_proto_parse_max_size (&info, &in_size, &out_size, &error));
  g_assert_no_error (error);
  g_assert_cmpuint (in_size, ==, CRFPMOC_EC_PROTO2_MAX_PARAM_SIZE);

  /* Header-undersized packet sizes must fail (would underflow) */
  info.max_request_packet_size = GUINT16_TO_LE (4);
  info.max_response_packet_size = GUINT16_TO_LE (2000);
  g_assert_false (crfpmoc_proto_parse_max_size (&info, &in_size, &out_size, &error));
  g_assert_error (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_PROTO);
  g_clear_error (&error);

  /* Zero incoming payload must fail */
  info.max_request_packet_size = GUINT16_TO_LE (1000);
  info.max_response_packet_size = GUINT16_TO_LE (8);
  g_assert_false (crfpmoc_proto_parse_max_size (&info, &in_size, &out_size, &error));
  g_assert_error (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_PROTO);
  g_clear_error (&error);

  /* Outgoing payload too small to carry a template chunk must fail */
  info.max_response_packet_size = GUINT16_TO_LE (1000);
  info.max_request_packet_size = GUINT16_TO_LE (16);
  g_assert_false (crfpmoc_proto_parse_max_size (&info, &in_size, &out_size, &error));
  g_assert_error (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_PROTO);
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/crfpmoc/proto/struct_sizes", test_crfpmoc_proto_struct_sizes);
  g_test_add_func ("/crfpmoc/proto/template_info_offset", test_crfpmoc_proto_template_info_offset);
  g_test_add_func ("/crfpmoc/proto/parse_fp_info_v1", test_crfpmoc_proto_parse_fp_info_v1);
  g_test_add_func ("/crfpmoc/proto/parse_fp_info_v2", test_crfpmoc_proto_parse_fp_info_v2);
  g_test_add_func ("/crfpmoc/proto/parse_fp_info_v3", test_crfpmoc_proto_parse_fp_info_v3);
  g_test_add_func ("/crfpmoc/proto/parse_fp_info_bounds", test_crfpmoc_proto_parse_fp_info_bounds);
  g_test_add_func ("/crfpmoc/proto/parse_max_size", test_crfpmoc_proto_parse_max_size);

  return g_test_run ();
}
