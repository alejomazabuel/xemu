/*
 * QEMU libpcap network client
 *
 * Copyright (C) 2021 Matt Borgerson
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#ifndef NET_PCAP_H
#define NET_PCAP_H

#if defined(__APPLE__)
#include <TargetConditionals.h>
#else
#define TARGET_OS_IPHONE 0
#endif

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
typedef struct pcap_if pcap_if_t;
#define PCAP_ERRBUF_SIZE 256
#else
#include <pcap/pcap.h>
#endif

#if defined(_WIN32)
#include "net/capture_win_ifnames.h"
#endif

#endif
