/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include "sdkconfig.h"
/* Passport ships with the existing GB2312 font. Other boards retain their
 * current UI and fonts; wire/service identifiers are never localized. */
#if CONFIG_MUSE_BOARD_FOLOTOY_PASSPORT
#define MUSE_UI_TEXT(en, zh) zh
#else
#define MUSE_UI_TEXT(en, zh) en
#endif
