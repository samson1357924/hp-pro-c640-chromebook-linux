/*
 * SPDX-License-Identifier: LGPL-2.1-or-later
 *
 * Minimal libfprint mock definitions for unit testing crfpmoc protocol parsing.
 *
 * Copyright (C) 2026 HP Pro c640 Linux Enablement Contributors
 * Copyright (C) 2026 Samson <https://github.com/samson1357924>
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

#ifndef MOCK_LIBFPRINT_H
#define MOCK_LIBFPRINT_H

#include <glib.h>
#include <stdint.h>

#ifndef BIT
#define BIT(nr) (1UL << (nr))
#endif

#ifndef MIN
#define MIN(a, b) (((a) < (b)) ? (a) : (b))
#endif

#ifndef MAX
#define MAX(a, b) (((a) > (b)) ? (a) : (b))
#endif

#endif /* MOCK_LIBFPRINT_H */
