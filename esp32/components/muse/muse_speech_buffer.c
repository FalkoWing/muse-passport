#include "muse_speech_buffer.h"
#include <string.h>
static uint32_t u32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24;
}
void muse_speech_buffer_begin(muse_speech_buffer_t *b, uint32_t session) {
    memset(b, 0, sizeof(*b)); b->session = session;
}
bool muse_speech_buffer_feed(muse_speech_buffer_t *b, const uint8_t *p, size_t len) {
    if (len < 9 || !b->session || u32(p) != b->session) return false;
    uint32_t frame = u32(p+4);
    unsigned kind = p[8];
    if ((kind == 2 || kind == 4) && len == 9) { b->abort = true; b->terminal=kind==4; return true; }
    if (kind == 3 && len == 9 && b->rejected && !b->started) {
        muse_speech_buffer_begin(b, b->session); return true;
    }
    if (b->rejected || b->abort || b->ended) return false;
    if (frame != b->received || kind > 1 || (kind == 1 ? len != 9 : len < 10 || len > 129)
        || (kind == 0 && b->count == MUSE_SPEECH_WINDOW)) {
        b->abort = b->terminal = true; return false;
    }
    if (kind == 1) { b->ended = true; return true; }
    unsigned at = (b->head + b->count) % MUSE_SPEECH_WINDOW;
    b->lengths[at] = len - 9;
    memcpy(b->frames[at], p+9, len-9);
    b->count++; b->received++;
    return true;
}
size_t muse_speech_buffer_take(muse_speech_buffer_t *b, uint8_t *out) {
    if (!b->count || b->abort || b->rejected) return 0;
    size_t len = b->lengths[b->head];
    memcpy(out, b->frames[b->head], len);
    b->head = (b->head+1) % MUSE_SPEECH_WINDOW;
    b->count--; b->consumed++;
    return len;
}
