#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "sdkconfig.h"
#if CONFIG_MUSE_PHONE_BRIDGE
void muse_speech_init(void);
bool muse_speech_request(const char *note, const char *message);
bool muse_speech_busy(void);
bool muse_speech_started(void);
void muse_speech_stop(void); /* Input task: nonblocking; task owns teardown. */
void muse_speech_reset(void); /* New turn, permits speech again. */
void muse_speech_receive(const uint8_t *data, size_t len);
#else
static inline void muse_speech_init(void) {}
static inline bool muse_speech_request(const char *n, const char *m) { (void)n; (void)m; return true; }
static inline bool muse_speech_busy(void) { return false; }
static inline bool muse_speech_started(void) { return false; }
static inline void muse_speech_stop(void) {}
static inline void muse_speech_reset(void) {}
#endif
