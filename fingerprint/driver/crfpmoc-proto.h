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
 *
 * This module contains only the EC protocol layout/parsing logic and is
 * intentionally free of any libfprint dependency so it can be compiled
 * and unit-tested standalone.
 */

#pragma once

#include <glib.h>

#include "crfpmoc-proto-structs.h"

G_BEGIN_DECLS

typedef struct
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

  gboolean has_template_info;
  guint32 template_size;
  guint16 template_max;
  guint16 template_valid;
  guint32 template_dirty;
  guint32 template_version;
} CrfpMocFpInfoParsed;

/* Byte offset of the template info block within an FP_INFO response of
 * the given version, or 0 if that version's layout has no template info
 * (legacy flat layout). */
gsize crfpmoc_proto_template_info_offset (gint version);

/* Parse an EC_CMD_FP_INFO response with strict bounds checking.
 * Accepts protocol versions 1 (legacy flat layout), 2 and 3. Fails with
 * a protocol error on truncated responses or unknown versions.
 */
gboolean crfpmoc_proto_parse_fp_info (gconstpointer       buf,
                                      gsize                len,
                                      gint                 version,
                                      CrfpMocFpInfoParsed *out,
                                      GError             **error);

/* Parse and validate the max in/out payload sizes from a protocol info
 * response, clamping to the driver's transfer buffer limits and failing
 * on packet sizes too small to be usable.
 */
gboolean crfpmoc_proto_parse_max_size (struct crfpmoc_ec_response_get_protocol_info *protocol_info,
                                       guint16                                      *max_insize,
                                       guint16                                      *max_outsize,
                                       GError                                      **error);

G_END_DECLS
