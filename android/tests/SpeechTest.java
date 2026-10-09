import ai.muse.passport.SpeechWire;
import ai.muse.passport.BridgeProtocol;
import java.util.*;
public class SpeechTest {
    static void require(boolean value){if(!value)throw new AssertionError();}
    public static void main(String[] args){
        byte[] wire=SpeechWire.packet(0x12345678L,0xAABBCCDDL,4,new byte[0]);
        require(SpeechWire.u32(wire,0)==0x12345678L && SpeechWire.u32(wire,4)==0xAABBCCDDL && wire[8]==4);
        var packets=BridgeProtocol.packets(14,0,1,SpeechWire.packet(7,1,0,new byte[120]),247);
        require(packets.size()==1 && packets.get(0).length==137);
        String text="第一句。第二句！"+"中".repeat(180)+"🙂";
        var parts=SpeechWire.sentences(text);require(String.join("",parts).equals(text));
        require(parts.stream().allMatch(s->s.codePointCount(0,s.length())<=80));
        var parser=new SpeechWire.JsonObjects();List<String> rows=new ArrayList<>();
        String input="{\"code\":0,\"message\":\"escaped \\\" }\",\"data\":\"AAAA\"}{\"code\":20000000,\"data\":null}";
        for(char c:input.toCharArray()){String row=parser.feed(c);if(row!=null)rows.add(row);}
        parser.finish();require(rows.size()==2 && rows.get(1).contains("20000000"));
        parser=new SpeechWire.JsonObjects();parser.feed('{');
        try{parser.finish();throw new AssertionError("truncated accepted");}catch(IllegalArgumentException expected){}
        byte[] pcm=new byte[48000*2*2];
        for(int i=0;i<pcm.length;i+=4){pcm[i]=pcm[i+2]=0;pcm[i+1]=pcm[i+3]=32;}
        short[] mono=SpeechWire.pcm(pcm,48000,2,2);require(mono.length==16000 && mono[100]==8192);
        require(SpeechWire.pcm(new byte[]{(byte)128,(byte)255,0},16000,1,3)[0]==0);
        try{SpeechWire.pcm(new byte[3],16000,1,2);throw new AssertionError("misaligned accepted");}catch(IllegalArgumentException expected){}
        System.out.println("Speech: packet budget, sessions, sentences, JSON chunk boundaries and PCM formats passed");
    }
}
