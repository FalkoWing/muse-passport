#pragma once
#include <stdbool.h>

// The Muse refresh API currently accepts a token fitting its 64-byte buffer.
#define SDK_TOKEN_MAX 63
void sdk_token_store_init(const char *build_default);
const char *sdk_token_store_get(void);
bool sdk_token_store_valid(const char *token);
// Durable write, including an empty override on clear. Applied after reboot so
// pairing and refresh retain stable, immutable pointers throughout one boot.
bool sdk_token_store_save(const char *token);
