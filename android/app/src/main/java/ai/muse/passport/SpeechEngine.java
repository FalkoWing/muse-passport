package ai.muse.passport;
import android.content.Context;
import android.media.*;
import android.os.Bundle;
import android.speech.tts.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import okhttp3.*;
import org.json.JSONObject;

/** Synthesis and bounded, device-credit-driven raw Opus delivery. */
final class SpeechEngine {
    static volatile String status="默认使用手机内置中文语音";
    private static SpeechEngine instance;
    static synchronized SpeechEngine get(Context c){if(instance==null)instance=new SpeechEngine(c.getApplicationContext());return instance;}
    interface Sender {boolean send(byte[] body);}
    private final Context context;
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private final CompletableFuture<Integer> initialized=new CompletableFuture<>();
    private final TextToSpeech tts;
    private final OkHttpClient http=new OkHttpClient.Builder().connectTimeout(15,TimeUnit.SECONDS).readTimeout(20,TimeUnit.SECONDS).build();
    private volatile Run current;
    private volatile Capture capture;
    private volatile Call call;
    private volatile boolean previewing;
    private volatile boolean previewCancelled;
    private volatile AudioTrack preview;
    private static final class Run {
        final long id;final Sender sender;long frame,limit;int state;volatile boolean cancelled;
        Run(long id,long limit,Sender sender){this.id=id;this.limit=Math.min(8,limit);this.sender=sender;}
        synchronized void check() throws InterruptedException {if(cancelled || state==3 || state==5)throw new InterruptedException();}
        synchronized void feedback(long limit,int state){this.limit=limit;this.state=state;notifyAll();}
    }
    private static final class Capture {
        final String id=UUID.randomUUID().toString();final CompletableFuture<short[]> result=new CompletableFuture<>();
        final ByteArrayOutputStream bytes=new ByteArrayOutputStream();int rate,channels,encoding;
    }
    private SpeechEngine(Context context) {
        this.context=context;tts=new TextToSpeech(context,initialized::complete);
        tts.setOnUtteranceProgressListener(new UtteranceProgressListener() {
            private Capture find(String id){Capture c=capture;return c!=null && c.id.equals(id)?c:null;}
            @Override public void onStart(String id) {}
            @Override public void onBeginSynthesis(String id,int rate,int format,int channels){Capture c=find(id);if(c!=null){c.rate=rate;c.encoding=format;c.channels=channels;}}
            @Override public void onAudioAvailable(String id,byte[] bytes) {
                Capture c=find(id);if(c==null || c.result.isDone())return;
                synchronized(c){if(c.bytes.size()+bytes.length>2_000_000){c.result.completeExceptionally(new IOException("PCM limit"));return;}c.bytes.write(bytes,0,bytes.length);}
            }
            @Override public void onDone(String id) {
                Capture c=find(id);if(c==null)return;
                try{synchronized(c){c.result.complete(SpeechWire.pcm(c.bytes.toByteArray(),c.rate,c.channels,c.encoding));}}
                catch(Exception e){c.result.completeExceptionally(new IOException("Chinese voice output unavailable"));}
            }
            @Override public void onError(String id){Capture c=find(id);if(c!=null)c.result.completeExceptionally(new IOException("System TTS failed"));}
            @Override public void onError(String id,int code){onError(id);}
            @Override public void onStop(String id,boolean interrupted){Capture c=find(id);if(c!=null)c.result.completeExceptionally(new InterruptedException());}
        });
    }
    void request(long id,String text,long limit,Sender sender) {
        stop();Run run=new Run(id,limit,sender);current=run;
        worker.execute(()->speak(run,text,new SpeechSettings(context)));
    }
    void feedback(byte[] bytes) {
        if(bytes.length!=9 || (bytes[8]&255)>5)return;
        Run run=current;if(run==null || run.id!=SpeechWire.u32(bytes,0))return;
        int state=bytes[8]&255;run.feedback(SpeechWire.u32(bytes,4),state);
        if(state==3 || state==5){run.cancelled=true;cancelSynthesis();}
    }
    private void cancelSynthesis() {
        Capture c=capture;if(c!=null)c.result.completeExceptionally(new InterruptedException());
        Call pending=call;if(pending!=null)pending.cancel();tts.stop();
    }
    void stop() {
        Run run=current;current=null;
        if(run!=null){run.cancelled=true;synchronized(run){run.notifyAll();}}
        previewCancelled=true;cancelSynthesis();AudioTrack track=preview;
        if(track!=null){try{track.stop();}catch(IllegalStateException ignored){/* Static PCM may not have been written yet. */}}
    }
    private void send(Run run,int kind,byte[] opus) throws Exception {
        run.check();if(current!=run || !run.sender.send(SpeechWire.packet(run.id,run.frame,kind,opus)))throw new IOException("BLE disconnected");
    }
    private void packet(Run run,byte[] opus) throws Exception {
        synchronized(run){long deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(15);
            while(run.frame>=run.limit){run.check();if(System.nanoTime()>deadline)throw new TimeoutException();run.wait(100);}}
        send(run,0,opus);run.frame++;
    }
    private final class Encoder implements AutoCloseable {
        final OpusEncoder opus=new OpusEncoder();final Run run;final short[] pending=new short[960];int count;
        Encoder(Run run){this.run=run;}
        void feed(short[] samples) throws Exception {for(short s:samples){pending[count++]=s;if(count==960){packet(run,opus.packet(pending));count=0;}}}
        void finish() throws Exception {if(count>0){Arrays.fill(pending,count,960,(short)0);packet(run,opus.packet(pending));count=0;}Arrays.fill(pending,(short)0);packet(run,opus.packet(pending));}
        public void close(){opus.close();}
    }
    private void speak(Run run,String text,SpeechSettings settings) {
        try {
            if(text.isBlank())throw new IOException("Missing completed reply");
            boolean cloud=settings.cloud;List<String> sentences=SpeechWire.sentences(text);int index=0;
            Encoder encoder=new Encoder(run);
            try {
                while(index<sentences.size()) {
                    run.check();
                    try {
                        if(cloud)cloudPCM(sentences.get(index),settings,encoder::feed);else encoder.feed(systemPCM(sentences.get(index)));
                        index++;
                    }catch(Exception e){
                        run.check();if(!cloud)throw e;
                        run.feedback(0,0);send(run,2,new byte[0]);
                        synchronized(run){long deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(5);
                            while(run.state!=4){run.check();if(System.nanoTime()>deadline)throw new TimeoutException();run.wait(100);}}
                        encoder.close();run.frame=0;run.feedback(0,0);send(run,3,new byte[0]);
                        encoder=new Encoder(run);cloud=false;index=0;status="云端未开播，已切换手机内置语音";
                    }
                }
                encoder.finish();send(run,1,new byte[0]);
                synchronized(run){long deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(15);
                    while(run.state<2){run.check();if(System.nanoTime()>deadline)throw new TimeoutException();run.wait(100);}}
                status=run.state==2?"朗读完成":"朗读已停止";
            }finally{encoder.close();}
        }catch(Exception e){
            status=run.state==5?"朗读失败，文字仍可阅读":run.cancelled?"朗读已停止":"朗读失败，文字仍可阅读";
            if(current==run && !run.cancelled && run.state<2)run.sender.send(SpeechWire.packet(run.id,run.frame,4,new byte[0]));
        }finally{if(current==run)current=null;}
    }
    private short[] systemPCM(String text) throws Exception {
        if(initialized.get(10,TimeUnit.SECONDS)!=TextToSpeech.SUCCESS)throw new IOException("System voice init");
        Set<Voice> voices=tts.getVoices();
        Voice voice=voices==null?null:voices.stream().filter(v->"zh".equals(v.getLocale().getLanguage())
                && Arrays.asList("CN","TW","SG","").contains(v.getLocale().getCountry()) && !v.isNetworkConnectionRequired())
                .sorted(Comparator.comparing(v->!"CN".equals(v.getLocale().getCountry()))).findFirst().orElse(null);
        if(voice==null || tts.setVoice(voice)!=TextToSpeech.SUCCESS)throw new IOException("Install Chinese offline voice");
        Capture c=new Capture();capture=c;File file=File.createTempFile("speech-",".wav",context.getCacheDir());
        try {
            if(tts.synthesizeToFile(text,new Bundle(),file,c.id)!=TextToSpeech.SUCCESS)throw new IOException("System voice synthesis");
            short[] samples=c.result.get(25,TimeUnit.SECONDS);if(samples.length==0)throw new IOException("Empty system voice");return samples;
        }finally{if(capture==c)capture=null;tts.stop();if(!file.delete())file.deleteOnExit();}
    }
    private interface PCMConsumer {void accept(short[] samples) throws Exception;}
    private void cloudPCM(String text,SpeechSettings settings,PCMConsumer consume) throws Exception {
        String secret=settings.secret();
        if(secret.isEmpty() || settings.resource.isBlank() || settings.voice.isBlank() || (settings.legacy && settings.appId.isBlank()))throw new IOException("Cloud configuration");
        JSONObject params=new JSONObject().put("text",text).put("speaker",settings.voice).put("audio_params",new JSONObject().put("format","pcm").put("sample_rate",16000));
        String body=new JSONObject().put("user",new JSONObject().put("uid","muse-passport")).put("req_params",params).toString();
        Request.Builder request=new Request.Builder().url("https://openspeech.bytedance.com/api/v3/tts/unidirectional")
                .header("X-Api-Resource-Id",settings.resource).header("X-Api-Request-Id",UUID.randomUUID().toString())
                .post(RequestBody.create(body,MediaType.get("application/json; charset=utf-8")));
        if(settings.legacy)request.header("X-Api-App-Id",settings.appId).header("X-Api-Access-Key",secret);else request.header("X-Api-Key",secret);
        Call requestCall=http.newCall(request.build());call=requestCall;
        try(Response response=requestCall.execute()) {
            if(response.code()!=200 || response.body()==null)throw new IOException("Cloud HTTP");
            SpeechWire.JsonObjects parser=new SpeechWire.JsonObjects();boolean completed=false;int total=0,carry=-1;
            Reader reader=new InputStreamReader(response.body().byteStream(),StandardCharsets.UTF_8);int next;
            while((next=reader.read())!=-1){
                if(current!=null)current.check();
                if(completed && !Character.isWhitespace((char)next))throw new IOException("Data after completion");
                String record=parser.feed((char)next);if(record==null)continue;
                JSONObject object=new JSONObject(record);int code=object.getInt("code");
                if(code==20000000)completed=true;else if(code!=0)throw new IOException("Cloud service");
                String encoded=object.optString("data","");if(encoded.isEmpty() || "null".equals(encoded))continue;
                byte[] data=android.util.Base64.decode(encoded,android.util.Base64.DEFAULT);total+=data.length;
                if(total>2_000_000)throw new IOException("Cloud PCM limit");
                byte[] bytes;if(carry>=0){bytes=new byte[data.length+1];bytes[0]=(byte)carry;System.arraycopy(data,0,bytes,1,data.length);}else bytes=data;
                int pairs=bytes.length/2;short[] samples=new short[pairs];for(int i=0;i<pairs;i++)samples[i]=(short)((bytes[i*2]&255)|((bytes[i*2+1]&255)<<8));
                carry=bytes.length%2==0?-1:bytes[bytes.length-1]&255;consume.accept(samples);
            }
            parser.finish();if(!completed || carry>=0 || total==0)throw new IOException("Incomplete cloud PCM");
        }finally{if(call==requestCall)call=null;}
    }
    void preview() {
        if(current!=null || previewing){status="请先停止设备朗读";return;}previewing=true;previewCancelled=false;
        worker.execute(()->{
            AudioTrack track=null;
            try {
                if(previewCancelled)throw new InterruptedException();
                String phrase="你好，我是 Muse。这是一段语音试听。";SpeechSettings settings=new SpeechSettings(context);ByteArrayOutputStream output=new ByteArrayOutputStream();
                PCMConsumer collect=samples->{for(short v:samples){output.write(v&255);output.write((v>>8)&255);}};
                if(settings.cloud)cloudPCM(phrase,settings,collect);else collect.accept(systemPCM(phrase));byte[] pcm=output.toByteArray();
                if(previewCancelled)throw new InterruptedException();
                track=new AudioTrack.Builder().setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                        .setAudioFormat(new AudioFormat.Builder().setSampleRate(16000).setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                        .setTransferMode(AudioTrack.MODE_STATIC).setBufferSizeInBytes(pcm.length).build();
                preview=track;track.write(pcm,0,pcm.length);
                if(previewCancelled)throw new InterruptedException();
                track.play();status="正在手机上试听";
                long deadline=System.nanoTime()+TimeUnit.MILLISECONDS.toNanos(pcm.length*1000L/32000);
                while(!previewCancelled && System.nanoTime()<deadline)Thread.sleep(50);
                status=previewCancelled?"试听已停止":"试听完成";
            }catch(Exception e){status=previewCancelled?"试听已停止":"试听失败，请检查中文声包或云端配置";}
            finally{preview=null;if(track!=null)track.release();previewing=false;}
        });
    }
}
