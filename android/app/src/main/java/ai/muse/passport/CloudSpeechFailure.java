package ai.muse.passport;

import java.io.IOException;

/** Only safe categories/codes are shown, never raw responses or credentials. */
final class CloudSpeechFailure extends IOException {
    CloudSpeechFailure(String reason){super(reason);}
    static CloudSpeechFailure http(int status) {
        return new CloudSpeechFailure("HTTP "+status+"，请检查服务权限、密钥与额度");
    }
    static CloudSpeechFailure service(int code) {
        return new CloudSpeechFailure("服务错误码 "+code+"，请检查模型、音色权限与额度");
    }
    static String description(Exception error) {
        if(error instanceof CloudSpeechFailure)return error.getMessage();
        if(error instanceof IOException)return "网络请求失败，请检查网络后重试";
        return "合成或播放未完成，请重试";
    }
}
