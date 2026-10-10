"""Exercise real system TTS connection recovery with an engine restart fake."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from test_empty_speech import JAVAC, ROOT


@unittest.skipUnless(JAVAC, 'Java toolchain unavailable')
class SystemTtsTest(unittest.TestCase):
    def test_engine_restart_is_not_a_missing_language_pack(self):
        source = (ROOT / 'android/app/src/main/java/ai/muse/passport/SpeechEngine.java').read_text()
        methods = source[source.index('    private SpeechEngine(Context'):source.index('    void request(')]
        # Include the actual PCM entry point: device speech and preview share it.
        pcm = source[source.index('    private short[] systemPCM'):source.index('    private interface PCMConsumer')]
        harness = r'''
package ai.muse.passport;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;
class Context {File getCacheDir(){return new File(System.getProperty("java.io.tmpdir"));}}
class Bundle {}
abstract class UtteranceProgressListener {
    public abstract void onStart(String id);
    public abstract void onDone(String id);
    public abstract void onError(String id);
    public void onError(String id,int code){}
    public void onStop(String id,boolean interrupted){}
    public void onBeginSynthesis(String id,int rate,int encoding,int channels){}
    public void onAudioAvailable(String id,byte[] bytes){}
}
class Voice {
    final boolean network,missing;
    Voice(boolean network,boolean missing){this.network=network;this.missing=missing;}
    Locale getLocale(){return Locale.SIMPLIFIED_CHINESE;}
    boolean isNetworkConnectionRequired(){return network;}
    Set<String> getFeatures(){return missing?Set.of("notInstalled"):Set.of();}
}
class TextToSpeech {
    static final int SUCCESS=0;
    static class Engine {static final String KEY_FEATURE_NOT_INSTALLED="notInstalled";}
    static Set<Voice> available=Set.of(new Voice(false,false));
    static int created,closed;
    static boolean failConnection;
    boolean connected=true;
    UtteranceProgressListener listener;
    TextToSpeech(Context c,java.util.function.Consumer<Integer> ready){created++;ready.accept(failConnection?-1:SUCCESS);}
    void setOnUtteranceProgressListener(UtteranceProgressListener l){listener=l;}
    Set<Voice> getVoices(){return connected&&!failConnection?available:null;}
    int setVoice(Voice voice){return connected?SUCCESS:-1;}
    String getDefaultEngine(){return "test.engine";}
    void shutdown(){closed++;connected=false;}
    void stop(){}
    int synthesizeToFile(String text,Bundle params,File file,String id){
        if(!connected)return -1;
        listener.onBeginSynthesis(id,16000,2,1);
        listener.onAudioAvailable(id,new byte[]{1,0,2,0});listener.onDone(id);return SUCCESS;
    }
}
class SpeechEngine {
    enum SystemVoice {CHECKING,READY,MISSING,UNAVAILABLE}
    static volatile SystemVoice systemVoice=SystemVoice.CHECKING;
    final ExecutorService worker=Executors.newSingleThreadExecutor();
    CompletableFuture<Integer> initialized=new CompletableFuture<>();
    TextToSpeech tts; Context context; Capture capture;
    static class Capture {
        final String id="test"; final CompletableFuture<short[]> result=new CompletableFuture<>();
        final ByteArrayOutputStream bytes=new ByteArrayOutputStream();int rate,channels,encoding;
    }
''' + methods + pcm + r'''
    void awaitCheck() throws Exception {checkSystemVoice();worker.submit(()->{}).get(2,TimeUnit.SECONDS);}
    static void require(boolean condition,String message){if(!condition)throw new AssertionError(message);}
    public static void main(String[] args) throws Exception {
        var engine=new SpeechEngine(new Context());
        try {
            engine.awaitCheck();require(systemVoice==SystemVoice.READY,"initial offline voice unavailable");
            engine.tts.connected=false;engine.awaitCheck();
            require(systemVoice==SystemVoice.READY,"engine restart reported "+systemVoice+" despite installed Chinese voice");
            require(TextToSpeech.created==2&&TextToSpeech.closed==1,"must replace broken connection once");
            engine.tts.connected=false;
            require(Arrays.equals(engine.systemPCM("正文。"),new short[]{1,2}),"PCM path did not recover");
            require(TextToSpeech.created==3,"PCM did not replace broken connection");
            TextToSpeech.available=Set.of(new Voice(true,false),new Voice(false,true));engine.awaitCheck();
            require(systemVoice==SystemVoice.MISSING,"network/uninstalled voice selected as offline");
            require(TextToSpeech.created==3,"missing voice data must not cause rebind loop");
            TextToSpeech.failConnection=true;engine.awaitCheck();
            require(systemVoice==SystemVoice.UNAVAILABLE,"connection failure mislabeled missing data");
            require(TextToSpeech.created==4,"failed connection must retry only once");
            TextToSpeech.failConnection=false;TextToSpeech.available=Set.of(new Voice(false,false));engine.awaitCheck();
            require(systemVoice==SystemVoice.READY,"cannot retry after failed initialization");
            System.out.println("Real system TTS: restart, PCM recovery, missing packs and bounded retry passed");
        } finally {engine.worker.shutdownNow();}
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            java = Path(directory) / 'SpeechEngine.java'
            java.write_text(harness)
            compiled = subprocess.run([JAVAC, '-d', directory, str(java), str(ROOT / 'android/app/src/main/java/ai/muse/passport/SpeechWire.java')],
                                      capture_output=True, text=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(Path(JAVAC).with_name('java')), '-cp', directory, 'ai.muse.passport.SpeechEngine'],
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
