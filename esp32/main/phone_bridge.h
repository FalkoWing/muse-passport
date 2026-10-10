#pragma once
#include "muse_link.h"
struct ble_gatt_svc_def;
struct ble_gap_event;
void phone_bridge_init(void);
const struct ble_gatt_svc_def *phone_bridge_services(void);
int phone_bridge_gap_event(struct ble_gap_event *event);
bool phone_bridge_ready(void);
int64_t phone_bridge_open(const char *verb, const char *path, const char *const *headers,
                          bool end_body, muse_link_req_cb cb, void *ctx);
bool phone_bridge_send(int64_t id, const void *data, size_t len, bool end_body, int wait_ms);
void phone_bridge_cancel(int64_t id);
bool phone_bridge_speech_ready(void);
bool phone_bridge_speech_follow_ready(void);
bool phone_bridge_speech_send(uint8_t type, const void *data, size_t len);
