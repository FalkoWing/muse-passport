#include "sdk_token_store.h"
#include "config_store.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static char saved[128];
static bool present, fail_write, fail_read, fail_lookup;
bool config_get_str(const char *key,char *out,size_t size) {
    assert(!strcmp(key,"sdk_token"));
    if (!present || fail_read || strlen(saved)>=size) return false;
    memcpy(out,saved,strlen(saved)+1);return true;
}
bool config_set_str(const char *key,const char *value) {
    assert(!strcmp(key,"sdk_token"));
    if (fail_write) return false;
    strcpy(saved,value);present=true;return true;
}
config_key_lookup_t config_key_lookup(const char *key) {
    assert(!strcmp(key,"sdk_token"));
    return fail_lookup?CONFIG_KEY_LOOKUP_ERROR:present?CONFIG_KEY_FOUND:CONFIG_KEY_NOT_FOUND;
}
int main(void) {
    const char *build="mgst_build_default";
    sdk_token_store_init(build);assert(!strcmp(sdk_token_store_get(),build));
    assert(!sdk_token_store_save("not_a_token"));assert(!present);
    assert(!sdk_token_store_save("mgst_"));assert(!sdk_token_store_save("mgst_has space"));
    assert(!sdk_token_store_save("mgst_中文"));
    char boundary[65];memset(boundary,'a',64);memcpy(boundary,"mgst_",5);boundary[64]=0;
    assert(!sdk_token_store_valid(boundary));boundary[63]=0;assert(sdk_token_store_valid(boundary));
    assert(sdk_token_store_save("mgst_device_token"));
    assert(!strcmp(sdk_token_store_get(),build)); // Pairing pointer immutable until restart.
    sdk_token_store_init(build);assert(!strcmp(sdk_token_store_get(),"mgst_device_token"));
    fail_write=true;assert(!sdk_token_store_save("mgst_replacement"));fail_write=false;
    sdk_token_store_init(build);assert(!strcmp(sdk_token_store_get(),"mgst_device_token"));
    assert(sdk_token_store_save(""));assert(present);sdk_token_store_init(build);
    assert(sdk_token_store_get()==NULL); // Clear overrides compiled default across reboot.
    assert(sdk_token_store_save("mgst_new"));fail_read=true;
    sdk_token_store_init(build);assert(sdk_token_store_get()==NULL);
    assert(!sdk_token_store_save("mgst_unconfirmed"));fail_read=false;
    fail_lookup=true;sdk_token_store_init(build);assert(sdk_token_store_get()==NULL);fail_lookup=false;
    strcpy(saved,"bad value");sdk_token_store_init(build);assert(sdk_token_store_get()==NULL);
    present=false;sdk_token_store_init("");assert(sdk_token_store_get()==NULL);
    puts("SDK token persistence, validation, failed writes and clear overrides passed");
}
