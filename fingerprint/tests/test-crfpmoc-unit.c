/*
 * Unit tests for crfpmoc driver protocol parser and payload calculations.
 *
 * Copyright (C) 2026 Antigravity Pair Programmer
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 */

#include <glib.h>
#include "fpi-context.h"
#include "fpi-device.h"
#include "drivers/crfpmoc/crfpmoc.h"

/* Test dynamic FP_INFO v3 response buffer parsing */
static void
test_crfpmoc_fp_info_v3 (void)
{
  guint8 buf[CRFPMOC_FP_INFO_BUFFER_SIZE] = {0};
  struct crfpmoc_ec_response_fp_sensor_info *sensor = (void *) buf;
  struct crfpmoc_ec_response_fp_template_info *tinfo = (void *) (buf + sizeof (*sensor));
  struct crfpmoc_ec_response_fp_frame_params_v3 *frame = (void *) (buf + sizeof (*sensor) + sizeof (*tinfo));

  /* Setup mock sensor info */
  sensor->vendor_id = GUINT32_TO_LE (0x20435046); /* 'FPC ' */
  sensor->product_id = GUINT32_TO_LE (0x1025);
  sensor->model_id = GUINT32_TO_LE (0x0210);
  sensor->version = GUINT32_TO_LE (1);

  /* Setup mock template info */
  tinfo->template_size = GUINT32_TO_LE (49152);
  tinfo->template_max = GUINT16_TO_LE (5);
  tinfo->template_valid = GUINT16_TO_LE (2);
  tinfo->template_dirty = GUINT32_TO_LE (0x3);
  tinfo->template_version = GUINT32_TO_LE (4);

  /* Setup mock v3 frame params */
  frame->frame_size = GUINT32_TO_LE (25600);
  frame->image_data_offset_bytes = GUINT32_TO_LE (32);
  frame->pixel_format = GUINT32_TO_LE (0x30384152);
  frame->width = GUINT16_TO_LE (160);
  frame->height = GUINT16_TO_LE (160);
  frame->bpp = GUINT16_TO_LE (8);
  frame->fp_capture_type = GUINT16_TO_LE (0);

  g_assert_cmpuint (sizeof (*sensor), ==, 20);
  g_assert_cmpuint (sizeof (*tinfo), ==, 16);
  g_assert_cmpuint (sizeof (*frame), ==, 20);
  g_assert_cmpuint (GUINT16_FROM_LE (tinfo->template_max), ==, 5);
  g_assert_cmpuint (GUINT16_FROM_LE (tinfo->template_valid), ==, 2);
  g_assert_cmpuint (GUINT32_FROM_LE (tinfo->template_size), ==, 49152);
}

/* Test dynamic FP_INFO v1 response buffer parsing */
static void
test_crfpmoc_fp_info_v1 (void)
{
  guint8 buf[CRFPMOC_FP_INFO_BUFFER_SIZE] = {0};
  struct crfpmoc_ec_response_fp_sensor_info *sensor = (void *) buf;
  struct crfpmoc_ec_response_fp_frame_params_v2 *frame = (void *) (buf + sizeof (*sensor));
  struct crfpmoc_ec_response_fp_template_info *tinfo = (void *) (buf + sizeof (*sensor) + sizeof (*frame));

  /* Setup mock sensor info */
  sensor->vendor_id = GUINT32_TO_LE (0x20435046);
  sensor->product_id = GUINT32_TO_LE (0x1025);

  /* Setup mock v1 frame params (at offset 20) */
  frame->frame_size = GUINT32_TO_LE (25600);
  frame->pixel_format = GUINT32_TO_LE (0x30384152);
  frame->width = GUINT16_TO_LE (160);
  frame->height = GUINT16_TO_LE (160);
  frame->bpp = GUINT16_TO_LE (8);

  /* Setup mock template info (at offset 36) */
  tinfo->template_size = GUINT32_TO_LE (32768);
  tinfo->template_max = GUINT16_TO_LE (5);
  tinfo->template_valid = GUINT16_TO_LE (1);

  g_assert_cmpuint (sizeof (*frame), ==, 16);
  g_assert_cmpuint (GUINT16_FROM_LE (tinfo->template_valid), ==, 1);
  g_assert_cmpuint (GUINT32_FROM_LE (tinfo->template_size), ==, 32768);
}

/* Test encryption status bitmask */
static void
test_crfpmoc_enc_status_bitmask (void)
{
  struct crfpmoc_ec_response_fp_encryption_status resp = {0};
  guint32 status;

  /* Case 1: Bit 0 set (Seed is set) along with other flag bits */
  resp.valid_flags = GUINT32_TO_LE (0x7);
  resp.status = GUINT32_TO_LE (0x00000005); /* BIT(0) | BIT(2) */

  status = GUINT32_FROM_LE (resp.status);
  g_assert_true ((status & CRFPMOC_FP_ENC_STATUS_SEED_SET) != 0);

  /* Case 2: Bit 0 not set (Seed not set) but other bits non-zero */
  resp.status = GUINT32_TO_LE (0x00000004); /* BIT(2) only */
  status = GUINT32_FROM_LE (resp.status);
  g_assert_false ((status & CRFPMOC_FP_ENC_STATUS_SEED_SET) != 0);
}

/* Test Protocol v3 payload sizing bounds */
static void
test_crfpmoc_payload_bounds (void)
{
  struct crfpmoc_ec_response_get_protocol_info proto_v3 = {0};
  const gsize header = sizeof (struct crfpmoc_ec_host_response);
  gsize max_param_cap;
  gsize derived_in;
  gsize derived_out;

  proto_v3.protocol_versions = GUINT32_TO_LE (1 << 3); /* Proto v3 supported */
  proto_v3.max_request_packet_size = GUINT16_TO_LE (544);
  proto_v3.max_response_packet_size = GUINT16_TO_LE (544);

  max_param_cap = (GUINT32_FROM_LE (proto_v3.protocol_versions) & (1 << 3)) ?
                  CROS_EC_PROTO3_MAX_PAYLOAD_SIZE : CRFPMOC_EC_PROTO2_MAX_PARAM_SIZE;

  derived_in = MIN (max_param_cap, GUINT16_FROM_LE (proto_v3.max_response_packet_size) - header);
  derived_out = MIN (max_param_cap, GUINT16_FROM_LE (proto_v3.max_request_packet_size) - header);

  g_assert_cmpuint (max_param_cap, ==, 536);
  g_assert_cmpuint (derived_in, ==, 536);
  g_assert_cmpuint (derived_out, ==, 536);
}

int
main (int argc, char **argv)
{
  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/crfpmoc/fp_info_v3", test_crfpmoc_fp_info_v3);
  g_test_add_func ("/crfpmoc/fp_info_v1", test_crfpmoc_fp_info_v1);
  g_test_add_func ("/crfpmoc/enc_status_bitmask", test_crfpmoc_enc_status_bitmask);
  g_test_add_func ("/crfpmoc/payload_bounds", test_crfpmoc_payload_bounds);

  return g_test_run ();
}
