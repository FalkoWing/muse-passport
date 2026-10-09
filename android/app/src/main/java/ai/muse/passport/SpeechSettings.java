package ai.muse.passport;
import android.content.*;
import android.security.keystore.*;
import android.util.Base64;
import java.security.*;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;

final class SpeechSettings {
    private static final String ALIAS="MusePassport.TTS";
    private final SharedPreferences prefs;
    boolean cloud,legacy;String appId,resource,voice;
    SpeechSettings(Context context) {
        prefs=context.getSharedPreferences("speech",Context.MODE_PRIVATE);
        cloud=prefs.getBoolean("cloud",false);legacy=prefs.getBoolean("legacy",false);
        appId=prefs.getString("appId","");resource=prefs.getString("resource","seed-tts-2.0");voice=prefs.getString("voice","");
    }
    private SecretKey key() throws Exception {
        KeyStore store=KeyStore.getInstance("AndroidKeyStore");store.load(null);
        if(store.containsAlias(ALIAS))return (SecretKey)store.getKey(ALIAS,null);
        KeyGenerator generator=KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(ALIAS,KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
        return generator.generateKey();
    }
    String secret() throws Exception {
        String encrypted=prefs.getString("secret","");if(encrypted.isEmpty())return "";
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE,key(),new GCMParameterSpec(128,Base64.decode(prefs.getString("iv",""),Base64.NO_WRAP)));
        return new String(cipher.doFinal(Base64.decode(encrypted,Base64.NO_WRAP)),java.nio.charset.StandardCharsets.UTF_8);
    }
    boolean hasSecret(){return !prefs.getString("secret","").isEmpty();}
    void save(String secret) throws Exception {
        SharedPreferences.Editor edit=prefs.edit().putBoolean("cloud",cloud).putBoolean("legacy",legacy)
                .putString("appId",appId.trim()).putString("resource",resource.trim()).putString("voice",voice.trim());
        if(!secret.isEmpty()) {
            Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,key());
            byte[] encrypted=cipher.doFinal(secret.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            edit.putString("iv",Base64.encodeToString(cipher.getIV(),Base64.NO_WRAP)).putString("secret",Base64.encodeToString(encrypted,Base64.NO_WRAP));
        }
        if(!edit.commit())throw new IllegalStateException("Secure save failed");
    }
    void clear() throws Exception {if(!prefs.edit().remove("iv").remove("secret").commit())throw new IllegalStateException("Secure clear failed");}
}
