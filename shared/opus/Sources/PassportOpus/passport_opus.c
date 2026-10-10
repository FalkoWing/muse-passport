#include "public/passport_opus.h"
#include "include/opus.h"
void *passport_opus_encoder_create(void) {
    int error;
    OpusEncoder *e = opus_encoder_create(16000, 1, OPUS_APPLICATION_VOIP, &error);
    if (!e) return 0;
    if (opus_encoder_ctl(e, OPUS_SET_BITRATE(16000)) != OPUS_OK
        || opus_encoder_ctl(e, OPUS_SET_VBR(0)) != OPUS_OK
        || opus_encoder_ctl(e, OPUS_SET_COMPLEXITY(3)) != OPUS_OK
        || opus_encoder_ctl(e, OPUS_SET_DTX(0)) != OPUS_OK
        || opus_encoder_ctl(e, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE)) != OPUS_OK) {
        opus_encoder_destroy(e); return 0;
    }
    return e;
}
int passport_opus_encode(void *e, const int16_t pcm[960], uint8_t packet[120]) {
    return e ? opus_encode(e, pcm, 960, packet, 120) : OPUS_BAD_ARG;
}
void passport_opus_encoder_destroy(void *e) { if (e) opus_encoder_destroy(e); }
void *passport_opus_decoder_create(void) {
    int error;
    return opus_decoder_create(16000, 1, &error);
}
int passport_opus_decode(void *d, const uint8_t *packet, int bytes, int16_t pcm[960]) {
    if (!d || !packet || bytes < 1 || bytes > 120
        || opus_packet_get_nb_samples(packet, bytes, 16000) != 960
        || opus_packet_get_nb_channels(packet) != 1) return OPUS_BAD_ARG;
    return opus_decode(d, packet, bytes, pcm, 960, 0);
}
void passport_opus_decoder_destroy(void *d) { if (d) opus_decoder_destroy(d); }
