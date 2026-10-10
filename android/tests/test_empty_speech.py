"""Run the real speech session methods with synthesis/transport fakes."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
JAVA = Path(os.environ.get('JAVA_HOME', '/usr')) / 'bin'
JAVAC = str(JAVA / 'javac') if (JAVA / 'javac').exists() else shutil.which('javac')


@unittest.skipUnless(JAVAC, 'Java toolchain unavailable')
class EmptySpeechTest(unittest.TestCase):
    def test_empty_replies_end_without_synthesis_or_encoder(self):
        source = (ROOT / 'android/app/src/main/java/ai/muse/passport/SpeechEngine.java').read_text()
        run = source[source.index('    private static final class Run'):source.index('    private static final class Capture')]
        methods = source[source.index('    private void send(Run'):source.index('    private short[] systemPCM')]
        harness = r'''
package ai.muse.passport;
import java.util.*;
import java.util.concurrent.*;
import java.io.*;
class EmptySpeechHarness {
    static String status;
    static int encoded, synthesized;
    volatile Run current;
    interface Sender {boolean send(byte[] body);}
    static class SpeechSettings {boolean cloud;boolean useCloud(){return cloud;}}
    static class OpusEncoder {
        OpusEncoder(){encoded++;}
        byte[] packet(short[] samples){return new byte[120];}
        void close(){}
    }
''' + run + methods + r'''
    interface PCMConsumer {void accept(short[] samples) throws Exception;}
    short[] systemPCM(String text){synthesized++;return new short[960];}
    void cloudPCM(String text,SpeechSettings settings,PCMConsumer consumer) throws Exception {
        synthesized++;consumer.accept(new short[960]);
    }
    static void require(boolean value){if(!value)throw new AssertionError(status);}
    public static void main(String[] args) throws Exception {
        for(boolean cloud:List.of(false,true))for(String text:List.of("```\ncode\n```","![图](https://x/a_(b))","⏰👨‍👩‍👧‍👦","！！！", " \n ")) {
            var engine=new EmptySpeechHarness();var settings=new SpeechSettings();settings.cloud=cloud;
            var writes=new ArrayList<byte[]>();encoded=0;synthesized=0;status="";
            engine.current=new Run(7,8,body->{writes.add(body);engine.current.feedback(0,2);return true;});
            engine.speak(engine.current,text,settings);
            require(encoded==0 && synthesized==0 && writes.size()==1);
            require(Arrays.equals(writes.get(0),SpeechWire.packet(7,0,1,new byte[0])));
            require(status.equals("无可朗读内容，文字仍可阅读") && engine.current==null);
        }
        for(int state:List.of(2,3,5)) {
            var engine=new EmptySpeechHarness();encoded=0;synthesized=0;
            engine.current=new Run(7,0,body->{
                // Feedback arrives later: the session must stay alive while draining.
                new Thread(()->{try{Thread.sleep(30);}catch(InterruptedException e){throw new AssertionError(e);}
                    require(engine.current!=null);engine.current.feedback(0,state);}).start();return true;
            });
            engine.speak(engine.current,"⏰",new SpeechSettings());
            require(encoded==0 && synthesized==0 && engine.current==null);
            require(status.equals(state==2?"无可朗读内容，文字仍可阅读":state==3?"朗读已停止":"朗读失败，文字仍可阅读"));
        }
        var engine=new EmptySpeechHarness();var writes=new ArrayList<byte[]>();
        engine.current=new Run(7,8,body->{writes.add(body);return false;});
        engine.speak(engine.current,"⏰",new SpeechSettings());
        require(status.equals("朗读失败，文字仍可阅读") && writes.size()==2 && writes.get(1)[8]==4);
        engine.current=new Run(7,8,body->{throw new AssertionError("cancelled sent audio");});engine.current.cancelled=true;
        engine.speak(engine.current,"⏰",new SpeechSettings());require(status.equals("朗读已停止"));
        // Nonempty replies still synthesize, encode and flush the normal tail.
        writes.clear();encoded=0;synthesized=0;
        engine.current=new Run(7,8,body->{writes.add(body);if(body[8]==1)engine.current.feedback(0,2);return true;});
        engine.speak(engine.current,"正文。",new SpeechSettings());
        require(encoded==1 && synthesized==1 && writes.size()==3 && writes.get(0)[8]==0 && writes.get(1)[8]==0 && writes.get(2)[8]==1);
        require(status.equals("朗读完成"));
        // PCM from two sentences shares a frame; its first sample owns the origin.
        writes.clear();engine.current=new Run(8,8,body->{writes.add(body);return true;});engine.current.follow=true;
        var encoder=engine.new Encoder(engine.current);
        engine.current.origin=17;encoder.feed(new short[400]);require(writes.isEmpty());
        engine.current.origin=99;encoder.feed(new short[1000]);encoder.finish();encoder.close();
        require(writes.size()==3 && writes.get(0)[8]==5 && SpeechWire.u32(writes.get(0),9)==17);
        require(SpeechWire.u32(writes.get(1),9)==99 && SpeechWire.u32(writes.get(2),9)==99);
        System.out.println("Android real speak: empty end, delayed drain, stop, failure and normal audio passed");
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            java = Path(directory) / 'EmptySpeechHarness.java'
            java.write_text(harness)
            subprocess.run([JAVAC, '-d', directory, str(java), str(ROOT / 'android/app/src/main/java/ai/muse/passport/SpeechWire.java')],
                           check=True, capture_output=True, text=True, timeout=30)
            result = subprocess.run([str(Path(JAVAC).with_name('java')), '-cp', directory, 'ai.muse.passport.EmptySpeechHarness'],
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
