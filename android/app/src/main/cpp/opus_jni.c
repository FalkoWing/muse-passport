#include <jni.h>
#include <stdint.h>
#include "passport_opus.h"
JNIEXPORT jlong JNICALL Java_ai_muse_passport_OpusEncoder_create(JNIEnv *env,jclass cls) {
    (void)env; (void)cls; return (jlong)(intptr_t)passport_opus_encoder_create();
}
JNIEXPORT jbyteArray JNICALL Java_ai_muse_passport_OpusEncoder_encode(JNIEnv *env,jclass cls,jlong handle,jshortArray input) {
    (void)cls;
    if (!handle || (*env)->GetArrayLength(env,input)!=960) return NULL;
    int16_t pcm[960]; uint8_t packet[120];
    (*env)->GetShortArrayRegion(env,input,0,960,pcm);
    if ((*env)->ExceptionCheck(env) || passport_opus_encode((void *)(intptr_t)handle,pcm,packet)!=120) return NULL;
    jbyteArray result=(*env)->NewByteArray(env,120);
    if (result) (*env)->SetByteArrayRegion(env,result,0,120,(const jbyte *)packet);
    return result;
}
JNIEXPORT void JNICALL Java_ai_muse_passport_OpusEncoder_destroy(JNIEnv *env,jclass cls,jlong handle) {
    (void)env; (void)cls; passport_opus_encoder_destroy((void *)(intptr_t)handle);
}
