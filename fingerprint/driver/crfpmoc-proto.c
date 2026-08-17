/*
 * SPDX-License-Identifier: LGPL-2.1-or-later
 *
 * ChromeOS Fingerprint driver for libfprint - pure protocol parsing
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

#include "crfpmoc-proto.h"

gsize
crfpmoc_proto_template_info_offset (gint version)
{
  if (version >= 2)
    return sizeof (struct crfpmoc_ec_response_fp_sensor_info);
  return 0;
}

gboolean
crfpmoc_proto_parse_fp_info (gconstpointer       buf,
                             gsize                len,
                             gint                 version,
                             CrfpMocFpInfoParsed *out,
                             GError             **error)
{
  const guint8 *p = buf;
  const struct crfpmoc_ec_response_fp_sensor_info *sensor;
  const struct crfpmoc_ec_response_fp_template_info *tinfo;
  const struct crfpmoc_ec_response_fp_frame_params_v2 *frame_v2;
  const struct crfpmoc_ec_response_fp_frame_params_v3 *frame_v3;
  const struct crfpmoc_ec_response_fp_info_v0 *v0;
  gsize need;

  g_return_val_if_fail (buf != NULL, FALSE);
  g_return_val_if_fail (out != NULL, FALSE);

  switch (version)
    {
    case 1:
      need = sizeof (*v0);
      break;
    case 2:
      need = sizeof (*sensor) + sizeof (*tinfo) + sizeof (*frame_v2);
      break;
    case 3:
      need = sizeof (*sensor) + sizeof (*tinfo) + sizeof (*frame_v3);
      break;
    default:
      g_set_error (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_PROTO,
                   "EC_CMD_FP_INFO v%d response layout is not supported", version);
      return FALSE;
    }

  if (len < need)
    {
      g_set_error (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_PROTO,
                   "EC_CMD_FP_INFO v%d response truncated (%zu bytes, need %zu)",
                   version, len, need);
      return FALSE;
    }

  memset (out, 0, sizeof (*out));

  if (version == 1)
    {
      v0 = (const struct crfpmoc_ec_response_fp_info_v0 *) p;
      out->vendor_id = GUINT32_FROM_LE (v0->vendor_id);
      out->product_id = GUINT32_FROM_LE (v0->product_id);
      out->model_id = GUINT32_FROM_LE (v0->model_id);
      out->version = GUINT32_FROM_LE (v0->version);
      out->frame_size = GUINT32_FROM_LE (v0->frame_size);
      out->pixel_format = GUINT32_FROM_LE (v0->pixel_format);
      out->width = GUINT16_FROM_LE (v0->width);
      out->height = GUINT16_FROM_LE (v0->height);
      out->bpp = GUINT16_FROM_LE (v0->bpp);
      out->errors = GUINT16_FROM_LE (v0->errors);
      out->has_template_info = FALSE;
      return TRUE;
    }

  sensor = (const struct crfpmoc_ec_response_fp_sensor_info *) p;
  out->vendor_id = GUINT32_FROM_LE (sensor->vendor_id);
  out->product_id = GUINT32_FROM_LE (sensor->product_id);
  out->model_id = GUINT32_FROM_LE (sensor->model_id);
  out->version = GUINT32_FROM_LE (sensor->version);
  out->errors = GUINT16_FROM_LE (sensor->errors);

  tinfo = (const struct crfpmoc_ec_response_fp_template_info *) (p + sizeof (*sensor));
  out->has_template_info = TRUE;
  out->template_size = GUINT32_FROM_LE (tinfo->template_size);
  out->template_max = GUINT16_FROM_LE (tinfo->template_max);
  out->template_valid = GUINT16_FROM_LE (tinfo->template_valid);
  out->template_dirty = GUINT32_FROM_LE (tinfo->template_dirty);
  out->template_version = GUINT32_FROM_LE (tinfo->template_version);

  if (version == 3)
    {
      frame_v3 = (const struct crfpmoc_ec_response_fp_frame_params_v3 *) (p + sizeof (*sensor) + sizeof (*tinfo));
      out->frame_size = GUINT32_FROM_LE (frame_v3->frame_size);
      out->pixel_format = GUINT32_FROM_LE (frame_v3->pixel_format);
      out->width = GUINT16_FROM_LE (frame_v3->width);
      out->height = GUINT16_FROM_LE (frame_v3->height);
      out->bpp = GUINT16_FROM_LE (frame_v3->bpp);
    }
  else
    {
      frame_v2 = (const struct crfpmoc_ec_response_fp_frame_params_v2 *) (p + sizeof (*sensor) + sizeof (*tinfo));
      out->frame_size = GUINT32_FROM_LE (frame_v2->frame_size);
      out->pixel_format = GUINT32_FROM_LE (frame_v2->pixel_format);
      out->width = GUINT16_FROM_LE (frame_v2->width);
      out->height = GUINT16_FROM_LE (frame_v2->height);
      out->bpp = GUINT16_FROM_LE (frame_v2->bpp);
    }

  return TRUE;
}

gboolean
crfpmoc_proto_parse_max_size (struct crfpmoc_ec_response_get_protocol_info *protocol_info,
                              guint16                                      *max_insize,
                              guint16                                      *max_outsize,
                              GError                                      **error)
{
  const gsize header = sizeof (struct crfpmoc_ec_host_response);
  const gsize min_out = offsetof (struct crfpmoc_ec_params_fp_template, data) + 4 + 1;
  gsize max_param_cap;
  gsize derived_in;
  gsize derived_out;
  guint16 req_size, resp_size;

  g_return_val_if_fail (protocol_info != NULL, FALSE);

  req_size = GUINT16_FROM_LE (protocol_info->max_request_packet_size);
  resp_size = GUINT16_FROM_LE (protocol_info->max_response_packet_size);

  if (resp_size < header || req_size < header)
    {
      g_set_error (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_PROTO,
                   "Device reported packet sizes smaller than the protocol "
                   "header (in %u, out %u, header %zu)",
                   resp_size, req_size, header);
      return FALSE;
    }

  max_param_cap = (GUINT32_FROM_LE (protocol_info->protocol_versions) & (1 << 3)) ?
                  CROS_EC_PROTO3_MAX_PAYLOAD_SIZE : CRFPMOC_EC_PROTO2_MAX_PARAM_SIZE;

  derived_in = MIN (max_param_cap, resp_size - header);
  derived_out = MIN (max_param_cap, req_size - header);

  if (derived_in == 0)
    {
      g_set_error_literal (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_PROTO,
                           "Device reported max incoming payload of zero bytes");
      return FALSE;
    }

  if (derived_out < min_out)
    {
      g_set_error (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_PROTO,
                   "Device reported max outgoing payload %zu too small to "
                   "carry a template chunk (need at least %zu)",
                   derived_out, min_out);
      return FALSE;
    }

  if (max_insize)
    *max_insize = derived_in;
  if (max_outsize)
    *max_outsize = derived_out;

  return TRUE;
}