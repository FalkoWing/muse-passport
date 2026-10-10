/* Copyright (c) Meta Platforms, Inc. and affiliates.
 * Derived from esp32/avatar/muse_pixel.c; its avatar license applies. */
#pragma once
#include "lvgl.h"
#include "muse_state.h"
const lv_image_dsc_t *passport_avatar_frame(muse_mode_t mode, bool small, unsigned tick, float level);
