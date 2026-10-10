import ai.muse.passport.SpeechWire;
import ai.muse.passport.BridgeProtocol;
import java.util.*;
public class SpeechTest {
    static void require(boolean value,String why){if(!value)throw new AssertionError(why);}
    static void require(boolean value){if(!value)throw new AssertionError();}
    static String unescape(String value) {
        StringBuilder out=new StringBuilder();
        for(int i=0;i<value.length();i++) {
            char c=value.charAt(i);
            if(c=='\\') {c=value.charAt(++i);c=switch(c){case 'n'->'\n';case 'r'->'\r';case 't'->'\t';case '\\'->'\\';default->throw new AssertionError("fixture escape");};}
            out.append(c);
        }
        return out.toString();
    }
    public static void main(String[] args) throws Exception {
        String original="正文。\n```\n重复正文。\n```\n**正文**。[正文](https://正文) 1️⃣。";
        var mapped=SpeechWire.cleanSpeechMapped(original);
        int[] raw=original.codePoints().toArray(),points=mapped.text.codePoints().toArray();
        require(points.length==mapped.origins.length,"mapped lengths");
        for(int i=0;i<points.length;i++) {
            require(points[i]==raw[mapped.origins[i]],"source character changed");
            if(i>0)require(mapped.origins[i]>mapped.origins[i-1],"source order");
        }
        var segments=SpeechWire.speechSegments(original);
        require(segments.get(0).origin==0,"first source");
        require(segments.get(1).origin==original.codePointCount(0,original.indexOf("**正文**")+2),"code skipped before repeated text");

        var fixture=java.nio.file.Path.of("ios/PassportBridge/Tests/PassportBridgeTests/Fixtures/speech_cleaning.tsv");
        if(!java.nio.file.Files.exists(fixture))fixture=java.nio.file.Path.of("..").resolve(fixture);
        for(String row:java.nio.file.Files.readAllLines(fixture)) {
            if(row.startsWith("#"))continue;
            String[] fields=row.split("\t",-1);require(fields.length==3);
            String actual=SpeechWire.cleanSpeech(unescape(fields[1])),expected=unescape(fields[2]);
            if(!actual.equals(expected))throw new AssertionError(fields[0]+": expected ["+expected+"], got ["+actual+"]");
        }
        byte[] wire=SpeechWire.packet(0x12345678L,0xAABBCCDDL,4,new byte[0]);
        require(SpeechWire.u32(wire,0)==0x12345678L && SpeechWire.u32(wire,4)==0xAABBCCDDL && wire[8]==4);
        var packets=BridgeProtocol.packets(14,0,1,SpeechWire.packet(7,1,0,new byte[120]),247);
        require(packets.size()==1 && packets.get(0).length==137);
        String text="第一句。第二句！"+"中".repeat(180)+"🙂";
        var parts=SpeechWire.sentences(text);require(String.join("",parts).equals(text));
        require(parts.stream().allMatch(s->s.codePointCount(0,s.length())<=80));
        for(String punctuation:List.of("！！！","!!!","？！","……。","；；")) {
            String before="前面正常"+punctuation,after="后面也应该继续。";
            require(SpeechWire.sentences(before+after).equals(List.of(before,after)));
        }
        require(SpeechWire.sentences("!!! ？！ *** ### —— …… \n").isEmpty());
        for(int length:List.of(79,80,159,160)) {
            var bounded=SpeechWire.sentences("中".repeat(length)+"！！！后面继续。");
            require(bounded.stream().allMatch(s->s.codePointCount(0,s.length())<=80));
            require(bounded.stream().allMatch(s->s.codePoints().anyMatch(Character::isLetterOrDigit)));
            require(String.join("",bounded).endsWith("后面继续。"));
            require(String.join("",bounded).codePoints().filter(cp->cp=='中').count()==length);
        }
        require(SpeechWire.sentences("123！！！继续。").equals(List.of("123！！！","继续。")));
        require(SpeechWire.cleanSpeech("**加粗**和*斜体*").equals("加粗和斜体"));
        require(SpeechWire.cleanSpeech("# 标题\n正文").equals("标题\n正文"));
        require(SpeechWire.cleanSpeech("- 项目一\n- 项目二").equals("项目一\n项目二"));
        require(SpeechWire.cleanSpeech("1. 第一\n2. 第二").equals("第一\n第二"));
        require(SpeechWire.cleanSpeech("> 引用").equals("引用"));
        require(SpeechWire.cleanSpeech("见[文档](https://example.com/a?b=1)详情").equals("见文档详情"));
        require(SpeechWire.cleanSpeech("![图](https://x/y.png)说明").equals("说明"));
        require(SpeechWire.cleanSpeech("用 `idf.py build` 编译").equals("用 idf.py build 编译"));
        require(SpeechWire.cleanSpeech("开始\n```\nprint(1)\n```\n结束").equals("开始\n\n结束"));
        require(SpeechWire.cleanSpeech("太好了😀明天见").equals("太好了明天见"));
        require(SpeechWire.cleanSpeech("👨‍👩‍👧一家三口").equals("一家三口"));
        require(SpeechWire.cleanSpeech("---\n***\n___").equals("\n\n"));
        require(SpeechWire.cleanSpeech("esp_idf_v5 编译").equals("esp_idf_v5 编译"));
        require(SpeechWire.cleanSpeech("# 配置\n运行 `idf.py` **构建**，见[文档](http://x.cn)😀").equals("配置\n运行 idf.py 构建，见文档"));
        require(SpeechWire.sentences(SpeechWire.cleanSpeech("😀😀😀")).isEmpty());
        require(SpeechWire.sentences(SpeechWire.cleanSpeech("**重要**！！！后面继续。")).equals(List.of("重要！！！","后面继续。")));
        require(SpeechWire.sentences("！！！正文继续。").equals(List.of("正文继续。")));
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
