/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stdbool.h>
#include "sdkconfig.h"
#include "muse_state.h"

typedef struct {
    char text[MUSE_CAPTION_MAX];
    int page, pages, role_page, role_pages;
    bool assistant, truncated, ready;
} muse_passport_page_t;

#if CONFIG_MUSE_PHONE_BRIDGE
void muse_passport_reader_start(void);
/* All calls are safe from voice, input and LVGL tasks. */
void muse_passport_reader_reset(void);
void muse_passport_reader_note(const char *identifier);
void muse_passport_reader_step(int direction);
bool muse_passport_reader_page(muse_passport_page_t *out);
#else
static inline void muse_passport_reader_start(void) {}
static inline void muse_passport_reader_reset(void) {}
static inline void muse_passport_reader_note(const char *identifier) { (void)identifier; }
static inline void muse_passport_reader_step(int direction) { (void)direction; }
static inline bool muse_passport_reader_page(muse_passport_page_t *out) { (void)out; return false; }
#endif
