#pragma once
#include <stdint.h>
/* Raw RFC 6716 packets, never an Ogg container. 16 kHz mono, 60 ms. */
void *passport_opus_encoder_create(void);
int passport_opus_encode(void *encoder, const int16_t pcm[960], uint8_t packet[120]);
void passport_opus_encoder_destroy(void *encoder);
void *passport_opus_decoder_create(void);
int passport_opus_decode(void *decoder, const uint8_t *packet, int bytes, int16_t pcm[960]);
void passport_opus_decoder_destroy(void *decoder);
