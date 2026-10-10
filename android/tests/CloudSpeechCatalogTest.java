package ai.muse.passport;
import java.util.Arrays;

public final class CloudSpeechCatalogTest {
    static void require(boolean condition){if(!condition)throw new AssertionError();}
    public static void main(String[] args) {
        String model=CloudSpeechCatalog.DEFAULT_MODEL, current=CloudSpeechCatalog.DEFAULT_VOICE;
        String previous=CloudSpeechCatalog.PREVIOUS_DEFAULT_VOICE;
        require(current.equals("ICL_uranus_zh_female_keainvsheng_tob"));
        require(Arrays.stream(CloudSpeechCatalog.voices(model)).anyMatch(v->v[0].equals("ICL_uranus_zh_female_tiaopigongzhu_tob")));
        for(String[] pair:new String[][]{
            {"ICL_zh_female_keainvsheng_tob","ICL_uranus_zh_female_keainvsheng_tob"},
            {"ICL_zh_female_tiaopigongzhu_tob","ICL_uranus_zh_female_tiaopigongzhu_tob"},
            {"zh_female_santongyongns_saturn_bigtts","zh_female_liuchangnv_uranus_bigtts"},
            {"zh_male_ruyayichen_saturn_bigtts","zh_male_ruyayichen_uranus_bigtts"},
            {"zh_male_dayi_saturn_bigtts","zh_male_dayi_uranus_bigtts"}
        }) {
            require(CloudSpeechCatalog.initialVoice(model,pair[0],false).equals(pair[1]));
            require(CloudSpeechCatalog.initialVoice("seed-custom-concurr",pair[0],true).equals(pair[0]));
        }
        require(CloudSpeechCatalog.initialVoice(model,"",true).equals(current));
        require(CloudSpeechCatalog.initialVoice(model,previous,true).equals(current));
        require(CloudSpeechCatalog.initialVoice(model,previous,false).equals(previous));
        require(CloudSpeechCatalog.initialVoice(model,"S_custom_voice",true).equals("S_custom_voice"));
        require(CloudSpeechCatalog.initialVoice("seed-custom-concurr",previous,true).equals(previous));
        require(CloudSpeechCatalog.initialVoice("seed-tts-1.0","my-voice",true).equals("my-voice"));
        require(CloudSpeechCatalog.voices(model)[0][0].equals(current));
        require(CloudSpeechCatalog.voices("seed-tts-1.0").length==3);
        require(CloudSpeechCatalog.voices("seed-tts-1.0")[0][0].equals("zh_male_lanxiaoyang_mars_bigtts"));
        require(CloudSpeechCatalog.voices("seed-custom-concurr").length==0);
        require(CloudSpeechCatalog.MODELS.length==2);
        require(CloudSpeechFailure.description(CloudSpeechFailure.http(403)).contains("HTTP 403"));
        require(CloudSpeechFailure.description(CloudSpeechFailure.service(45000000)).contains("45000000"));
        require(!CloudSpeechFailure.description(CloudSpeechFailure.service(45000000)).contains("声包"));
        require(CloudSpeechFailure.description(new java.io.IOException("private response must not be shown")).equals("网络请求失败，请检查网络后重试"));
        System.out.println("Cloud catalog: defaults, migration and custom IDs PASS");
    }
}
