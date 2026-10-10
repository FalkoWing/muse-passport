package ai.muse.passport;

final class CloudSpeechCatalog {
    static final String DEFAULT_MODEL="seed-tts-2.0", CUSTOM="__custom__";
    static final String DEFAULT_VOICE="ICL_uranus_zh_female_keainvsheng_tob";
    static final String PREVIOUS_DEFAULT_VOICE="zh_female_vv_uranus_bigtts";
    // Current TTS catalog: https://docs.volcengine.com/docs/DoubaoVoice/Tonelist-1
    static final String[][] MODELS={
        {DEFAULT_MODEL,"豆包语音合成 2.0"},
        {"seed-tts-1.0","豆包语音合成 1.0"}
    };
    private static final String[][] V2={
        {DEFAULT_VOICE,"可爱女生 · 默认"},
        {"ICL_uranus_zh_female_tiaopigongzhu_tob","调皮公主 · 女声"},
        {PREVIOUS_DEFAULT_VOICE,"Vivi 2.0 · 女声"},
        {"zh_female_liuchangnv_uranus_bigtts","流畅女声 · 女声"},
        {"zh_male_ruyayichen_uranus_bigtts","儒雅逸辰 · 男声"},
        {"zh_male_dayi_uranus_bigtts","大壹 · 男声"}
    };
    private static final String[][] V1={
        {"zh_male_lanxiaoyang_mars_bigtts","懒音绵宝 · 男声"},
        {"zh_male_dongmanhaimian_mars_bigtts","亮嗓萌仔 · 男声"},
        {"zh_female_tianmeitaozi_mars_bigtts","甜美桃子 · 女声"}
    };
    static String[][] voices(String resource) {
        return DEFAULT_MODEL.equals(resource)?V2:"seed-tts-1.0".equals(resource)?V1:new String[0][];
    }
    static String initialVoice(String resource,String saved,boolean migrateDefault) {
        if(DEFAULT_MODEL.equals(resource) && (saved.isEmpty() || (migrateDefault && PREVIOUS_DEFAULT_VOICE.equals(saved))))return DEFAULT_VOICE;
        if(DEFAULT_MODEL.equals(resource))return switch(saved) {
            case "ICL_zh_female_keainvsheng_tob" -> DEFAULT_VOICE;
            case "ICL_zh_female_tiaopigongzhu_tob" -> "ICL_uranus_zh_female_tiaopigongzhu_tob";
            case "zh_female_santongyongns_saturn_bigtts" -> "zh_female_liuchangnv_uranus_bigtts";
            case "zh_male_ruyayichen_saturn_bigtts" -> "zh_male_ruyayichen_uranus_bigtts";
            case "zh_male_dayi_saturn_bigtts" -> "zh_male_dayi_uranus_bigtts";
            default -> saved;
        };
        return saved;
    }
}
