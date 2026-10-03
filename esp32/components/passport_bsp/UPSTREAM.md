# FoloToy AI Passport BSP

Imported from https://gitee.com/FoloToy/ai-passport at `0b9e4c81ee4421c0bac39ca3561d65a8285acd4a`.
The files in `src/` and `include/` retain FoloToy's MIT license (see LICENSE).

Local integration changes: ESP-IDF 6 dependency constraints, smaller display
buffer and LVGL task priority for concurrent Wi-Fi, release button events,
and a borrowed codec handle for Muse's fixed-format audio lifecycle.
The vendor hardware test menu and application are not imported.

First-device checks found that the vendor's fixed single-slot format mask
configured mono DMA for Muse's stereo buffers. Multi-channel opens now use
the full channel mask. Audio DMA uses four 160-frame blocks in each direction;
the LCD uses one eight-line partial buffer to reserve RAM for provisioning.

The audio recovery harness and its stubs in `../../tests/passport_audio*`
are also imported from the same MIT-licensed vendor revision, with regression
checks added for stereo DMA and the borrowed codec reopening.

The Chinese Muse menu was reproduced causing an LVGL task stack protection
fault in `lv_event_send` / `event_send_core` with the previous 4 KiB stack.
The display task now has 6 KiB; verify its measured watermark during menu,
status, battery and paging transitions while BLE remains connected.
