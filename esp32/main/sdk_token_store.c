#include "sdk_token_store.h"
#include "config_store.h"
#include <string.h>

static char current[SDK_TOKEN_MAX + 1];
bool sdk_token_store_valid(const char *token) {
    if (!token || strncmp(token,"mgst_",5) || !token[5]) return false;
    size_t n=strlen(token);
    if (n>SDK_TOKEN_MAX) return false;
    for (size_t i=5;i<n;i++) {
        unsigned char c=token[i];
        if (!((c>='a' && c<='z') || (c>='A' && c<='Z') ||
              (c>='0' && c<='9') || c=='_' || c=='-')) return false;
    }
    return true;
}
void sdk_token_store_init(const char *build_default) {
    memset(current,0,sizeof(current));
    config_key_lookup_t exists=config_key_lookup("sdk_token");
    if (exists==CONFIG_KEY_FOUND) {
        // Empty is an explicit clear; errors or invalid stored values fail closed.
        if (!config_get_str("sdk_token",current,sizeof(current)) ||
            (current[0] && !sdk_token_store_valid(current))) memset(current,0,sizeof(current));
    } else if (exists==CONFIG_KEY_NOT_FOUND && sdk_token_store_valid(build_default)) {
        memcpy(current,build_default,strlen(build_default)+1);
    }
}
const char *sdk_token_store_get(void) { return current[0]?current:NULL; }
bool sdk_token_store_save(const char *token) {
    if (!token || (token[0] && !sdk_token_store_valid(token))) return false;
    if (!config_set_str("sdk_token",token)) return false;
    char readback[SDK_TOKEN_MAX+1]={0};
    bool ok=config_get_str("sdk_token",readback,sizeof(readback)) && !strcmp(token,readback);
    memset(readback,0,sizeof(readback));
    return ok;
}
