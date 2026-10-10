# libopus 1.6.1

Generic fixed point sources from [Xiph's official release](https://opus-codec.org/downloads/).
Archive SHA-256: `6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1`.
Sources and copyright headers are unchanged; see `Sources/PassportOpus/COPYING`.
Only the single stream codec is built. No neural enhancement, assembly, multistream,
Ogg or model weights. `config.h` and `passport_opus.c` are this project's integration.

The same source and wrapper build in SwiftPM, Android NDK and ESP-IDF.
Reply speech is mono 16 kHz, hard CBR 16 kbps, 960 samples / 60 ms,
120 bytes per packet. The ESP32 linker discards unused encoder code.
