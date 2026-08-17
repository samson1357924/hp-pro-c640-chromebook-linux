/*
 * SPDX-License-Identifier: LGPL-2.1-or-later
 *
 * ChromeOS Fingerprint driver for libfprint - EC protocol layouts
 *
 * Copyright (C) 2024 Abhinav Baid <abhinavbaid@gmail.com>
 * Copyright (C) 2024 Felix Niederer <felix@niederer.dev>
 * Copyright (C) 2026 Marco Trevisan (Treviño) <mail@3v1n0.net>
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
 * Pure EC protocol struct layouts and constants, free of any libfprint
 * dependency so the parsing code can be unit-tested standalone. This is
 * the single source of truth for these layouts; crfpmoc.h includes it.
 */

#pragma once

#include <glib.h>
#include <stdint.h>

#define CRFPMOC_FP_INFO_BUFFER_SIZE 512
#define CROS_EC_PROTO3_MAX_PAYLOAD_SIZE 536
#define CRFPMOC_EC_PROTO2_MAX_PARAM_SIZE 0xfc

/* crfpmoc_ec_host_response and crfpmoc_ec_host_request are only here for the size of the struct */
struct crfpmoc_ec_host_response
{
  guint8  struct_version;
  guint8  checksum;
  guint16 result;
  guint16 data_len;
  guint16 reserved;
} __attribute__((packed));

struct crfpmoc_ec_host_request
{
  guint8  struct_version;
  guint8  checksum;
  guint16 command;
  guint8  command_version;
  guint8  reserved;
  guint16 data_len;
} __attribute__((packed));

/* ec_commands.h layout of the EC_CMD_FP_INFO response */
struct crfpmoc_ec_response_fp_sensor_info
{
  guint32 vendor_id;
  guint32 product_id;
  guint32 model_id;
  guint32 version;
  guint16 num_capture_types;
  guint16 errors;
} __attribute__((packed));

/* Legacy flat EC_CMD_FP_INFO layout (32 bytes) without template info.
 * Real v1 responses already carry template info (48 bytes); this layout
 * predates it and is only accepted defensively, failing closed for any
 * operation that needs template info.
 */
struct crfpmoc_ec_response_fp_info_v0
{
  guint32 vendor_id;
  guint32 product_id;
  guint32 model_id;
  guint32 version;
  guint32 frame_size;
  guint32 pixel_format;
  guint16 width;
  guint16 height;
  guint16 bpp;
  guint16 errors;
} __attribute__((packed));

struct crfpmoc_ec_response_fp_template_info
{
  guint32 template_size;
  guint16 template_max;
  guint16 template_valid;
  guint32 template_dirty;
  guint32 template_version;
} __attribute__((packed));

/* v2 layout (16 bytes): frame_size@0, pixel_format@4, width@8, height@10, bpp@12 */
struct crfpmoc_ec_response_fp_frame_params_v2
{
  guint32 frame_size;
  guint32 pixel_format;
  guint16 width;
  guint16 height;
  guint16 bpp;
  guint16 fp_capture_type;
} __attribute__((packed));

/* v3 layout (20 bytes): frame_size@0, image_data_offset_bytes@4, pixel_format@8, width@12, height@14, bpp@16 */
struct crfpmoc_ec_response_fp_frame_params_v3
{
  guint32 frame_size;
  guint32 image_data_offset_bytes;
  guint32 pixel_format;
  guint16 width;
  guint16 height;
  guint16 bpp;
  guint16 fp_capture_type;
} __attribute__((packed));

struct crfpmoc_ec_response_get_protocol_info
{
  /* Fields which exist if at least protocol version 3 supported */
  guint32 protocol_versions;
  guint16 max_request_packet_size;
  guint16 max_response_packet_size;
  guint32 flags;
} __attribute__((packed));

struct crfpmoc_ec_params_fp_template
{
  guint32 offset;
  guint32 size;
  guint8  data[];
} __attribute__((packed));

/* Minimal error domain fallback so the protocol parsing module can be
 * compiled and tested without libfprint; the real FP_DEVICE_ERROR from
 * fpi-device.h takes precedence in the driver build. Values and the
 * quark name mirror libfprint's so errors carry the same domain.
 */
#ifndef FP_DEVICE_ERROR
typedef enum
{
  FP_DEVICE_ERROR_GENERAL = 0,
  FP_DEVICE_ERROR_NOT_SUPPORTED = 1,
  FP_DEVICE_ERROR_NOT_OPEN = 2,
  FP_DEVICE_ERROR_ALREADY_OPEN = 3,
  FP_DEVICE_ERROR_BUSY = 4,
  FP_DEVICE_ERROR_PROTO = 5,
} FpDeviceErrorFallback;

static GQuark
fp_device_error_quark (void)
{
  return g_quark_from_static_string ("fp-device-error-quark");
}

#define FP_DEVICE_ERROR (fp_device_error_quark ())
#endif
