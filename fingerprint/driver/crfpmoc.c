/*
 * SPDX-License-Identifier: LGPL-2.1-or-later
 *
 * ChromeOS Fingerprint driver for libfprint
 *
 * Copyright (C) 2024 Abhinav Baid <abhinavbaid@gmail.com>
 * Copyright (C) 2024 Felix Niederer <felix@niederer.dev>
 * Copyright (C) 2025 Michael Evans <mike.67.442@gmail.com>
 * Copyright (C) 2026 Marco Trevisan (Treviño) <mail@3v1n0.net>
 * Copyright (C) 2026 Samson <https://github.com/samson1357924>
 * Copyright (C) 2026 HP Pro c640 Linux Enablement Contributors
 *
 * This file contains modifications to the upstream crfpmoc driver
 * (50ms polling loop, weak-pointer guards, and re-establishing the
 * FP_CONTEXT / sensor bring-up on every open so fingerprint works after a
 * reboot — see the KEYS_CLEAR_MODE step in the KEYS sub-SSM).
 * Modified: 2026-08-16. See CREDITS.md for details.
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
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#define FP_COMPONENT "crfpmoc"

#include <glib-unix.h>
#include <gio/gunixinputstream.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>

#if defined(__linux__)
#include <sys/random.h>
#endif

#include "crfpmoc.h"
#include "crfpmoc-ec-transfer.h"
#include "crfpmoc-proto.h"

struct _FpiDeviceCrfpMoc
{
  FpDevice parent;
  FpiSsm  *task_ssm;
  FpiSsm  *active_ssm_guard;

  guint16  max_insize;
  guint16  max_outsize;
  guint16  max_templates;
  guint16  template_size;
  gint     fp_info_version;

  guint8   seed[CRFPMOC_FP_CONTEXT_TPM_BYTES];
  guint8   context[CRFPMOC_FP_CONTEXT_USERID_BYTES];

  guint    open_retries;

  int      emul_fd;
};

/* The ChromeOS EC/FPMCU channel is briefly unusable right after S3 resume
 * (empirically the first open attempt fails and the next one ~2 s later
 * succeeds), so retry failed open attempts for a bounded time instead of
 * failing the claim — otherwise the first lock-screen unlock after resume
 * shows no fingerprint prompt. Retries only trigger when open fails; a
 * healthy open completes on the first attempt with no added latency. */
#define CRFPMOC_OPEN_MAX_RETRIES    8
#define CRFPMOC_OPEN_RETRY_DELAY_MS 500

G_DEFINE_TYPE (FpiDeviceCrfpMoc, fpi_device_crfpmoc, FP_TYPE_DEVICE)

static void crfpmoc_finger_up_run_state (FpiSsm   *ssm,
                                         FpDevice *device);
static void crfpmoc_clear_storage_run_state (FpiSsm   *ssm,
                                             FpDevice *device);
static void crfpmoc_keys_run_state (FpiSsm   *ssm,
                                    FpDevice *device);
static void crfpmoc_download_run_state (FpiSsm   *ssm,
                                        FpDevice *device);
static void crfpmoc_upload_run_state (FpiSsm   *ssm,
                                      FpDevice *device);
static void crfpmoc_wait_for_device_idle (FpiSsm *ssm);
static void complete_verification (FpiSsm  *ssm,
                                   FpPrint *matched_print,
                                   FpPrint *scanned_print);
static void crfpmoc_verify_fp_stats_cb (CrfpMocEcTransfer *transfer,
                                        GAsyncResult      *res,
                                        gpointer           user_data);
static void upload_data_free (gpointer data);

/* State machine private data. All state machines get this and it is
 * cleared/freed at the completion of the state machine.
 */
typedef struct
{
  FpiDeviceCrfpMoc *self;
  FpiSsm           *parent_ssm;
  GSource          *timeout;
  GInputStream     *poll_input_stream;

  int               timeout_state;
  guint             poll_source;
  int               clear_step;
  int               idle_attempts;

  gpointer          sub_data;
  GDestroyNotify    sub_data_destroy;
} SubSsmData;

/* Data for the enroll state machine */
typedef struct
{
  int     stage;
  guint32 last_fp_events;
  guint   last_progress_pct;
  guint   last_error_code;
} EnrollData;

/* Data for the download sub-SSM */
typedef struct
{
  int     template_index;
  guint32 offset;
  guint32 buf_offset;
  gsize   remaining;
  guint8 *buffer;
  int     num_attempts;
  guint16 sum;
} DownloadData;

/* Data for the upload sub-SSM */
typedef struct
{
  guint      current_print;
  guint8    *data;
  guint32    offset;
  gsize      remaining;
  guint16    sum;
  GPtrArray *prints;
} UploadData;

/* Data for the keys sub-SSM */
typedef struct
{
  int poll_attempts;
} KeysData;

enum {
  DOWNLOAD_CHUNK,
  DOWNLOAD_FINISHED,
  DOWNLOAD_STATES,
};

enum {
  UPLOAD_NEXT_PRINT,
  UPLOAD_CHUNK,
  UPLOAD_DONE,
  UPLOAD_STATES,
};

enum {
  KEYS_ENC_STATUS,
  KEYS_SET_SEED,
  KEYS_CLEAR_MODE,
  KEYS_CTX_ASYNC,
  KEYS_CTX_POLL,
  KEYS_DONE,
  KEYS_STATES,
};

static const FpIdEntry crfpmoc_id_table[] = {
  {.udev_types = FPI_DEVICE_UDEV_SUBTYPE_MISC, .misc_name = "cros_fp"},
  {.udev_types = 0}
};

/* Clear and free the state machine private data */
static void
subssm_data_free (void *arg)
{
  SubSsmData *data = arg;
  FpiDeviceCrfpMoc *self = data->self;

  if (self && self->active_ssm_guard == data->parent_ssm)
    self->active_ssm_guard = NULL;

  /* Cancel any poll source */
  fp_dbg ("crfpmoc_ssm_data_free: remove poll source %d (ssm %p, parent %p)",
          data->poll_source, data->parent_ssm, data->parent_ssm);
  g_clear_handle_id (&data->poll_source, g_source_remove);

  g_clear_object (&data->poll_input_stream);

  /* Cancel any timeout source */
  g_clear_pointer (&data->timeout, g_source_destroy);

  if (data->sub_data_destroy)
    data->sub_data_destroy (data->sub_data);

  g_free (data);
}

/* Wrapper to start a sub-state machine after adding the private data. The data
 * can be supplied and is required to be crfpmoc_ssm_data or contain it as its
 * first member.
 */
static void
crfpmoc_ssm_start_subsm_full (FpiDeviceCrfpMoc *self,
                              FpiSsm           *ssm,
                              gpointer          sub_data,
                              GDestroyNotify    sub_data_destroy)
{
  SubSsmData *data = NULL;

  g_assert (self->task_ssm != NULL);

  self->active_ssm_guard = ssm;

  data = g_new0 (SubSsmData, 1);
  data->self = self;
  data->parent_ssm = ssm;
  data->sub_data = sub_data;
  data->sub_data_destroy = sub_data_destroy;

  fpi_ssm_set_data (ssm, g_steal_pointer (&data), subssm_data_free);
  fpi_ssm_start_subsm (self->task_ssm, ssm);
}

static void
crfpmoc_ssm_start_subsm (FpiDeviceCrfpMoc *self, FpiSsm *ssm)
{
  crfpmoc_ssm_start_subsm_full (self, ssm, NULL, NULL);
}

/* Wrapper to start a state machine after adding the private data. The data
 * can be supplied and is required to be crfpmoc_ssm_data or contain it as its
 * first member.
 */
static void
crfpmoc_ssm_start (FpiDeviceCrfpMoc         *self,
                   FpiSsm                   *ssm,
                   FpiSsmCompletedCallback   cb)
{
  SubSsmData *data = g_new0 (SubSsmData, 1);

  self->active_ssm_guard = ssm;

  data->self = self;
  data->parent_ssm = ssm;
  fpi_ssm_set_data (ssm, g_steal_pointer (&data), subssm_data_free);
  fpi_ssm_start (ssm, cb);
}

static const gchar *const crfpmoc_meanings[] = {
  "SUCCESS",
  "INVALID_COMMAND",
  "ERROR",
  "INVALID_PARAM",
  "ACCESS_DENIED",
  "INVALID_RESPONSE",
  "INVALID_VERSION",
  "INVALID_CHECKSUM",
  "IN_PROGRESS",
  "UNAVAILABLE",
  "TIMEOUT",
  "OVERFLOW",
  "INVALID_HEADER",
  "REQUEST_TRUNCATED",
  "RESPONSE_TOO_BIG",
  "BUS_ERROR",
  "BUSY",
  "INVALID_HEADER_VERSION",
  "INVALID_HEADER_CRC",
  "INVALID_DATA_CRC",
  "DUP_UNAVAILABLE",
};

const gchar *
crfpmoc_strresult (int i)
{
  if (i < 0 || i >= G_N_ELEMENTS (crfpmoc_meanings))
    return "<unknown>";
  return crfpmoc_meanings[i];
}

static const gchar *const crfpmoc_mkbp_event_names[] = {
  "KEY_MATRIX",
  "HOST_EVENT",
  "SENSOR_FIFO",
  "BUTTON",
  "SWITCH",
  "FINGERPRINT",
  "SYSRQ",
  "HOST_EVENT64",
  "CEC_EVENT",
  "CEC_MESSAGE",
  "DP_ALT_MODE_ENTERED",
  "ONLINE_CALIBRATION",
  "PCHG",
};

static const gchar *
crfpmoc_mkbp_event_strresult (int i)
{
  if (i < 0 || i >= G_N_ELEMENTS (crfpmoc_mkbp_event_names))
    return "<unknown>";
  return crfpmoc_mkbp_event_names[i];
}

static void
crfpmoc_set_print_data (FpPrint *print,
                        guint8  *template,
                        size_t   template_size)
{
  GVariant *fpi_data = NULL;

  fp_dbg ("Setting print data");

  if (template == NULL || template_size == 0)
    {
      fp_warn ("Template is NULL or size is 0, setting empty template");
      template = NULL;
      template_size = 0;
    }

  fpi_data = g_variant_new_fixed_array (G_VARIANT_TYPE_BYTE,
                                        template, template_size,
                                        sizeof (guint8));
  g_object_set (print, "fpi-data", fpi_data, NULL);
}

static gboolean
crfpmoc_get_print_data (FpPrint *print,
                        guint8 **template,
                        size_t  *template_size,
                        GError **error)
{
  g_autoptr(GVariant) fpi_data = NULL;
  const guint8 *template_data = NULL;
  gsize template_data_size = 0;

  if (template)
    *template = NULL;
  if (template_size)
    *template_size = 0;

  g_object_get (print, "fpi-data", &fpi_data, NULL);

  if (!fpi_data)
    {
      g_set_error_literal (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_GENERAL,
                           "No fpi-data found in the print object.");
      return FALSE;
    }

  template_data = g_variant_get_fixed_array (fpi_data,
                                             &template_data_size,
                                             sizeof (guint8));

  if (!template_data || template_data_size == 0)
    {
      g_set_error_literal (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_GENERAL,
                           "Template data is empty in the print object.");
      return FALSE;
    }

  if (template)
    *template = g_memdup2 (template_data, template_data_size);

  if (template_size)
    *template_size = template_data_size;

  return TRUE;
}

gboolean
crfpmoc_umockdev_recording_enabled (FpiDeviceCrfpMoc *self)
{
  return G_UNLIKELY (fpi_device_emulation_mode_enabled (FP_DEVICE (self)) && self->emul_fd != -1);
}

/* Self test uses umockdev for replay of a captured sequence. At this
 * time umockdev supports cros_ec only for replay. We need to create
 * the sequence. Record all the ioctls for replay in the format
 * umockdev requires.
 */
void
crfpmoc_umockdev_record (FpiDeviceCrfpMoc *self, int res,
                         int cmd, void *arg)
{
  g_autoptr(GString) buffer = NULL;
  struct crfpmoc_cros_ec_command_v2 *s_cmd = arg;
  guchar *ptr = arg;
  gsize size;

  g_return_if_fail (crfpmoc_umockdev_recording_enabled (self));
  g_return_if_fail (arg != NULL);

  switch (cmd)
    {
    case CRFPMOC_CROS_EC_DEV_IOCXCMD_V2:
      /* umockdev replays this ioctl as exactly sizeof(header) + insize
       * bytes (header struct followed by the response as the driver
       * reads it from data[0..insize)); any other line length aborts
       * the whole trace, so this MUST stay sizeof + insize. */
      size = (sizeof (*s_cmd) + s_cmd->insize);
      buffer = g_string_sized_new (size * 2);
      g_string_append_printf (buffer, "CROS_EC_DEV_IOCXCMD_V2 %u ",
                              s_cmd->insize);

      /* Send the command. */
      while (size > s_cmd->insize)
        {
          g_string_append_printf (buffer, "%02X", *ptr++);
          size--;
        }

      /* Send the data. If this is a template suppress the actual data for privacy. */
      if (s_cmd->command == CRFPMOC_EC_CMD_FP_FRAME)
        {
          for (gsize i = 0; i < size; i++)
            g_string_append_printf (buffer, "%02X", (guint8) (i & 0xff));
          size = 0;
        }
      else
        {
          while (size > 0)
            {
              g_string_append_printf (buffer, "%02X", *ptr++);
              size--;
            }
        }

      g_string_append_c (buffer, '\n');

      if (write (self->emul_fd, buffer->str, buffer->len) != (gssize) buffer->len)
        fp_dbg ("emulation trace write failed");
      break;

    default:
      g_warn_if_reached ();
    }
}

/* Non-blocking single-shot read of the next fingerprint MKBP event.
 * Returns TRUE (with *got set to whether a relevant fingerprint event was
 * consumed), or FALSE on a hard error.
 */
static gboolean
crfpmoc_poll_event (FpDevice *device,
                    guint32  *fp_events,
                    gboolean *got,
                    GError  **error)
{
  int fd = fpi_device_get_udev_fd (device, FPI_DEVICE_UDEV_SUBTYPE_MISC);
  struct pollfd pfd = { .fd = fd, .events = POLLIN };
  struct crfpmoc_ec_response_get_next_event_v1 buffer = { 0 };
  ssize_t n;
  int r;

  *got = FALSE;

  if (fd < 0)
    {
      g_set_error_literal (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_NOT_OPEN,
                           "Device node is not open");
      return FALSE;
    }

  r = poll (&pfd, 1, 0);
  if (r < 0)
    {
      if (errno == EINTR)
        return TRUE;
      g_set_error (error, G_IO_ERROR, g_io_error_from_errno (errno),
                   "poll on FP device failed: %s", g_strerror (errno));
      return FALSE;
    }

  if (!(pfd.revents & POLLIN))
    return TRUE;

  n = read (fd, &buffer, sizeof (buffer));
  if (n < 0)
    {
      if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
        return TRUE;
      g_set_error (error, G_IO_ERROR, g_io_error_from_errno (errno),
                   "Failed to read FP event: %s", g_strerror (errno));
      return FALSE;
    }

  guint8 event_type = buffer.event_type & CRFPMOC_EC_MKBP_EVENT_TYPE_MASK;
  if (n < 1 || event_type != CRFPMOC_EC_MKBP_EVENT_FINGERPRINT)
    {
      if (n >= 1)
        fp_dbg ("crfpmoc_poll_event: non-fingerprint event %u (%s)",
                event_type, crfpmoc_mkbp_event_strresult (event_type));
      return TRUE;
    }

  if (n < 5)
    return TRUE;

  *fp_events = GUINT32_FROM_LE (buffer.data.fp_events);
  fp_dbg ("crfpmoc_poll_event: fingerprint event 0x%08x", *fp_events);
  *got = TRUE;
  return TRUE;
}

/* Enable device event reporting and queue a callback when there is
 * data available to read. The device will notify on mode changes
 * EC_FP_MODE_MATCH, EC_FP_MODE_ENROLL_*, EC_FP_MODE_CAPTURE,
 * EC_FP_MODE_FINGER_UP, EC_FP_MODE_FINGER_DOWN, maybe others ?
 */

static void
crfpmoc_finger_up_mode_cb (CrfpMocEcTransfer *transfer, GAsyncResult *res, gpointer user_data)
{
  g_autoptr(GError) error = NULL;
  FpiSsm *ssm = user_data;

  if (!crfpmoc_ec_transfer_submit_finish (res, &error))
    {
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  fpi_ssm_next_state (ssm);
}

/* Set the device to the specified mode, see above for list of modes.
 */
static void
crfpmoc_enroll_check_cb (CrfpMocEcTransfer *transfer, GAsyncResult *res, gpointer user_data)
{
  g_autoptr(GError) error = NULL;
  FpiSsm *ssm = user_data;
  FpDevice *device = fpi_ssm_get_device (ssm);
  SubSsmData *data = fpi_ssm_get_data (ssm);
  EnrollData *enroll_data = data->sub_data;
  guint32 mode;

  if (!crfpmoc_ec_transfer_submit_finish (res, &error))
    {
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  mode = GUINT32_FROM_LE (((struct crfpmoc_ec_response_fp_mode *) transfer->indata)->mode);

  if (mode & CRFPMOC_FP_MODE_ENROLL_SESSION)
    {
      if (mode & CRFPMOC_FP_MODE_ENROLL_IMAGE)
        {
          fpi_ssm_jump_to_state (ssm, ENROLL_WAIT_ENROLL_COMPLETE);
        }
      else
        {
          fpi_device_report_finger_status_changes (device,
                                                   FP_FINGER_STATUS_PRESENT,
                                                   FP_FINGER_STATUS_NONE);

          if (enroll_data->last_error_code == CRFPMOC_EC_MKBP_FP_ERR_ENROLL_OK)
            {
              enroll_data->stage++;
              fp_dbg ("Enroll stage %d completed successfully (%u%%)",
                      enroll_data->stage, enroll_data->last_progress_pct);
              fpi_device_enroll_progress (device, enroll_data->stage, NULL, NULL);
            }
          else if (enroll_data->last_error_code == CRFPMOC_EC_MKBP_FP_ERR_ENROLL_LOW_QUALITY)
            {
              fpi_device_enroll_progress (device, enroll_data->stage, NULL,
                                          fpi_device_retry_new (FP_DEVICE_RETRY_CENTER_FINGER));
            }
          else if (enroll_data->last_error_code == CRFPMOC_EC_MKBP_FP_ERR_ENROLL_IMMOBILE)
            {
              fpi_device_enroll_progress (device, enroll_data->stage, NULL,
                                          fpi_device_retry_new (FP_DEVICE_RETRY_REMOVE_FINGER));
            }
          else
            {
              fpi_device_enroll_progress (device, enroll_data->stage, NULL,
                                          fpi_device_retry_new (FP_DEVICE_RETRY_GENERAL));
            }

          if (enroll_data->last_progress_pct >= 100 || enroll_data->stage >= 5)
            fpi_ssm_jump_to_state (ssm, ENROLL_COMMIT);
          else
            fpi_ssm_jump_to_state (ssm, ENROLL_SENSOR_ENROLL_SUBMIT);
        }
    }
  else if (mode == 0)
    {
      fpi_device_report_finger_status_changes (device,
                                               FP_FINGER_STATUS_PRESENT,
                                               FP_FINGER_STATUS_NONE);
      fpi_ssm_next_state (ssm);
    }
  else
    {
      fpi_device_report_finger_status_changes (device,
                                               FP_FINGER_STATUS_PRESENT,
                                               FP_FINGER_STATUS_NONE);
      fpi_device_enroll_progress (device, enroll_data->stage, NULL,
                                  fpi_device_error_new_msg (FP_DEVICE_ERROR_PROTO,
                                                            "FP mode unexpected: (0x%x)", mode));
      fpi_ssm_jump_to_state (ssm, ENROLL_SENSOR_ENROLL_SUBMIT);
    }
}

static void
crfpmoc_wait_idle_cb (CrfpMocEcTransfer *transfer, GAsyncResult *res, gpointer user_data)
{
  g_autoptr(GError) error = NULL;
  FpiSsm *ssm = user_data;
  SubSsmData *data = fpi_ssm_get_data (ssm);
  guint32 mode;

  if (!crfpmoc_ec_transfer_submit_finish (res, &error))
    {
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  mode = GUINT32_FROM_LE (((struct crfpmoc_ec_response_fp_mode *) transfer->indata)->mode);

  if (mode == 0)
    {
      fpi_ssm_next_state (ssm);
    }
  else
    {
      if (data)
        {
          data->idle_attempts++;
          if (data->idle_attempts > 50)
            {
              fpi_ssm_mark_failed (ssm, fpi_device_error_new_msg (FP_DEVICE_ERROR_BUSY,
                                                                 "Timeout waiting for device idle (attempts: %d)",
                                                                 data->idle_attempts));
              return;
            }
        }
      fpi_ssm_jump_to_state_delayed (ssm, fpi_ssm_get_cur_state (ssm), 100);
    }
}

static void
crfpmoc_clear_storage_cb (CrfpMocEcTransfer *transfer, GAsyncResult *res, gpointer user_data)
{
  g_autoptr(GError) error = NULL;
  FpiSsm *ssm = user_data;
  SubSsmData *data = fpi_ssm_get_data (ssm);
  FpDevice *device = fpi_ssm_get_device (ssm);
  struct crfpmoc_ec_params_fp_mode p;

  if (!crfpmoc_ec_transfer_submit_finish (res, &error))
    {
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  if (data->clear_step == 0)
    {
      CrfpMocEcTransfer *new_transfer = NULL;

      data->clear_step = 1;
      p.mode = CRFPMOC_FP_MODE_RESET_SENSOR;
      new_transfer = crfpmoc_ec_transfer_new_cmd (device, CRFPMOC_EC_CMD_FP_MODE, 0,
                                                  &p, sizeof (p), sizeof (struct crfpmoc_ec_response_fp_mode));
      crfpmoc_ec_transfer_submit_cmd (new_transfer, fpi_device_get_cancellable (device),
                                      crfpmoc_clear_storage_cb, ssm);
    }
  else
    {
      fpi_ssm_next_state (ssm);
    }
}

static const struct crfpmoc_ec_response_fp_template_info *
crfpmoc_get_template_info (gconstpointer indata, gsize len, gint version)
{
  gsize offset;

  if (indata == NULL)
    return NULL;

  offset = crfpmoc_proto_template_info_offset (version);
  if (offset == 0 || len < offset + sizeof (struct crfpmoc_ec_response_fp_template_info))
    return NULL;

  return (const struct crfpmoc_ec_response_fp_template_info *) ((const guint8 *) indata + offset);
}

/* Parse the device info response, vendor, version, etc. Get the state
 * of the loaded templates and how many can be loaded as well as the
 * size of templates. All templates have the same size on a given device.
 */
static gboolean
crfpmoc_parse_fp_info (FpiDeviceCrfpMoc *self,
                       gconstpointer     indata,
                       gsize             len,
                       gint              version,
                       guint16          *max_templates,
                       guint16          *template_size,
                       GError          **error)
{
  CrfpMocFpInfoParsed parsed;
  gchar vendor[5];
  const gchar *model = NULL;

  if (!crfpmoc_proto_parse_fp_info (indata, len, version, &parsed, error))
    {
      if (error && !*error)
        g_set_error_literal (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_PROTO,
                             "Invalid FP_INFO response");
      return FALSE;
    }

  vendor[0] = parsed.vendor_id;
  vendor[1] = parsed.vendor_id >> 8;
  vendor[2] = parsed.vendor_id >> 16;
  vendor[3] = parsed.vendor_id >> 24;
  vendor[4] = '\0';

  if (strcmp (vendor, "FPC ") == 0)
    {
      switch ((parsed.model_id >> 4) & 0xfff)
        {
        case 0x021:
          model = "FPC1025";
          break;

        case 0x011:
          model = "FPC1035";
          break;

        case 0x140:
          model = "FPC1145";
          break;
        }
    }

  fp_dbg ("Fingerprint sensor: vendor %s product %x model %x (%s) version %x",
          vendor, parsed.product_id, parsed.model_id,
          model ? model : "", parsed.version);
  fp_dbg ("Image: size %dx%d %d bpp, format 0x%x, frame_size %u",
          parsed.width, parsed.height, parsed.bpp, parsed.pixel_format, parsed.frame_size);
  fp_dbg ("Templates: version %u size %u count %u/%u dirty bitmap 0x%x",
          parsed.template_version, parsed.template_size, parsed.template_valid,
          parsed.template_max, parsed.template_dirty);

  if (!parsed.has_template_info)
    {
      g_set_error_literal (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_PROTO,
                           "EC_CMD_FP_INFO response does not provide template info");
      return FALSE;
    }

  if (parsed.template_size == 0)
    {
      g_set_error_literal (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_PROTO,
                           "Template size is zero, device may not be initialized.");
      return FALSE;
    }

  if (max_templates)
    *max_templates = parsed.template_max;
  if (template_size)
    *template_size = parsed.template_size;

  if (self)
    self->fp_info_version = version;

  return TRUE;
}

static CrfpMocEcTransfer *
crfpmoc_fp_info_transfer_new (FpDevice *device, int version)
{
  FpiDeviceCrfpMoc *self = FPI_DEVICE_CRFPMOC (device);
  int ver = (version > 0) ? version : (self->fp_info_version > 0 ? self->fp_info_version : 3);

  return crfpmoc_ec_transfer_new_cmd (device, CRFPMOC_EC_CMD_FP_INFO, ver,
                                      NULL, 0, CRFPMOC_FP_INFO_BUFFER_SIZE);
}

/* Retry with next lower FP_INFO version if the firmware rejected with INVALID_VERSION.
 * Returns TRUE if a retry transfer was submitted and the callback will be
 * invoked again. */
static gboolean
crfpmoc_fp_info_maybe_retry (CrfpMocEcTransfer       *transfer,
                             FpiSsm                  *ssm,
                             CrfpMocEcTransferCallback cb)
{
  if (transfer->result == EC_RES_INVALID_VERSION)
    {
      CrfpMocEcTransfer *retry = NULL;
      FpDevice *device = fpi_ssm_get_device (ssm);

      if (transfer->version == 3)
        {
          fp_dbg ("FP_INFO v3 rejected with INVALID_VERSION, retrying with v2");
          retry = crfpmoc_fp_info_transfer_new (device, 2);
        }
      else if (transfer->version == 2)
        {
          fp_dbg ("FP_INFO v2 rejected with INVALID_VERSION, retrying with v1");
          retry = crfpmoc_fp_info_transfer_new (device, 1);
        }

      if (retry)
        {
          crfpmoc_ec_transfer_submit_cmd (retry, fpi_device_get_cancellable (device),
                                          cb, ssm);
          return TRUE;
        }
    }

  return FALSE;
}

/* Debug function to print the protocol infomation.
 */
static void
crfpmoc_show_proto_info (struct crfpmoc_ec_response_get_protocol_info *protocol_info)
{
  gsize len = 0;
  gsize buflen = 256;
  g_autofree gchar *buffer = g_malloc (buflen);

  for (int i = 0; i < 32; i++)
    if (protocol_info->protocol_versions & (1ULL << i))
      len += snprintf (&buffer[len], buflen - len, "%s%d", len == 0 ? "" : ",", i);

  buffer[buflen - 1] = '\0';
  fp_dbg ("crfpmoc_show_proto_info: vers %s, max_out %d, max_in %d, flags 0x%08x",
          buffer,
          protocol_info->max_request_packet_size,
          protocol_info->max_response_packet_size,
          protocol_info->flags);
}

/* Stolen BSD sum algorithm. Used for debug to allow matching the
 * templates uploaded using ectool with the sum shell command.
 */
static uint16_t
crfpmoc_sum (guint16 sum, guint8 * buffer, gsize len)
{
  int checksum = sum;             /* The checksum mod 2^16. */
  int i;

  for (i = 0; i < len; i++)
    {
      checksum = (checksum >> 1) + ((checksum & 1) << 15);
      checksum += buffer[i];
      checksum &= 0xffff;       /* Keep it within bounds. */
    }
  return (guint16) checksum;
}

/* Generic task completion callback to report any errors. Only to be
 * used for top level tasks since it assumes it is completing
 * self->task_ssm.
 */
static void
crfpmoc_task_ssm_done (FpiSsm *ssm, FpDevice *device, GError *error)
{
  FpiDeviceCrfpMoc *self = FPI_DEVICE_CRFPMOC (device);

  fp_dbg ("Task SSM done");
  g_assert (!self->task_ssm || self->task_ssm == ssm);
  self->task_ssm = NULL;

  if (error)
    fpi_device_action_error (device, error);
}

static void
crfpmoc_enroll_ssm_done (FpiSsm *ssm, FpDevice *device, GError *error)
{
  FpiDeviceCrfpMoc *self = FPI_DEVICE_CRFPMOC (device);
  FpPrint *print;

  fp_dbg ("Enroll SSM done");
  self->task_ssm = NULL;

  if (error)
    {
      fpi_device_action_error (device, error);
      return;
    }

  fpi_device_get_enroll_data (device, &print);
  fpi_device_enroll_complete (device, g_object_ref (print), NULL);
}

static void
crfpmoc_open_proto_info_cb (CrfpMocEcTransfer *transfer, GAsyncResult *res, gpointer user_data)
{
  g_autoptr(GError) error = NULL;
  FpiSsm *ssm = user_data;
  FpDevice *device = fpi_ssm_get_device (ssm);
  FpiDeviceCrfpMoc *self = FPI_DEVICE_CRFPMOC (device);
  struct crfpmoc_ec_response_get_protocol_info *protocol_info;

  if (!crfpmoc_ec_transfer_submit_finish (res, &error))
    {
      g_prefix_error_literal (&error, "Failed to get max insize/outsize: ");
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  protocol_info = (struct crfpmoc_ec_response_get_protocol_info *) transfer->indata;

  crfpmoc_show_proto_info (protocol_info);

  if (!crfpmoc_proto_parse_max_size (protocol_info, &self->max_insize,
                                     &self->max_outsize, &error))
    {
      g_prefix_error_literal (&error, "Failed to get max insize/outsize: ");
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  fpi_ssm_next_state (ssm);
}

static void
crfpmoc_open_fp_info_cb (CrfpMocEcTransfer *transfer, GAsyncResult *res, gpointer user_data)
{
  g_autoptr(GError) error = NULL;
  FpiSsm *ssm = user_data;
  FpDevice *device = fpi_ssm_get_device (ssm);
  FpiDeviceCrfpMoc *self = FPI_DEVICE_CRFPMOC (device);

  if (!crfpmoc_ec_transfer_submit_finish (res, &error))
    {
      if (crfpmoc_fp_info_maybe_retry (transfer, ssm, crfpmoc_open_fp_info_cb))
        return;
      g_prefix_error_literal (&error, "Failed to get max templates and templates size: ");
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  if (!crfpmoc_parse_fp_info (self, transfer->indata, transfer->insize, transfer->version,
                              &self->max_templates, &self->template_size, &error))
    {
      g_prefix_error_literal (&error, "Failed to get max templates and templates size: ");
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  fpi_ssm_next_state (ssm);
}

static void
crfpmoc_open_run_state (FpiSsm *ssm, FpDevice *device)
{
  CrfpMocEcTransfer *transfer;

  switch (fpi_ssm_get_cur_state (ssm))
    {
    case OPEN_GET_PROTO_INFO:
      transfer = crfpmoc_ec_transfer_new_cmd (device, CRFPMOC_EC_CMD_GET_PROTOCOL_INFO, 0,
                                              NULL, 0, sizeof (struct crfpmoc_ec_response_get_protocol_info));
      crfpmoc_ec_transfer_submit_cmd (transfer, fpi_device_get_cancellable (device),
                                      crfpmoc_open_proto_info_cb, ssm);
      break;

    case OPEN_GET_FP_INFO:
      transfer = crfpmoc_fp_info_transfer_new (device, 3);
      crfpmoc_ec_transfer_submit_cmd (transfer, fpi_device_get_cancellable (device),
                                      crfpmoc_open_fp_info_cb, ssm);
      break;

    default:
      g_assert_not_reached ();
    }
}

static void crfpmoc_open_ssm_done (FpiSsm *ssm, FpDevice *device, GError *error);

static gboolean
crfpmoc_open_retry_cb (gpointer user_data)
{
  FpDevice *device = user_data;
  FpiDeviceCrfpMoc *self = FPI_DEVICE_CRFPMOC (device);
  g_autoptr(GError) error = NULL;

  /* The claim may have been cancelled (or the device closed) while the
   * retry was pending — in that case abandon the retry and complete the
   * open with a cancelled error so the caller can unwind cleanly. */
  if (fpi_device_get_current_action (device) != FPI_DEVICE_ACTION_OPEN ||
      g_cancellable_is_cancelled (fpi_device_get_cancellable (device)))
    {
      g_set_error_literal (&error, G_IO_ERROR, G_IO_ERROR_CANCELLED,
                           "Open retry aborted: device closed or claim cancelled");
      self->open_retries = 0;
      fpi_device_open_complete (device, g_steal_pointer (&error));
      return G_SOURCE_REMOVE;
    }

  g_assert (self->task_ssm == NULL);
  self->task_ssm = fpi_ssm_new (device, crfpmoc_open_run_state, OPEN_STATES);
  crfpmoc_ssm_start (self, self->task_ssm, crfpmoc_open_ssm_done);

  return G_SOURCE_REMOVE;
}

static void
crfpmoc_open_ssm_done (FpiSsm *ssm, FpDevice *device, GError *error)
{
  FpiDeviceCrfpMoc *self = FPI_DEVICE_CRFPMOC (device);
  int fd;

  self->task_ssm = NULL;

  /* The EC/FPMCU channel is briefly unusable right after S3 resume, so
   * open attempts can fail with an I/O error or an EC error for a couple
   * of seconds. Retry with a bounded budget instead of failing the claim:
   * the lock screen would otherwise never offer fingerprint on the first
   * unlock after resume. */
  if (error &&
      g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED) == FALSE &&
      !g_cancellable_is_cancelled (fpi_device_get_cancellable (device)) &&
      (error->domain == G_IO_ERROR || error->domain == FP_DEVICE_ERROR) &&
      self->open_retries < CRFPMOC_OPEN_MAX_RETRIES)
    {
      self->open_retries++;
      fp_dbg ("crfpmoc_open_ssm_done: open attempt failed (%s); retrying in %u ms (%u/%u)",
              error->message, CRFPMOC_OPEN_RETRY_DELAY_MS,
              self->open_retries, CRFPMOC_OPEN_MAX_RETRIES);
      g_timeout_add_full (G_PRIORITY_DEFAULT, CRFPMOC_OPEN_RETRY_DELAY_MS,
                          crfpmoc_open_retry_cb, g_object_ref (device),
                          g_object_unref);
      return;
    }

  if (error)
    fp_dbg ("crfpmoc_open_ssm_done: open failed after %u retries: %s",
            self->open_retries, error->message);

  self->open_retries = 0;

  if (!error)
    {
      fd = fpi_device_get_udev_fd (device, FPI_DEVICE_UDEV_SUBTYPE_MISC);
      if (fd >= 0)
        {
          if (ioctl (fd, CRFPMOC_CROS_EC_DEV_IOCEVENTMASK_V2, 1 << CRFPMOC_EC_MKBP_EVENT_FINGERPRINT) < 0)
            fp_dbg ("crfpmoc_open_ssm_done: ioctl eventmask failed: %s", g_strerror (errno));
        }
    }

  fp_dbg ("crfpmoc_open: open_complete");
  fpi_device_open_complete (device, error);
}

/* Fill a buffer from kernel entropy (getrandom first, /dev/urandom as
 * fallback). Returns FALSE if no kernel entropy source is available.
 * The caller treats failure as fatal: a seed that is not
 * cryptographically random would make enrolled templates decryptable by
 * anyone who knows the fallback value.
 */
static gboolean
crfpmoc_generate_random_seed (guint8 *seed, gsize len)
{
  g_return_val_if_fail (seed != NULL, FALSE);
  g_return_val_if_fail (len > 0, FALSE);

#if defined(__linux__)
  ssize_t ret = getrandom (seed, len, 0);
  if (ret == (ssize_t) len)
    return TRUE;
#endif

  int fd = open ("/dev/urandom", O_RDONLY | O_CLOEXEC);
  if (fd >= 0)
    {
      ssize_t total = 0;
      while (total < (ssize_t) len)
        {
          ssize_t n = read (fd, seed + total, len - total);
          if (n <= 0)
            break;
          total += n;
        }
      close (fd);
      if (total == (ssize_t) len)
        return TRUE;
    }

  return FALSE;
}

/* Initialise the encryption seed and user context.
 * In emulation mode fixed test values are used so the recorded ioctl replay stays
 * deterministic. On real hardware, a secure random 32-byte seed is read from or
 * persisted to /var/lib/fprint/crfpmoc.key (mode 0600) so enrolled templates
 * remain decryptable across reboots. If no valid persistent key exists and a
 * new random seed cannot be generated and persisted, open fails closed so
 * templates are never encrypted with a predictable fallback seed.
 */
static gboolean
crfpmoc_init_keys (FpiDeviceCrfpMoc *self, GError **error)
{
  G_STATIC_ASSERT (sizeof (self->seed) == CRFPMOC_FP_CONTEXT_TPM_BYTES);
  G_STATIC_ASSERT (sizeof (self->context) == CRFPMOC_FP_CONTEXT_USERID_BYTES);
  G_STATIC_ASSERT (sizeof (CRFPMOC_DEFAULT_SEED) - 1 == CRFPMOC_FP_CONTEXT_TPM_BYTES);
  G_STATIC_ASSERT (sizeof (CRFPMOC_DEFAULT_CONTEXT) - 1 == CRFPMOC_FP_CONTEXT_USERID_BYTES);

  /* User context remains persistent machine salt */
  memcpy (self->context, CRFPMOC_DEFAULT_CONTEXT, sizeof (self->context));

  if (fpi_device_emulation_mode_enabled (FP_DEVICE (self)))
    {
      fp_dbg ("Emulation mode active: using deterministic default seed");
      memcpy (self->seed, CRFPMOC_DEFAULT_SEED, sizeof (self->seed));
      return TRUE;
    }

  g_autofree gchar *contents = NULL;
  gsize length = 0;
  g_autoptr(GError) read_error = NULL;

  if (g_file_get_contents (CRFPMOC_KEY_FILE_PATH, &contents, &length, &read_error))
    {
      if (length == CRFPMOC_FP_CONTEXT_TPM_BYTES)
        {
          fp_dbg ("Loaded persistent key from %s", CRFPMOC_KEY_FILE_PATH);
          memcpy (self->seed, contents, sizeof (self->seed));
          return TRUE;
        }
      else
        {
          fp_warn ("Persistent key file %s has invalid size (%zu bytes, expected %d); regenerating",
                   CRFPMOC_KEY_FILE_PATH, length, CRFPMOC_FP_CONTEXT_TPM_BYTES);
        }
    }
  else
    {
      fp_dbg ("Could not read key file %s: %s", CRFPMOC_KEY_FILE_PATH, read_error->message);
    }

  guint8 new_seed[CRFPMOC_FP_CONTEXT_TPM_BYTES];
  if (!crfpmoc_generate_random_seed (new_seed, sizeof (new_seed)))
    {
      g_set_error (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_PROTO,
                   "No kernel entropy available to generate the fingerprint encryption key");
      return FALSE;
    }

  g_autofree gchar *dirname = g_path_get_dirname (CRFPMOC_KEY_FILE_PATH);
  if (g_mkdir_with_parents (dirname, 0700) != 0 && errno != EEXIST)
    {
      g_set_error (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_PROTO,
                   "Failed to create key directory %s: %s",
                   dirname, g_strerror (errno));
      return FALSE;
    }

  mode_t old_umask = umask (0077);
  g_autoptr(GError) write_error = NULL;
  gboolean write_ok = g_file_set_contents (CRFPMOC_KEY_FILE_PATH,
                                           (const gchar *) new_seed,
                                           sizeof (new_seed),
                                           &write_error);
  umask (old_umask);

  if (write_ok)
    {
      if (chmod (CRFPMOC_KEY_FILE_PATH, S_IRUSR | S_IWUSR) != 0)
        fp_warn ("Could not enforce 0600 permissions on %s: %s",
                 CRFPMOC_KEY_FILE_PATH, g_strerror (errno));

      fp_dbg ("Generated and stored persistent seed at %s", CRFPMOC_KEY_FILE_PATH);
      memcpy (self->seed, new_seed, sizeof (self->seed));
      return TRUE;
    }
  else
    {
      g_set_error (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_PROTO,
                   "Failed to persist fingerprint encryption key to %s: %s",
                   CRFPMOC_KEY_FILE_PATH, write_error->message);
      return FALSE;
    }
}

static void
crfpmoc_open (FpDevice *device)
{
  g_autoptr(GError) error = NULL;
  FpiDeviceCrfpMoc *self = FPI_DEVICE_CRFPMOC (device);
  const char *device_path;

  self->open_retries = 0;

  device_path = fpi_device_get_udev_data (device, FPI_DEVICE_UDEV_SUBTYPE_MISC);
  fp_dbg ("Opening device %s", device_path);

  /* For testing we need to create the umockdev trace file ourselves
   * since there is no record support, while there is playback support.
   */
  if (fpi_device_emulation_mode_enabled (device) &&
      g_getenv ("FPI_CRFPMOC_IOCTL_RECORD"))
    {
      g_autofree char *ioctl_file = NULL;

      self->emul_fd = g_file_open_tmp ("crfpmoc-XXXXXX.ioctl", &ioctl_file, &error);
      if (self->emul_fd < 0)
        {
          fpi_device_open_complete (device, g_steal_pointer (&error));
          return;
        }

      fp_dbg ("Created temporary ioctl file for recording: %s", ioctl_file);
    }

  if (!crfpmoc_init_keys (self, &error))
    {
      fp_warn ("crfpmoc_open: failed to initialise encryption keys: %s", error->message);
      g_clear_fd (&self->emul_fd, NULL);
      fpi_device_open_complete (device, g_steal_pointer (&error));
      return;
    }

  g_assert (self->task_ssm == NULL);
  self->task_ssm = fpi_ssm_new (device, crfpmoc_open_run_state, OPEN_STATES);
  crfpmoc_ssm_start (self, self->task_ssm, crfpmoc_open_ssm_done);
}

/* Synchronously issue a sensor reset (mode 0). Used to abort ongoing
 * work on cancel/suspend/close. These teardown paths must not depend on
 * the main loop running (the current cancellable is already cancelled on
 * cancel, and close/suspend are expected to settle promptly), so a
 * blocking transfer with a bounded timeout is used instead of the async
 * SSM machinery. crfpmoc_ec_transfer_submit_sync_timeout takes
 * ownership of the transfer (freed on success, kept by the worker on
 * timeout), so no autoptr is used here.
 */
#define CRFPMOC_RESET_SYNC_TIMEOUT_MS 2000

static void
crfpmoc_reset_sync (FpDevice *device)
{
  g_autoptr(GError) error = NULL;
  CrfpMocEcTransfer *transfer;

  transfer = crfpmoc_ec_transfer_new_cmd (device, CRFPMOC_EC_CMD_FP_MODE, 0,
                                          &(struct crfpmoc_ec_params_fp_mode){ .mode = 0 },
                                          sizeof (struct crfpmoc_ec_params_fp_mode),
                                          sizeof (struct crfpmoc_ec_response_fp_mode));

  if (!crfpmoc_ec_transfer_submit_sync_timeout (transfer, CRFPMOC_RESET_SYNC_TIMEOUT_MS, &error))
    fp_warn ("crfpmoc_reset_sync: reset failed: %s", error->message);
}

static void
crfpmoc_cancel (FpDevice *device)
{
  fp_dbg ("Cancel");

  /* Issue reset */
  crfpmoc_reset_sync (device);
}

static void
crfpmoc_suspend (FpDevice *device)
{
  fp_dbg ("Suspend");

  crfpmoc_reset_sync (device);

  fp_dbg ("crfpmoc_suspend: suspend_complete");
  fpi_device_suspend_complete (device, NULL);
}

static void
crfpmoc_close (FpDevice *device)
{
  g_autoptr(GError) error = NULL;
  FpiDeviceCrfpMoc *self = FPI_DEVICE_CRFPMOC (device);

  fp_dbg ("Closing device");

  /* Clear the emulation trace fd before issuing the reset: the reset may
   * run in a worker thread after a timeout, and recording must not write
   * to a closed fd. */
  g_clear_fd (&self->emul_fd, &error);

  crfpmoc_reset_sync (device);

  fpi_device_close_complete (device, g_steal_pointer (&error));
}

static void
download_data_free (gpointer data)
{
  DownloadData *ddata = data;

  g_clear_pointer (&ddata->buffer, g_free);
  g_free (data);
}

static void
crfpmoc_commit_fp_info_cb (CrfpMocEcTransfer *transfer, GAsyncResult *res, gpointer user_data)
{
  g_autoptr(GError) error = NULL;
  FpiSsm *ssm = user_data;
  FpDevice *device = fpi_ssm_get_device (ssm);
  FpiDeviceCrfpMoc *self = FPI_DEVICE_CRFPMOC (device);
  DownloadData *ddata;
  FpiSsm *sub;
  guint16 enrolled_templates;
  const struct crfpmoc_ec_response_fp_template_info *tinfo;

  if (!crfpmoc_ec_transfer_submit_finish (res, &error))
    {
      if (crfpmoc_fp_info_maybe_retry (transfer, ssm, crfpmoc_commit_fp_info_cb))
        return;
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  tinfo = crfpmoc_get_template_info (transfer->indata, transfer->insize, transfer->version);
  if (!tinfo)
    {
      fpi_ssm_mark_failed (ssm, fpi_device_error_new_msg (FP_DEVICE_ERROR_PROTO, "Missing template info in FP_INFO"));
      return;
    }

  enrolled_templates = GUINT16_FROM_LE (tinfo->template_valid);
  fp_dbg ("Number of enrolled templates is: %d", enrolled_templates);

  if (enrolled_templates == 0)
    {
      fpi_ssm_mark_failed (ssm,
                           fpi_device_error_new_msg (FP_DEVICE_ERROR_PROTO,
                                                     "Device reported no enrolled "
                                                     "templates after enrollment"));
      return;
    }

  sub = fpi_ssm_new (device, crfpmoc_download_run_state, DOWNLOAD_STATES);

  ddata = g_new0 (DownloadData, 1);
  ddata->template_index = enrolled_templates - 1;
  ddata->offset = (ddata->template_index + CRFPMOC_FP_FRAME_INDEX_TEMPLATE) << CRFPMOC_FP_FRAME_INDEX_SHIFT;
  ddata->buf_offset = 0;
  ddata->remaining = self->template_size;
  ddata->buffer = g_malloc0 (self->template_size);

  crfpmoc_ssm_start_subsm_full (self, sub, ddata, download_data_free);
}

static void
crfpmoc_verify_fp_info_cb (CrfpMocEcTransfer *transfer, GAsyncResult *res, gpointer user_data)
{
  g_autoptr(GError) error = NULL;
  CrfpMocEcTransfer *stats_transfer;
  FpiSsm *ssm = user_data;
  FpDevice *device = fpi_ssm_get_device (ssm);
  const struct crfpmoc_ec_response_fp_template_info *tinfo;
  guint16 enrolled_templates;

  if (!crfpmoc_ec_transfer_submit_finish (res, &error))
    {
      if (crfpmoc_fp_info_maybe_retry (transfer, ssm, crfpmoc_verify_fp_info_cb))
        return;
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  tinfo = crfpmoc_get_template_info (transfer->indata, transfer->insize, transfer->version);
  if (!tinfo)
    {
      fpi_ssm_mark_failed (ssm, fpi_device_error_new_msg (FP_DEVICE_ERROR_PROTO, "Missing template info in FP_INFO"));
      return;
    }

  enrolled_templates = GUINT16_FROM_LE (tinfo->template_valid);

  fp_dbg ("handle_verify_check: enrolled templates: %d", enrolled_templates);

  if (!enrolled_templates)
    {
      fp_info ("No enrolled templates on device");
      complete_verification (ssm, NULL, NULL);
      return;
    }

  stats_transfer = crfpmoc_ec_transfer_new_cmd (device, CRFPMOC_EC_CMD_FP_STATS, 0,
                                                NULL, 0, sizeof (struct crfpmoc_ec_response_fp_stats));
  crfpmoc_ec_transfer_submit_cmd (stats_transfer, fpi_device_get_cancellable (device),
                                  crfpmoc_verify_fp_stats_cb, ssm);
}

static void
crfpmoc_verify_fp_stats_cb (CrfpMocEcTransfer *transfer, GAsyncResult *res, gpointer user_data)
{
  g_autoptr(GError) error = NULL;
  g_autoptr(GPtrArray) prints = NULL;
  FpiSsm *ssm = user_data;
  FpDevice *device = fpi_ssm_get_device (ssm);
  FpPrint *matched_print;
  g_autofree guint8 *matched_template = NULL;
  size_t matched_template_size = 0;
  struct crfpmoc_ec_response_fp_stats *stats;
  gint8 template_idx;

  if (!crfpmoc_ec_transfer_submit_finish (res, &error))
    {
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  stats = (struct crfpmoc_ec_response_fp_stats *) transfer->indata;

  if (stats->timestamps_invalid & CRFPMOC_FPSTATS_MATCHING_INV)
    template_idx = -1;
  else
    template_idx = stats->template_matched;

  if (template_idx < 0)
    {
      fp_info ("Print was not identified by the device");
      complete_verification (ssm, NULL, NULL);
      return;
    }

  if (fpi_device_get_current_action (device) == FPI_DEVICE_ACTION_IDENTIFY)
    {
      GPtrArray *gallery = NULL;
      fpi_device_get_identify_data (device, &gallery);
      prints = g_ptr_array_ref (gallery);
    }
  else
    {
      FpPrint *verify_print = NULL;
      fpi_device_get_verify_data (device, &verify_print);
      prints = g_ptr_array_new_with_free_func (g_object_unref);
      g_ptr_array_add (prints, g_object_ref (verify_print));
    }

  if (!prints || prints->len == 0)
    {
      fp_info ("No prints available for verification");
      complete_verification (ssm, NULL, NULL);
      return;
    }

  if (template_idx >= prints->len)
    {
      fp_info ("Matched template not in index %d, gallery size %d",
               template_idx, prints->len);
      complete_verification (ssm, NULL, NULL);
      return;
    }

  fp_info ("Identify successful for template %d", template_idx);

  matched_print = g_ptr_array_index (prints, template_idx);

  if (!crfpmoc_get_print_data (matched_print,
                               &matched_template, &matched_template_size,
                               &error))
    {
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  g_autoptr(FpPrint) scanned_print = fp_print_new (device);
  fpi_print_set_type (scanned_print, FPI_PRINT_RAW);
  crfpmoc_set_print_data (scanned_print, matched_template, matched_template_size);
  complete_verification (ssm, matched_print, g_steal_pointer (&scanned_print));
}

static void
handle_enroll_sensor_enroll_submit (FpiSsm *ssm)
{
  FpDevice *device = fpi_ssm_get_device (ssm);
  struct crfpmoc_ec_params_fp_mode p = {
    .mode = CRFPMOC_FP_MODE_ENROLL_IMAGE | CRFPMOC_FP_MODE_ENROLL_SESSION
  };
  CrfpMocEcTransfer *transfer;

  transfer = crfpmoc_ec_transfer_new_cmd (device, CRFPMOC_EC_CMD_FP_MODE, 0,
                                          &p, sizeof (p), sizeof (struct crfpmoc_ec_response_fp_mode));
  crfpmoc_ec_transfer_submit_cmd (transfer, fpi_device_get_cancellable (device),
                                  crfpmoc_ssm_ec_transfer_cb, ssm);
}

static void
handle_enroll_sensor_enroll_done (FpiSsm *ssm)
{
  fpi_ssm_next_state (ssm);
}

static void
handle_enroll_reset (FpiSsm *ssm)
{
  FpDevice *device = fpi_ssm_get_device (ssm);
  struct crfpmoc_ec_params_fp_mode p = { .mode = 0 };
  CrfpMocEcTransfer *transfer;

  transfer = crfpmoc_ec_transfer_new_cmd (device, CRFPMOC_EC_CMD_FP_MODE, 0,
                                          &p, sizeof (p), sizeof (struct crfpmoc_ec_response_fp_mode));
  crfpmoc_ec_transfer_submit_cmd (transfer, NULL, crfpmoc_ssm_ec_transfer_cb, ssm);
}

static void
handle_enroll_wait_enroll_complete (FpiSsm *ssm)
{
  FpDevice *device = fpi_ssm_get_device (ssm);
  SubSsmData *data = fpi_ssm_get_data (ssm);
  EnrollData *enroll_data = data ? data->sub_data : NULL;
  GCancellable *cancellable = fpi_device_get_cancellable (device);
  g_autoptr(GError) error = NULL;
  guint32 fp_events = 0;
  gboolean got = FALSE;

  if (g_cancellable_set_error_if_cancelled (cancellable, &error))
    {
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  if (!crfpmoc_poll_event (device, &fp_events, &got, &error))
    {
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  if (got && (fp_events & CRFPMOC_EC_MKBP_FP_ENROLL))
    {
      guint error_code = CRFPMOC_EC_MKBP_FP_ERRCODE (fp_events);
      guint progress = CRFPMOC_EC_MKBP_FP_ENROLL_PROGRESS (fp_events);

      if (enroll_data)
        {
          enroll_data->last_fp_events = fp_events;
          enroll_data->last_progress_pct = progress;
          enroll_data->last_error_code = error_code;
        }

      fp_dbg ("handle_enroll_wait_enroll_complete: enroll MKBP event received: progress %u%%, error_code %u",
              progress, error_code);
      fpi_ssm_next_state (ssm);
      return;
    }

  fpi_ssm_jump_to_state_delayed (ssm, ENROLL_WAIT_ENROLL_COMPLETE, 50);
}

static void
crfpmoc_ssm_timeout (FpDevice *device, gpointer user_data)
{
  SubSsmData *data = user_data;

  fp_dbg ("crfpmoc_ssm_timeout: move to state %d",
          data->timeout_state);

  /* Timeout should be cancelled, make sure cleanup does not see it */
  data->timeout = NULL;

  /* If there is an active poller on this state machine remove it */
  fp_dbg ("crfpmoc_ssm_timeout: remove poll source %d", data->poll_source);
  g_clear_handle_id (&data->poll_source, g_source_remove);
  g_clear_object (&data->poll_input_stream);

  /* Is it ok to call the state machine from here ? If not make sure we exit first */
  fpi_ssm_jump_to_state_delayed (data->parent_ssm, data->timeout_state, 1);
}

static void
handle_wait_finger_up (FpiSsm *ssm,
                       int     state,
                       int     timeout)
{
  FpDevice *device = fpi_ssm_get_device (ssm);
  SubSsmData *data = fpi_ssm_get_data (ssm);
  struct crfpmoc_ec_params_fp_mode p = { .mode = CRFPMOC_FP_MODE_FINGER_UP };
  CrfpMocEcTransfer *transfer;

  data->timeout_state = state;
  data->timeout = fpi_device_add_timeout (device, timeout,
                                          crfpmoc_ssm_timeout, data, NULL);

  fpi_device_report_finger_status_changes (device,
                                           FP_FINGER_STATUS_NONE,
                                           FP_FINGER_STATUS_NEEDED);

  transfer = crfpmoc_ec_transfer_new_cmd (device, CRFPMOC_EC_CMD_FP_MODE, 0,
                                          &p, sizeof (p), sizeof (struct crfpmoc_ec_response_fp_mode));
  crfpmoc_ec_transfer_submit_cmd (transfer, fpi_device_get_cancellable (device),
                                  crfpmoc_finger_up_mode_cb, ssm);
}

/* Enroll state machine */
static void
handle_enroll_sensor_check (FpiSsm *ssm)
{
  FpDevice *device = fpi_ssm_get_device (ssm);
  struct crfpmoc_ec_params_fp_mode p = { .mode = CRFPMOC_FP_MODE_DONT_CHANGE };
  CrfpMocEcTransfer *transfer;

  transfer = crfpmoc_ec_transfer_new_cmd (device, CRFPMOC_EC_CMD_FP_MODE, 0,
                                          &p, sizeof (p), sizeof (struct crfpmoc_ec_response_fp_mode));
  crfpmoc_ec_transfer_submit_cmd (transfer, fpi_device_get_cancellable (device),
                                  crfpmoc_enroll_check_cb, ssm);
}

static void
handle_enroll_commit (FpiSsm *ssm)
{
  FpDevice *device = fpi_ssm_get_device (ssm);
  CrfpMocEcTransfer *transfer;

  transfer = crfpmoc_fp_info_transfer_new (device, 3);
  crfpmoc_ec_transfer_submit_cmd (transfer, fpi_device_get_cancellable (device),
                                  crfpmoc_commit_fp_info_cb, ssm);
}

static void
crfpmoc_enroll_capacity_cb (CrfpMocEcTransfer *transfer, GAsyncResult *res, gpointer user_data)
{
  g_autoptr(GError) error = NULL;
  FpiSsm *ssm = user_data;
  const struct crfpmoc_ec_response_fp_template_info *tinfo;
  guint16 t_valid, t_max;

  if (!crfpmoc_ec_transfer_submit_finish (res, &error))
    {
      if (crfpmoc_fp_info_maybe_retry (transfer, ssm, crfpmoc_enroll_capacity_cb))
        return;
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  tinfo = crfpmoc_get_template_info (transfer->indata, transfer->insize, transfer->version);
  if (!tinfo)
    {
      fpi_ssm_mark_failed (ssm, fpi_device_error_new_msg (FP_DEVICE_ERROR_PROTO, "Missing template info in FP_INFO"));
      return;
    }

  t_valid = GUINT16_FROM_LE (tinfo->template_valid);
  t_max = GUINT16_FROM_LE (tinfo->template_max);

  fp_dbg ("handle_enroll_check_capacity: enrolled %d of %d templates", t_valid, t_max);

  if (t_max != 0 && t_valid >= t_max)
    {
      fpi_ssm_mark_failed (ssm,
                           fpi_device_error_new_msg (FP_DEVICE_ERROR_DATA_FULL,
                                                     "On-device storage is full "
                                                     "(%d of %d templates enrolled)",
                                                     t_valid, t_max));
      return;
    }

  fpi_ssm_next_state (ssm);
}

static void
handle_enroll_check_capacity (FpiSsm *ssm)
{
  FpDevice *device = fpi_ssm_get_device (ssm);
  CrfpMocEcTransfer *transfer;

  transfer = crfpmoc_fp_info_transfer_new (device, 3);
  crfpmoc_ec_transfer_submit_cmd (transfer, fpi_device_get_cancellable (device),
                                  crfpmoc_enroll_capacity_cb, ssm);
}

static void
handle_ensure_keys (FpiSsm *ssm)
{
  FpDevice *device = fpi_ssm_get_device (ssm);
  FpiDeviceCrfpMoc *self = FPI_DEVICE_CRFPMOC (device);
  FpiSsm *sub;

  sub = fpi_ssm_new (device, crfpmoc_keys_run_state, KEYS_STATES);
  crfpmoc_ssm_start_subsm_full (self, sub, g_new0 (KeysData, 1), g_free);
}

static void
crfpmoc_enroll_run_state (FpiSsm *ssm, FpDevice *device)
{
  switch (fpi_ssm_get_cur_state (ssm))
    {
    case ENROLL_ENSURE_KEYS:
      handle_ensure_keys (ssm);
      break;

    case ENROLL_CHECK_CAPACITY:
      handle_enroll_check_capacity (ssm);
      break;

    case ENROLL_SENSOR_ENROLL_SUBMIT:
      handle_enroll_sensor_enroll_submit (ssm);
      break;

    case ENROLL_SENSOR_ENROLL_DONE:
      handle_enroll_sensor_enroll_done (ssm);
      break;

    case ENROLL_WAIT_ENROLL_COMPLETE:
      handle_enroll_wait_enroll_complete (ssm);
      break;

#ifdef WAIT_ON_ENROLL
    case ENROLL_WAIT_FINGER_UP:
      handle_wait_finger_up (ssm, FINGER_UP_TIMEOUT, 5000);
      break;
#endif

    case ENROLL_SENSOR_CHECK:
      handle_enroll_sensor_check (ssm);
      break;

    case ENROLL_COMMIT:
      handle_enroll_commit (ssm);
      break;

    case ENROLL_RESET:
      handle_enroll_reset (ssm);
      break;

    default:
      g_assert_not_reached ();
    }
}

/* Handle device enroll request */
static void
crfpmoc_enroll (FpDevice *device)
{
  g_autoptr(GError) error = NULL;
  FpiDeviceCrfpMoc *self = FPI_DEVICE_CRFPMOC (device);
  EnrollData *enroll_data = NULL;

  fp_dbg ("Enroll");

  if (self->template_size == 0)
    {
      fpi_device_enroll_complete (device, NULL,
                                  fpi_device_error_new_msg (FP_DEVICE_ERROR_NOT_SUPPORTED,
                                                            "Device template size is zero or uninitialized"));
      return;
    }

  enroll_data = g_new0 (EnrollData, 1);
  enroll_data->stage = 0;

  g_assert (self->task_ssm == NULL);
  self->task_ssm = fpi_ssm_new_full (device, crfpmoc_enroll_run_state, ENROLL_STATES,
                                     ENROLL_RESET, "crfpmoc_enroll");
  self->active_ssm_guard = self->task_ssm;

  SubSsmData *data = g_new0 (SubSsmData, 1);
  data->self = self;
  data->parent_ssm = self->task_ssm;
  data->sub_data = enroll_data;
  data->sub_data_destroy = g_free;
  fpi_ssm_set_data (self->task_ssm, data, subssm_data_free);
  fpi_ssm_start (self->task_ssm, crfpmoc_enroll_ssm_done);
}

/* Verify/Identify state machine */

static void
handle_verify_upload_template (FpiSsm *ssm)
{
  FpDevice *device = fpi_ssm_get_device (ssm);
  FpiDeviceCrfpMoc *self = FPI_DEVICE_CRFPMOC (device);
  UploadData *udata;
  FpiSsm *sub;

  sub = fpi_ssm_new (device, crfpmoc_upload_run_state, UPLOAD_STATES);

  udata = g_new0 (UploadData, 1);

  if (fpi_device_get_current_action (device) == FPI_DEVICE_ACTION_IDENTIFY)
    {
      GPtrArray *prints = NULL;
      fpi_device_get_identify_data (device, &prints);
      udata->prints = g_ptr_array_ref (prints);
    }
  else
    {
      FpPrint *print = NULL;
      fpi_device_get_verify_data (device, &print);
      udata->prints = g_ptr_array_new_with_free_func (g_object_unref);
      g_ptr_array_add (udata->prints, g_object_ref (print));
    }

  crfpmoc_ssm_start_subsm_full (self, sub, udata, upload_data_free);
}

static void
handle_verify_sensor_match_submit (FpiSsm *ssm)
{
  FpDevice *device = fpi_ssm_get_device (ssm);
  struct crfpmoc_ec_params_fp_mode p = { .mode = CRFPMOC_FP_MODE_MATCH };
  CrfpMocEcTransfer *transfer;

  transfer = crfpmoc_ec_transfer_new_cmd (device, CRFPMOC_EC_CMD_FP_MODE, 0,
                                          &p, sizeof (p), sizeof (struct crfpmoc_ec_response_fp_mode));
  crfpmoc_ec_transfer_submit_cmd (transfer, fpi_device_get_cancellable (device),
                                  crfpmoc_ssm_ec_transfer_cb, ssm);
}

static void
handle_verify_sensor_match_done (FpiSsm *ssm)
{
  fpi_ssm_next_state (ssm);
}

static void
handle_verify_reset (FpiSsm *ssm)
{
  FpDevice *device = fpi_ssm_get_device (ssm);
  struct crfpmoc_ec_params_fp_mode p = { .mode = 0 };
  CrfpMocEcTransfer *transfer;

  transfer = crfpmoc_ec_transfer_new_cmd (device, CRFPMOC_EC_CMD_FP_MODE, 0,
                                          &p, sizeof (p), sizeof (struct crfpmoc_ec_response_fp_mode));
  crfpmoc_ec_transfer_submit_cmd (transfer, NULL, crfpmoc_ssm_ec_transfer_cb, ssm);
}

static void
handle_verify_wait_match_complete (FpiSsm *ssm)
{
  FpDevice *device = fpi_ssm_get_device (ssm);
  GCancellable *cancellable = fpi_device_get_cancellable (device);
  g_autoptr(GError) error = NULL;
  guint32 fp_events = 0;
  gboolean got = FALSE;

  if (g_cancellable_set_error_if_cancelled (cancellable, &error))
    {
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  if (!crfpmoc_poll_event (device, &fp_events, &got, &error))
    {
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  if (got && (fp_events & CRFPMOC_EC_MKBP_FP_MATCH))
    {
      fp_dbg ("handle_verify_wait_match_complete: match MKBP event received (0x%08x)", fp_events);
      fpi_ssm_next_state (ssm);
      return;
    }

  fpi_ssm_jump_to_state_delayed (ssm, VERIFY_WAIT_MATCH_COMPLETE, 50);
}

static void
crfpmoc_verify_check_cb (CrfpMocEcTransfer *transfer, GAsyncResult *res, gpointer user_data)
{
  g_autoptr(GError) error = NULL;
  FpiSsm *ssm = user_data;
  FpDevice *device = fpi_ssm_get_device (ssm);
  guint32 mode;

  if (!crfpmoc_ec_transfer_submit_finish (res, &error))
    {
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  mode = GUINT32_FROM_LE (((struct crfpmoc_ec_response_fp_mode *) transfer->indata)->mode);

  if (mode & CRFPMOC_FP_MODE_MATCH)
    {
      fpi_ssm_jump_to_state (ssm, VERIFY_WAIT_MATCH_COMPLETE);
    }
  else if (mode == 0)
    {
      fpi_device_report_finger_status_changes (device,
                                               FP_FINGER_STATUS_PRESENT,
                                               FP_FINGER_STATUS_NONE);
      fpi_ssm_next_state (ssm);
    }
  else
    {
      fpi_device_report_finger_status_changes (device,
                                               FP_FINGER_STATUS_PRESENT,
                                               FP_FINGER_STATUS_NONE);
      fpi_ssm_mark_failed (ssm, fpi_device_error_new_msg (FP_DEVICE_ERROR_PROTO,
                                                          "FP mode: (0x%x)", mode));
    }
}

static void
handle_verify_sensor_check (FpiSsm *ssm)
{
  FpDevice *device = fpi_ssm_get_device (ssm);
  struct crfpmoc_ec_params_fp_mode p = { .mode = CRFPMOC_FP_MODE_DONT_CHANGE };
  CrfpMocEcTransfer *transfer;

  transfer = crfpmoc_ec_transfer_new_cmd (device, CRFPMOC_EC_CMD_FP_MODE, 0,
                                          &p, sizeof (p), sizeof (struct crfpmoc_ec_response_fp_mode));
  crfpmoc_ec_transfer_submit_cmd (transfer, fpi_device_get_cancellable (device),
                                  crfpmoc_verify_check_cb, ssm);
}

static void
complete_verification (FpiSsm  *ssm,
                       FpPrint *matched_print,
                       FpPrint *scanned_print)
{
  FpDevice *device = fpi_ssm_get_device (ssm);
  FpiDeviceAction action = fpi_device_get_current_action (device);

  if (action == FPI_DEVICE_ACTION_IDENTIFY)
    {
      fp_dbg ("complete_verification: identify_report");
      fpi_device_identify_report (device, matched_print, scanned_print, NULL);
    }
  else if (action == FPI_DEVICE_ACTION_VERIFY)
    {
      fp_dbg ("complete_verification: verify_report");
      fpi_device_verify_report (device,
                                matched_print ? FPI_MATCH_SUCCESS : FPI_MATCH_FAIL,
                                scanned_print, NULL);
    }
  else
    {
      g_assert_not_reached ();
    }

  fpi_ssm_jump_to_state (ssm, VERIFY_RESET);
}

static void
handle_verify_check (FpiSsm *ssm)
{
  FpDevice *device = fpi_ssm_get_device (ssm);
  CrfpMocEcTransfer *transfer;

  transfer = crfpmoc_fp_info_transfer_new (device, 3);
  crfpmoc_ec_transfer_submit_cmd (transfer, fpi_device_get_cancellable (device),
                                  crfpmoc_verify_fp_info_cb, ssm);
}

static void
crfpmoc_wait_for_device_idle (FpiSsm *ssm)
{
  FpDevice *device = fpi_ssm_get_device (ssm);
  struct crfpmoc_ec_params_fp_mode p = { .mode = CRFPMOC_FP_MODE_DONT_CHANGE };
  CrfpMocEcTransfer *transfer;

  transfer = crfpmoc_ec_transfer_new_cmd (device, CRFPMOC_EC_CMD_FP_MODE, 0,
                                          &p, sizeof (p), sizeof (struct crfpmoc_ec_response_fp_mode));
  crfpmoc_ec_transfer_submit_cmd (transfer, fpi_device_get_cancellable (device),
                                  crfpmoc_wait_idle_cb, ssm);
}

/* Finger up state machine */
static void
handle_verify_clear_storage (FpiSsm *ssm)
{
  FpDevice *device = fpi_ssm_get_device (ssm);

  FpiSsm *sub = fpi_ssm_new (device, crfpmoc_clear_storage_run_state,
                             CLEAR_STORAGE_STATES);

  crfpmoc_ssm_start_subsm (FPI_DEVICE_CRFPMOC (device), sub);
}

static void
handle_verify_finger_up (FpiSsm *ssm)
{
  FpDevice *device = fpi_ssm_get_device (ssm);

  FpiSsm *sub = fpi_ssm_new (device, crfpmoc_finger_up_run_state,
                             FINGER_UP_STATES);

  crfpmoc_ssm_start_subsm (FPI_DEVICE_CRFPMOC (device), sub);
}

/* Clear storage state machine */
static void
crfpmoc_verify_run_state (FpiSsm *ssm, FpDevice *device)
{
  switch (fpi_ssm_get_cur_state (ssm))
    {
    case VERIFY_CLEAR_STORAGE:
      handle_verify_clear_storage (ssm);
      break;

    case VERIFY_FINGER_UP:
      handle_verify_finger_up (ssm);
      break;

    case VERIFY_ENSURE_KEYS:
      handle_ensure_keys (ssm);
      break;

    case VERIFY_UPLOAD_TEMPLATE:
      handle_verify_upload_template (ssm);
      break;

    case VERIFY_SENSOR_MATCH_SUBMIT:
      handle_verify_sensor_match_submit (ssm);
      break;

    case VERIFY_SENSOR_MATCH_DONE:
      handle_verify_sensor_match_done (ssm);
      break;

    case VERIFY_WAIT_MATCH_COMPLETE:
      handle_verify_wait_match_complete (ssm);
      break;

    case VERIFY_SENSOR_CHECK:
      handle_verify_sensor_check (ssm);
      break;

    case VERIFY_CHECK:
      handle_verify_check (ssm);
      break;

    case VERIFY_RESET:
      handle_verify_reset (ssm);
      break;

    default:
      g_assert_not_reached ();
    }
}

static void
crfpmoc_finger_up_run_state (FpiSsm *ssm, FpDevice *device)
{
  switch (fpi_ssm_get_cur_state (ssm))
    {
    case FINGER_UP_START:
      handle_wait_finger_up (ssm, FINGER_UP_TIMEOUT, 5000);
      break;

    case FINGER_UP_DONE:
      fpi_ssm_mark_completed (ssm);
      break;

    /* User has not lifted finger. Send a retry error to prompt them */
    case FINGER_UP_TIMEOUT:
      fpi_ssm_mark_failed (ssm,
                           fpi_device_retry_new (FP_DEVICE_RETRY_REMOVE_FINGER));
      break;
    }
}

static void
crfpmoc_clear_storage_run_state (FpiSsm *ssm, FpDevice *device)
{
  SubSsmData *data = fpi_ssm_get_data (ssm);
  struct crfpmoc_ec_params_fp_mode p = { .mode = 0 };
  CrfpMocEcTransfer *transfer;

  switch (fpi_ssm_get_cur_state (ssm))
    {
    case CLEAR_STORAGE_SENSOR_RESET:
      data->clear_step = 0;

      transfer = crfpmoc_ec_transfer_new_cmd (device, CRFPMOC_EC_CMD_FP_MODE, 0,
                                              &p, sizeof (p), sizeof (struct crfpmoc_ec_response_fp_mode));
      crfpmoc_ec_transfer_submit_cmd (transfer, fpi_device_get_cancellable (device),
                                      crfpmoc_clear_storage_cb, ssm);
      break;

    case CLEAR_STORAGE_SENSOR_WAIT:
      crfpmoc_wait_for_device_idle (ssm);
      break;

    case CLEAR_STORAGE_SENSOR_DONE:
      if (fpi_device_get_current_action (device) == FPI_DEVICE_ACTION_CLEAR_STORAGE)
        {
          fp_dbg ("crfpmoc_clear_storage_run_state: clear_storage_complete");
          fpi_device_clear_storage_complete (device, NULL);
        }
      fpi_ssm_mark_completed (ssm);
      break;
    }
}

/* Keys sub-SSM callbacks */
static void
crfpmoc_keys_enc_status_cb (CrfpMocEcTransfer *transfer, GAsyncResult *res, gpointer user_data)
{
  g_autoptr(GError) error = NULL;
  FpiSsm *ssm = user_data;
  struct crfpmoc_ec_response_fp_encryption_status *resp;

  guint32 status;

  if (!crfpmoc_ec_transfer_submit_finish (res, &error))
    {
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  resp = (struct crfpmoc_ec_response_fp_encryption_status *) transfer->indata;
  status = GUINT32_FROM_LE (resp->status);
  fp_dbg ("crfpmoc_keys_enc_status_cb: FPMCU encryption status: 0x%08x (valid_flags: 0x%08x)",
          status, GUINT32_FROM_LE (resp->valid_flags));

  if (!(status & CRFPMOC_FP_ENC_STATUS_SEED_SET))
    fpi_ssm_next_state (ssm); /* KEYS_SET_SEED */
  else
    /* The seed (and the SEED_SET flag) live in FPMCU RAM, not flash: they
     * survive a warm reboot only because the FPMCU stays powered, and on a cold
     * boot they are lost and the host re-sends FP_SEED from
     * /var/lib/fprint/crfpmoc.key.  The user context (user_id) is also RAM.
     * FP_CONTEXT_ASYNC triggers a sensor reset (fp_sensor_open, ~175 ms) that
     * re-initializes the sensor; that bring-up is required before any crypto
     * operation, so we must run FP_CONTEXT on every open even when the seed is
     * already set.  Only the FP_SEED step can be skipped. */
    fpi_ssm_jump_to_state (ssm, KEYS_CLEAR_MODE);
}

static void
crfpmoc_keys_seed_cb (CrfpMocEcTransfer *transfer, GAsyncResult *res, gpointer user_data)
{
  g_autoptr(GError) error = NULL;
  FpiSsm *ssm = user_data;

  if (!crfpmoc_ec_transfer_submit_finish (res, &error))
    {
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  fpi_ssm_next_state (ssm); /* KEYS_CLEAR_MODE */
}

static void
crfpmoc_keys_clear_mode_cb (CrfpMocEcTransfer *transfer, GAsyncResult *res, gpointer user_data)
{
  g_autoptr(GError) error = NULL;
  FpiSsm *ssm = user_data;

  if (!crfpmoc_ec_transfer_submit_finish (res, &error))
    {
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  /* FP_CONTEXT_ASYNC internally triggers FP_MODE_RESET_SENSOR, which the EC
   * rejects (INVALID_PARAM) if any other mode bit (e.g. FP_MODE_FINGER_UP set
   * by the verify finger-up check) is still active.  Clear the sensor mode
   * here so the reset always has a clean slate. */
  fp_dbg ("crfpmoc_keys_clear_mode_cb: sensor mode cleared before context reset");
  fpi_ssm_next_state (ssm); /* KEYS_CTX_ASYNC */
}

static void
crfpmoc_keys_ctx_async_cb (CrfpMocEcTransfer *transfer, GAsyncResult *res, gpointer user_data)
{
  g_autoptr(GError) error = NULL;
  FpiSsm *ssm = user_data;

  if (!crfpmoc_ec_transfer_submit_finish (res, &error))
    {
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  fpi_ssm_next_state (ssm); /* KEYS_CTX_POLL */
}

static void
crfpmoc_keys_ctx_poll_cb (CrfpMocEcTransfer *transfer, GAsyncResult *res, gpointer user_data)
{
  g_autoptr(GError) error = NULL;
  FpiSsm *ssm = user_data;
  SubSsmData *data = fpi_ssm_get_data (ssm);
  KeysData *keys_data = data->sub_data;

  if (!crfpmoc_ec_transfer_submit_finish (res, &error))
    {
      if (g_error_matches (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_BUSY) &&
          keys_data->poll_attempts < 40)
        {
          keys_data->poll_attempts++;
          fp_dbg ("Context setting is still in progress. Attempt %d of %d",
                  keys_data->poll_attempts, 40);
          g_clear_error (&error);

          fpi_ssm_jump_to_state_delayed (ssm, KEYS_CTX_POLL, 80);
          return;
        }

      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  fp_dbg ("Context set successfully.");
  fpi_ssm_next_state (ssm); /* KEYS_DONE */
}

static void
crfpmoc_keys_run_state (FpiSsm *ssm, FpDevice *device)
{
  FpiDeviceCrfpMoc *self = FPI_DEVICE_CRFPMOC (device);
  CrfpMocEcTransfer *transfer;

  switch (fpi_ssm_get_cur_state (ssm))
    {
    case KEYS_ENC_STATUS:
      {
        transfer = crfpmoc_ec_transfer_new_cmd (device, CRFPMOC_EC_CMD_FP_ENC_STATUS, 0,
                                                NULL, 0, sizeof (struct crfpmoc_ec_response_fp_encryption_status));
        crfpmoc_ec_transfer_submit_cmd (transfer, fpi_device_get_cancellable (device),
                                        crfpmoc_keys_enc_status_cb, ssm);
        break;
      }

    case KEYS_SET_SEED:
      {
        struct crfpmoc_ec_params_fp_seed p = {
          .struct_version = GUINT16_TO_LE (CRFPMOC_FP_TEMPLATE_FORMAT_VERSION),
        };
        memcpy (p.seed, self->seed, sizeof (p.seed));
        transfer = crfpmoc_ec_transfer_new_cmd (device, CRFPMOC_EC_CMD_FP_SEED, 0,
                                                &p, sizeof (p), 0);
        crfpmoc_ec_transfer_submit_cmd (transfer, fpi_device_get_cancellable (device),
                                        crfpmoc_keys_seed_cb, ssm);
        break;
      }

    case KEYS_CLEAR_MODE:
      {
        struct crfpmoc_ec_params_fp_mode p = { .mode = 0 };
        transfer = crfpmoc_ec_transfer_new_cmd (device, CRFPMOC_EC_CMD_FP_MODE, 0,
                                                &p, sizeof (p),
                                                sizeof (struct crfpmoc_ec_response_fp_mode));
        crfpmoc_ec_transfer_submit_cmd (transfer, fpi_device_get_cancellable (device),
                                        crfpmoc_keys_clear_mode_cb, ssm);
        break;
      }

    case KEYS_CTX_ASYNC:
      {
        struct crfpmoc_ec_params_fp_context_v1 p = {
          .action = CRFPMOC_FP_CONTEXT_ASYNC,
        };
        memcpy (p.userid, self->context, sizeof (p.userid));
        transfer = crfpmoc_ec_transfer_new_cmd (device, CRFPMOC_EC_CMD_FP_CONTEXT, 1,
                                                &p, sizeof (p), 0);
        crfpmoc_ec_transfer_submit_cmd (transfer, fpi_device_get_cancellable (device),
                                        crfpmoc_keys_ctx_async_cb, ssm);
        break;
      }

    case KEYS_CTX_POLL:
      {
        struct crfpmoc_ec_params_fp_context_v1 p = {
          .action = CRFPMOC_FP_CONTEXT_GET_RESULT,
        };
        /* FP_CONTEXT_GET_RESULT would copy p.userid into the EC's user_id, an
         * input to Chromium's template key derivation.  We deliberately leave
         * userid zeroed: the current driver relies on a zero context so that
         * enroll/verify stay consistently bound across reboots.  Sending a
         * non-zero context here would require re-enrolling all existing
         * templates. */
        transfer = crfpmoc_ec_transfer_new_cmd (device, CRFPMOC_EC_CMD_FP_CONTEXT, 1,
                                                &p, sizeof (p), 0);
        crfpmoc_ec_transfer_submit_cmd (transfer, fpi_device_get_cancellable (device),
                                        crfpmoc_keys_ctx_poll_cb, ssm);
        break;
      }

    case KEYS_DONE:
      fpi_ssm_mark_completed (ssm);
      break;
    }
}

/* Download sub-SSM callbacks */
static void
crfpmoc_download_chunk_cb (CrfpMocEcTransfer *transfer, GAsyncResult *res, gpointer user_data)
{
  g_autoptr(GError) error = NULL;
  FpiSsm *ssm = user_data;
  SubSsmData *data = fpi_ssm_get_data (ssm);
  DownloadData *ddata = data->sub_data;
  FpDevice *device = fpi_ssm_get_device (ssm);
  FpiDeviceCrfpMoc *self = FPI_DEVICE_CRFPMOC (device);
  gsize stride;

  if (!crfpmoc_ec_transfer_submit_finish (res, &error))
    {
      if (g_error_matches (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_BUSY) &&
          ddata->num_attempts < 3)
        {
          ddata->num_attempts++;
          fp_dbg ("crfpmoc_download_chunk_cb: retry frame, attempt %d", ddata->num_attempts);

          {
            struct crfpmoc_ec_params_fp_frame p;
            CrfpMocEcTransfer *new_transfer;

            stride = MIN (self->max_insize, ddata->remaining);
            p = (struct crfpmoc_ec_params_fp_frame){
              .offset = ddata->offset,
              .size = stride,
            };
            new_transfer = crfpmoc_ec_transfer_new_cmd (
              device, CRFPMOC_EC_CMD_FP_FRAME, 0,
              &p, sizeof (p), stride);
            crfpmoc_ec_transfer_submit_cmd (new_transfer, fpi_device_get_cancellable (device),
                                            crfpmoc_download_chunk_cb, ssm);
          }
          return;
        }

      if (g_error_matches (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_NOT_SUPPORTED))
        fp_dbg ("Access denied, stopping retry");

      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  stride = MIN (self->max_insize, ddata->remaining);
  {
    gsize old_offset = ddata->buf_offset;

    if (!g_log_writer_default_would_drop (G_LOG_LEVEL_DEBUG, G_LOG_DOMAIN))
      {
        guint8 *ptr = transfer->indata;
        ddata->sum = crfpmoc_sum (ddata->sum, ptr, stride);
      }

    memcpy (ddata->buffer + old_offset, transfer->indata, stride);
    ddata->offset += stride;
    ddata->buf_offset += stride;
    ddata->remaining -= stride;

    fp_dbg ("crfpmoc_download_chunk_cb: read %zu bytes at offset %lu, remaining %zu",
            stride, (unsigned long) old_offset, ddata->remaining);
  }

  if (ddata->remaining > 0)
    fpi_ssm_jump_to_state (ssm, DOWNLOAD_CHUNK);
  else
    fpi_ssm_next_state (ssm); /* DOWNLOAD_FINISHED */
}

static void
crfpmoc_download_run_state (FpiSsm *ssm, FpDevice *device)
{
  FpiDeviceCrfpMoc *self = FPI_DEVICE_CRFPMOC (device);
  SubSsmData *data = fpi_ssm_get_data (ssm);
  DownloadData *ddata = data->sub_data;

  switch (fpi_ssm_get_cur_state (ssm))
    {
    case DOWNLOAD_CHUNK:
      {
        CrfpMocEcTransfer *transfer;
        gsize stride = MIN (self->max_insize, ddata->remaining);
        struct crfpmoc_ec_params_fp_frame p = {
          .offset = ddata->offset,
          .size = stride,
        };
        ddata->num_attempts = 0;

        transfer = crfpmoc_ec_transfer_new_cmd (device, CRFPMOC_EC_CMD_FP_FRAME,
                                                0, &p, sizeof (p), stride);
        crfpmoc_ec_transfer_submit_cmd (transfer, fpi_device_get_cancellable (device),
                                        crfpmoc_download_chunk_cb, ssm);
        break;
      }

    case DOWNLOAD_FINISHED:
      {
        FpPrint *print;
        g_autofree gchar *user_id = NULL;

        fpi_device_get_enroll_data (device, &print);

        user_id = fpi_print_generate_user_id (print);
        fp_dbg ("New fingerprint ID: %s", user_id);
        g_object_set (print, "description", user_id, NULL);

        fpi_print_set_type (print, FPI_PRINT_RAW);
        crfpmoc_set_print_data (print, ddata->buffer, ddata->buf_offset);

        fp_info ("download sub-SSM: enroll_complete");
        fpi_ssm_mark_completed (ssm);
        break;
      }

    default:
      g_assert_not_reached ();
    }
}

/* Upload sub-SSM callbacks and data destroy */
static void
upload_data_free (gpointer data)
{
  UploadData *udata = data;

  g_clear_pointer (&udata->data, g_free);
  g_clear_pointer (&udata->prints, g_ptr_array_unref);
  g_free (data);
}

static void
crfpmoc_upload_chunk_cb (CrfpMocEcTransfer *transfer, GAsyncResult *res, gpointer user_data)
{
  g_autoptr(GError) error = NULL;
  FpiSsm *ssm = user_data;
  FpDevice *device = fpi_ssm_get_device (ssm);
  FpiDeviceCrfpMoc *self = FPI_DEVICE_CRFPMOC (device);
  SubSsmData *data = fpi_ssm_get_data (ssm);
  UploadData *udata = data->sub_data;
  gsize max_chunk;

  if (!crfpmoc_ec_transfer_submit_finish (res, &error))
    {
      fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
      return;
    }

  max_chunk = self->max_outsize -
              offsetof (struct crfpmoc_ec_params_fp_template, data) - 4;
  guint32 tlen = MIN (max_chunk, udata->remaining);
  udata->offset += tlen;
  udata->remaining -= tlen;

  if (udata->remaining > 0)
    {
      fpi_ssm_jump_to_state (ssm, UPLOAD_CHUNK);
    }
  else
    {
      fp_dbg ("uploaded template %u, %u bytes", udata->current_print, udata->offset);
      udata->current_print++;
      udata->offset = 0;
      fpi_ssm_jump_to_state (ssm, UPLOAD_NEXT_PRINT);
    }
}

static void
crfpmoc_upload_run_state (FpiSsm *ssm, FpDevice *device)
{
  FpiDeviceCrfpMoc *self = FPI_DEVICE_CRFPMOC (device);
  SubSsmData *data = fpi_ssm_get_data (ssm);
  UploadData *udata = data->sub_data;
  gsize max_chunk;

  max_chunk = self->max_outsize -
              offsetof (struct crfpmoc_ec_params_fp_template, data) - 4;

  switch (fpi_ssm_get_cur_state (ssm))
    {
    case UPLOAD_NEXT_PRINT:
      {
        if (udata->current_print >= udata->prints->len)
          {
            fpi_ssm_jump_to_state (ssm, UPLOAD_DONE);
            break;
          }

        FpPrint *print = g_ptr_array_index (udata->prints, udata->current_print);
        g_autofree guint8 *template = NULL;
        size_t size = 0;
        g_autoptr(GError) error = NULL;

        if (!crfpmoc_get_print_data (print, &template, &size, &error))
          {
            fpi_ssm_mark_failed (ssm, g_steal_pointer (&error));
            break;
          }

        if (size != self->template_size)
          {
            fpi_ssm_mark_failed (ssm, fpi_device_error_new_msg (
                                   FP_DEVICE_ERROR_DATA_INVALID,
                                   "Template size %zu does not match sensor expected size %u",
                                   size, self->template_size));
            break;
          }

        g_clear_pointer (&udata->data, g_free);
        udata->data = g_steal_pointer (&template);
        udata->remaining = size;
        udata->offset = 0;
        udata->sum = 0;

        fpi_ssm_jump_to_state (ssm, UPLOAD_CHUNK);
        break;
      }

    case UPLOAD_CHUNK:
      {
        guint32 tlen = MIN (max_chunk, udata->remaining);
        gsize struct_size = offsetof (struct crfpmoc_ec_params_fp_template, data) + tlen;
        struct crfpmoc_ec_params_fp_template *p = g_malloc0 (struct_size);
        CrfpMocEcTransfer *transfer;
        guint32 flags = 0;

        if (udata->remaining <= max_chunk)
          flags |= CRFPMOC_FP_TEMPLATE_COMMIT;

        p->offset = GUINT32_TO_LE (udata->offset);
        p->size = GUINT32_TO_LE (tlen | flags);

        memcpy (p->data, udata->data + udata->offset, tlen);

        if (!g_log_writer_default_would_drop (G_LOG_LEVEL_DEBUG, G_LOG_DOMAIN))
          udata->sum = crfpmoc_sum (udata->sum, p->data, tlen);

        transfer = crfpmoc_ec_transfer_new_cmd (device, CRFPMOC_EC_CMD_FP_TEMPLATE, 0,
                                                p, struct_size, 0);
        g_free (p);

        crfpmoc_ec_transfer_submit_cmd (transfer, fpi_device_get_cancellable (device),
                                        crfpmoc_upload_chunk_cb, ssm);
        break;
      }

    case UPLOAD_DONE:
      fpi_ssm_mark_completed (ssm);
      break;
    }
}

static void
crfpmoc_verify_ssm_done (FpiSsm *ssm, FpDevice *device,
                         GError *error)
{
  fp_dbg ("crfpmoc_verify_ssm_done");
  FpiDeviceCrfpMoc *self = FPI_DEVICE_CRFPMOC (device);

  g_assert (!self->task_ssm || self->task_ssm == ssm);
  self->task_ssm = NULL;

  if (error)
    {
      g_autoptr(GError) report_err = NULL;

      if (error->domain == FP_DEVICE_RETRY)
        {
          report_err = g_error_copy (error);
          if (fpi_device_get_current_action (device) == FPI_DEVICE_ACTION_VERIFY)
            fpi_device_verify_report (device, FPI_MATCH_ERROR, NULL, g_steal_pointer (&report_err));
          else
            fpi_device_identify_report (device, NULL, NULL, g_steal_pointer (&report_err));
        }

      if (fpi_device_get_current_action (device) == FPI_DEVICE_ACTION_VERIFY)
        {
          fp_dbg ("crfpmoc_verify_ssm_done: verify_complete with error: %s", error->message);
          fpi_device_verify_complete (device, error);
        }
      else
        {
          fp_dbg ("crfpmoc_verify_ssm_done: identify_complete with error: %s", error->message);
          fpi_device_identify_complete (device, error);
        }
    }
  else
    {
      if (fpi_device_get_current_action (device) == FPI_DEVICE_ACTION_VERIFY)
        {
          fp_dbg ("crfpmoc_verify_ssm_done: verify_complete success");
          fpi_device_verify_complete (device, NULL);
        }
      else
        {
          fp_dbg ("crfpmoc_verify_ssm_done: identify_complete success");
          fpi_device_identify_complete (device, NULL);
        }
    }
}

/* Handle device verify or identify requests. These are very similar
 * only differing in request prints and report formats. The procedure
 * for each is identical.
 */
static void
crfpmoc_identify_verify (FpDevice *device)
{
  FpiDeviceCrfpMoc *self = FPI_DEVICE_CRFPMOC (device);

  fp_dbg ("%s",
          fpi_device_get_current_action (device) == FPI_DEVICE_ACTION_IDENTIFY ?
          "Identify" : "Verify");

  g_assert (self->task_ssm == NULL);
  self->task_ssm = fpi_ssm_new_full (device, crfpmoc_verify_run_state, VERIFY_STATES,
                                     VERIFY_RESET, "crfpmoc_verify");
  crfpmoc_ssm_start (self, self->task_ssm, crfpmoc_verify_ssm_done);
}

/* Handle device clear storage request. */
static void
crfpmoc_clear_storage (FpDevice *device)
{
  FpiDeviceCrfpMoc *self = FPI_DEVICE_CRFPMOC (device);

  fp_dbg ("Clear storage");

  g_assert (self->task_ssm == NULL);
  self->task_ssm = fpi_ssm_new (device, crfpmoc_clear_storage_run_state, CLEAR_STORAGE_STATES);
  crfpmoc_ssm_start (self, self->task_ssm, crfpmoc_task_ssm_done);
}

/* Handle device initialization. Called before any other device op.
 */
static void
fpi_device_crfpmoc_init (FpiDeviceCrfpMoc *self)
{
  self->emul_fd = -1;
  self->fp_info_version = 0;
}

static void
crfpmoc_probe (FpDevice *device)
{
  fpi_device_probe_complete (device, NULL, NULL, NULL);
}

static void
crfpmoc_resume (FpDevice *device)
{
  crfpmoc_reset_sync (device);
  fpi_device_resume_complete (device, NULL);
}

/* Register the device. Note, this function is declared in the
 * G_DEFINE_TYPE macro and registered there.
 */
static void
fpi_device_crfpmoc_class_init (FpiDeviceCrfpMocClass *klass)
{
  FpDeviceClass *dev_class = FP_DEVICE_CLASS (klass);

  dev_class->id = FP_COMPONENT;
  dev_class->full_name = CRFPMOC_DRIVER_FULLNAME;

  dev_class->type = FP_DEVICE_TYPE_UDEV;
  dev_class->scan_type = FP_SCAN_TYPE_PRESS;
  dev_class->id_table = crfpmoc_id_table;
  dev_class->nr_enroll_stages = CRFPMOC_NR_ENROLL_STAGES;
  dev_class->temp_hot_seconds = -1;

  dev_class->probe = crfpmoc_probe;
  dev_class->open = crfpmoc_open;
  dev_class->cancel = crfpmoc_cancel;
  dev_class->suspend = crfpmoc_suspend;
  dev_class->resume = crfpmoc_resume;
  dev_class->close = crfpmoc_close;
  dev_class->enroll = crfpmoc_enroll;
  dev_class->identify = crfpmoc_identify_verify;
  dev_class->verify = crfpmoc_identify_verify;
  dev_class->clear_storage = crfpmoc_clear_storage;

  fpi_device_class_auto_initialize_features (dev_class);
}

/* The pure protocol parsing module is compiled into this translation
 * unit: the packaged build lists driver sources explicitly in
 * libfprint's meson.build, which the driver overlay cannot modify, so
 * compiling the implementation here guarantees it is always built.
 * The standalone unit test compiles crfpmoc-proto.c directly instead,
 * so the exact same parsing code is exercised either way.
 */
#include "crfpmoc-proto.c"
