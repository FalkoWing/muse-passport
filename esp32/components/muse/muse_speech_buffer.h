#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define MUSE_SPEECH_WINDOW 8
#define MUSE_SPEECH_PACKET 120
/* Caller serializes access. Wire: session u32, frame u32, kind u8, raw Opus.
 * kind: 0 frame, 1 end, 2 probe abort, 3 restart, 4 terminal error,
 * 5 frame with original-text scalar offset u32 before raw Opus. */
typedef struct {
    uint32_t session, received, consumed;
    unsigned count, head;
    bool ended, abort, started, rejected, terminal;
    uint8_t frames[MUSE_SPEECH_WINDOW][MUSE_SPEECH_PACKET];
    uint8_t lengths[MUSE_SPEECH_WINDOW];
    uint32_t origins[MUSE_SPEECH_WINDOW], taken_origin;
} muse_speech_buffer_t;
void muse_speech_buffer_begin(muse_speech_buffer_t *b, uint32_t session);
bool muse_speech_buffer_feed(muse_speech_buffer_t *b, const uint8_t *data, size_t len);
size_t muse_speech_buffer_take(muse_speech_buffer_t *b, uint8_t *out);
