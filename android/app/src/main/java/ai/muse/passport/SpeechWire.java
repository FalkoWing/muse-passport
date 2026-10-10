package ai.muse.passport;
import java.util.*;
/** Pure wire, framing and format helpers, also compiled by host tests. */
public final class SpeechWire {
    public static long u32(byte[] b,int o) {
        long n=0;for(int i=0;i<4;i++)n|=(long)(b[o+i]&255)<<(i*8);return n;
    }
    public static byte[] packet(long session,long frame,int kind,byte[] opus) {
        byte[] out=new byte[9+opus.length];
        for(int i=0;i<4;i++){out[i]=(byte)(session>>(i*8));out[i+4]=(byte)(frame>>(i*8));}
        out[8]=(byte)kind;System.arraycopy(opus,0,out,9,opus.length);return out;
    }
    public static List<String> sentences(String text) {
        List<String> result=new ArrayList<>();StringBuilder part=new StringBuilder();int count=0;
        int[] points=text.codePoints().toArray();
        for(int i=0;i<points.length;i++) {
            int cp=points[i];
            part.appendCodePoint(cp);count++;
            boolean end="。！？!?；;\n".indexOf(cp)>=0;
            boolean nextEnd=i+1<points.length && "。！？!?；;\n".indexOf(points[i+1])>=0;
            if(count>=80 || (end && !nextEnd)) {
                addSentence(result,part);part.setLength(0);count=0;
            }
        }
        addSentence(result,part);return result;
    }
    private static void addSentence(List<String> result,StringBuilder part) {
        // Punctuation and markup alone may yield no cloud audio. Keep the
        // 80-code-point bound even when a punctuation run crosses it.
        String sentence=part.toString();
        if(sentence.codePoints().anyMatch(Character::isLetterOrDigit))result.add(sentence);
    }
    /** Text with one original Unicode-scalar offset per retained scalar. */
    public static final class MappedText {
        public final String text; public final int[] origins;
        MappedText(String text,int[] origins){this.text=text;this.origins=origins;}
        static MappedText original(String text){int n=text.codePointCount(0,text.length());int[] at=new int[n];for(int i=0;i<n;i++)at[i]=i;return new MappedText(text,at);}
        MappedText slice(int from,int to){return new MappedText(SpeechWire.slice(text.codePoints().toArray(),from,to),Arrays.copyOfRange(origins,from,to));}
        MappedText replace(String pattern,int group){
            var matcher=java.util.regex.Pattern.compile(pattern).matcher(text);MappedBuilder out=new MappedBuilder();int at=0;
            while(matcher.find()){
                int start=text.codePointCount(0,matcher.start()),end=text.codePointCount(0,matcher.end());
                out.add(slice(at,start));
                if(group>0)out.add(slice(text.codePointCount(0,matcher.start(group)),text.codePointCount(0,matcher.end(group))));
                at=end;
            }
            out.add(slice(at,origins.length));return out.build();
        }
    }
    private static final class MappedBuilder {
        final StringBuilder text=new StringBuilder();final List<Integer> origins=new ArrayList<>();
        void add(MappedText value){text.append(value.text);for(int origin:value.origins)origins.add(origin);}
        void point(int cp,int origin){text.appendCodePoint(cp);origins.add(origin);}
        MappedText build(){return new MappedText(text.toString(),origins.stream().mapToInt(Integer::intValue).toArray());}
    }
    public static String cleanSpeech(String text) {return cleanSpeechMapped(text).text;}
    /** Same cleaning rules, retaining provenance instead of searching repeated text. */
    public static MappedText cleanSpeechMapped(String text) {
        MappedText original=MappedText.original(text);String[] lines=text.split("\n",-1);
        int[] starts=new int[lines.length];for(int i=1;i<lines.length;i++)starts[i]=starts[i-1]+lines[i-1].codePointCount(0,lines[i-1].length())+1;
        MappedBuilder out=new MappedBuilder();
        for(int i=0;i<lines.length;i++) {
            MappedText line=original.slice(starts[i],starts[i]+lines[i].codePointCount(0,lines[i].length()));int[] fence=fence(line.text);
            if(fence!=null) {
                int end=i+1;while(end<lines.length && !closesFence(lines[end],fence))end++;
                if(end==lines.length){out.add(original.slice(starts[i],original.origins.length));break;}
                i=end;
            } else {
                line=line.replace("^[ \\t]*(-{3,}|\\*{3,}|_{3,})[ \\t]*\\r?$",0);
                for(String pattern:new String[]{"^#{1,6}[ \\t]+","^> ?","^[ \\t]?[-*+][ \\t]+","^\\d{1,3}[.)][ \\t]+"})line=line.replace(pattern,0);
                InlineText inline=inlineSpeech(line,0);out.add(inline.text);
                if(inline.openCode){if(i+1<lines.length)out.add(original.slice(starts[i]+lines[i].codePointCount(0,lines[i].length()),original.origins.length));break;}
            }
            if(i+1<lines.length)out.point('\n',starts[i]+lines[i].codePointCount(0,lines[i].length()));
        }
        return out.build();
    }
    public static final class Segment {
        public final String text; public final int origin;
        Segment(String text,int origin){this.text=text;this.origin=origin;}
    }
    public static List<Segment> speechSegments(String original) {
        MappedText mapped=cleanSpeechMapped(original);List<Segment> result=new ArrayList<>();int at=0;
        // sentences() retains punctuation-only skipped parts; locate by its
        // deterministic boundaries, not by substring search in original text.
        int[] points=mapped.text.codePoints().toArray();int start=0;
        for(int i=0;i<points.length;i++){
            boolean end="。！？!?；;\n".indexOf(points[i])>=0;
            boolean nextEnd=i+1<points.length && "。！？!?；;\n".indexOf(points[i+1])>=0;
            if(i-start+1>=80 || end && !nextEnd || i+1==points.length){
                at=start;while(at<=i && !Character.isLetterOrDigit(points[at]))at++;
                if(at<=i)result.add(new Segment(slice(points,start,i+1),mapped.origins[at]));start=i+1;
            }
        }
        return result;
    }
    private static int[] fence(String line) {
        var match=java.util.regex.Pattern.compile("^ {0,3}(`{3,}|~{3,})(.*)\\r?$").matcher(line);
        if(!match.matches() || (match.group(1).charAt(0)=='`' && match.group(2).contains("`")))return null;
        return new int[]{match.group(1).charAt(0),match.group(1).length()};
    }
    private static boolean closesFence(String line,int[] opening) {
        return line.matches(" {0,3}"+(char)opening[0]+"{"+opening[1]+",}[ \\t]*\\r?");
    }
    private static String slice(int[] p,int from,int to){return new String(p,from,to-from);}
    private static int runEnd(int[] p,int at) {int end=at+1;while(end<p.length && p[end]==p[at])end++;return end;}
    private static int balancedEnd(int[] p,int at,int open,int close) {
        int depth=0;
        for(int i=at;i<p.length;i++) {
            if(p[i]=='\\'){i++;continue;}
            if(p[i]==open)depth++;
            if(p[i]==close){depth--;if(depth==0)return i;}
        }
        return -1;
    }
    private static final class InlineText {
        final MappedText text;final boolean openCode;
        InlineText(MappedText text,boolean openCode){this.text=text;this.openCode=openCode;}
    }
    private static InlineText inlineSpeech(MappedText mapped,int depth) {
        if(depth>=16)return new InlineText(mapped,false); // Bound nested link labels; unknown structures stay literal.
        int[] p=mapped.text.codePoints().toArray();MappedBuilder out=new MappedBuilder(),plain=new MappedBuilder();boolean openCode=false;
        for(int i=0;i<p.length;) {
            int end=i;MappedText literal=null;
            if(p[i]=='\\' && i+1<p.length) {end=i+2;literal=mapped.slice(i,end);}
            else if(p[i]=='`') {
                int start=runEnd(p,i),close=start;
                while(close<p.length) {
                    if(p[close]!='`'){close++;continue;}
                    int next=runEnd(p,close);if(next-close==start-i)break;close=next;
                }
                openCode=close==p.length;
                end=openCode?p.length:close+start-i;
                literal=close==p.length?mapped.slice(i,end):mapped.slice(start,close);
            } else if(p[i]=='[' || (p[i]=='!' && i+1<p.length && p[i+1]=='[')) {
                int label=p[i]=='!'?i+1:i,close=balancedEnd(p,label,'[',']');
                int destination=close>=0 && close+1<p.length && p[close+1]=='('?balancedEnd(p,close+1,'(',')'):-1;
                if(destination>=0) {end=destination+1;literal=p[i]=='!'?mapped.slice(i,i):inlineSpeech(mapped.slice(label+1,close),depth+1).text;}
                else {end=p.length;literal=mapped.slice(i,end);}
            } else if(textAt(p,i,"https://") || textAt(p,i,"http://") || textAt(p,i,"www.")) {
                end=i;while(end<p.length && !Character.isWhitespace(p[end]))end++;
                literal=mapped.slice(i,end);
            }
            if(literal!=null) {out.add(plainSpeech(plain.build()));out.add(literal);plain=new MappedBuilder();i=end;}
            else {plain.point(p[i],mapped.origins[i]);i++;}
        }
        out.add(plainSpeech(plain.build()));return new InlineText(out.build(),openCode);
    }
    private static boolean textAt(int[] p,int at,String text) {
        if(at+text.length()>p.length)return false;
        for(int i=0;i<text.length();i++)if(p[at+i]!=text.charAt(i))return false;return true;
    }
    private static MappedText plainSpeech(MappedText mapped) {
        int[] p=mapped.text.codePoints().toArray();MappedBuilder out=new MappedBuilder();
        for(int i=0;i<p.length;) {
            int cp=p[i],next=i+1;
            if(next<p.length && p[next]==0xFE0F)next++;
            if((cp>='0' && cp<='9' || cp=='#' || cp=='*') && next<p.length && p[next]==0x20E3) {
                if(cp>='0' && cp<='9')out.point(cp,mapped.origins[i]);i=next+1;continue;
            }
            // Text symbols/operators stay unless explicitly presented as emoji.
            boolean operator=cp==0x2716 || cp>=0x2795 && cp<=0x2797 || cp>='0' && cp<='9';
            boolean modified=next<p.length && p[next]>=0x1F3FB && p[next]<=0x1F3FF && inRanges(cp,EMOJI_TEXT_MODIFIER_BASE);
            if(!operator && (inRanges(cp,EMOJI_PRESENTATION) || next>i+1 && inRanges(cp,EMOJI) || modified)) {
                i=emojiEnd(p,i);
                while(i+1<p.length && p[i]==0x200D && inRanges(p[i+1],EMOJI))i=emojiEnd(p,i+1);
            } else {out.point(cp,mapped.origins[i]);i++;}
        }
        mapped=out.build();
        for(String mark:new String[]{"\\*\\*","__","\\*"}) {
            String excluded=mark.equals("__")?"_":"*";
            mapped=mapped.replace("(?<![A-Za-z0-9_*])"+mark+"([^"+excluded+" \\t\\r\\n\\p{P}](?:[^"+excluded+"\\r\\n]*?[^"+excluded+" \\t\\r\\n])?)"+mark+"(?![A-Za-z0-9_*])",1);
        }
        return mapped;
    }
    private static int emojiEnd(int[] p,int at) {
        int i=at+1;
        while(i<p.length && (p[i]==0xFE0E || p[i]==0xFE0F || p[i]>=0x1F3FB && p[i]<=0x1F3FF || p[i]>=0xE0020 && p[i]<=0xE007F))i++;
        return i;
    }
    private static boolean inRanges(int cp,int[][] ranges) {
        for(int[] r:ranges)if(cp>=r[0] && cp<=r[1])return true;return false;
    }
    // Unicode 17 Emoji / Emoji_Presentation, unicode.org/Public/17.0.0/ucd/emoji/emoji-data.txt.
    // Copyright Unicode, Inc. See shared/UNICODE-LICENSE.txt.
    // Emoji_Modifier_Base minus Emoji_Presentation (other bases are already removed).
    private static final int[][] EMOJI_TEXT_MODIFIER_BASE={
        {0x261D,0x261D},{0x26F9,0x26F9},{0x270C,0x270D},
        {0x1F3CB,0x1F3CC},{0x1F574,0x1F575},{0x1F590,0x1F590}};
    private static final int[][] EMOJI={
        {0x23,0x23},{0x2A,0x2A},{0x30,0x39},{0xA9,0xA9},{0xAE,0xAE},
        {0x203C,0x203C},{0x2049,0x2049},{0x2122,0x2122},{0x2139,0x2139},{0x2194,0x2199},
        {0x21A9,0x21AA},{0x231A,0x231B},{0x2328,0x2328},{0x23CF,0x23CF},{0x23E9,0x23F3},
        {0x23F8,0x23FA},{0x24C2,0x24C2},{0x25AA,0x25AB},{0x25B6,0x25B6},{0x25C0,0x25C0},
        {0x25FB,0x25FE},{0x2600,0x2604},{0x260E,0x260E},{0x2611,0x2611},{0x2614,0x2615},
        {0x2618,0x2618},{0x261D,0x261D},{0x2620,0x2620},{0x2622,0x2623},{0x2626,0x2626},
        {0x262A,0x262A},{0x262E,0x262F},{0x2638,0x263A},{0x2640,0x2640},{0x2642,0x2642},
        {0x2648,0x2653},{0x265F,0x2660},{0x2663,0x2663},{0x2665,0x2666},{0x2668,0x2668},
        {0x267B,0x267B},{0x267E,0x267F},{0x2692,0x2697},{0x2699,0x2699},{0x269B,0x269C},
        {0x26A0,0x26A1},{0x26A7,0x26A7},{0x26AA,0x26AB},{0x26B0,0x26B1},{0x26BD,0x26BE},
        {0x26C4,0x26C5},{0x26C8,0x26C8},{0x26CE,0x26CF},{0x26D1,0x26D1},{0x26D3,0x26D4},
        {0x26E9,0x26EA},{0x26F0,0x26F5},{0x26F7,0x26FA},{0x26FD,0x26FD},{0x2702,0x2702},
        {0x2705,0x2705},{0x2708,0x270D},{0x270F,0x270F},{0x2712,0x2712},{0x2714,0x2714},
        {0x2716,0x2716},{0x271D,0x271D},{0x2721,0x2721},{0x2728,0x2728},{0x2733,0x2734},
        {0x2744,0x2744},{0x2747,0x2747},{0x274C,0x274C},{0x274E,0x274E},{0x2753,0x2755},
        {0x2757,0x2757},{0x2763,0x2764},{0x2795,0x2797},{0x27A1,0x27A1},{0x27B0,0x27B0},
        {0x27BF,0x27BF},{0x2934,0x2935},{0x2B05,0x2B07},{0x2B1B,0x2B1C},{0x2B50,0x2B50},
        {0x2B55,0x2B55},{0x3030,0x3030},{0x303D,0x303D},{0x3297,0x3297},{0x3299,0x3299},
        {0x1F004,0x1F004},{0x1F0CF,0x1F0CF},{0x1F170,0x1F171},{0x1F17E,0x1F17F},{0x1F18E,0x1F18E},
        {0x1F191,0x1F19A},{0x1F1E6,0x1F1FF},{0x1F201,0x1F202},{0x1F21A,0x1F21A},{0x1F22F,0x1F22F},
        {0x1F232,0x1F23A},{0x1F250,0x1F251},{0x1F300,0x1F321},{0x1F324,0x1F393},{0x1F396,0x1F397},
        {0x1F399,0x1F39B},{0x1F39E,0x1F3F0},{0x1F3F3,0x1F3F5},{0x1F3F7,0x1F4FD},{0x1F4FF,0x1F53D},
        {0x1F549,0x1F54E},{0x1F550,0x1F567},{0x1F56F,0x1F570},{0x1F573,0x1F57A},{0x1F587,0x1F587},
        {0x1F58A,0x1F58D},{0x1F590,0x1F590},{0x1F595,0x1F596},{0x1F5A4,0x1F5A5},{0x1F5A8,0x1F5A8},
        {0x1F5B1,0x1F5B2},{0x1F5BC,0x1F5BC},{0x1F5C2,0x1F5C4},{0x1F5D1,0x1F5D3},{0x1F5DC,0x1F5DE},
        {0x1F5E1,0x1F5E1},{0x1F5E3,0x1F5E3},{0x1F5E8,0x1F5E8},{0x1F5EF,0x1F5EF},{0x1F5F3,0x1F5F3},
        {0x1F5FA,0x1F64F},{0x1F680,0x1F6C5},{0x1F6CB,0x1F6D2},{0x1F6D5,0x1F6D8},{0x1F6DC,0x1F6E5},
        {0x1F6E9,0x1F6E9},{0x1F6EB,0x1F6EC},{0x1F6F0,0x1F6F0},{0x1F6F3,0x1F6FC},{0x1F7E0,0x1F7EB},
        {0x1F7F0,0x1F7F0},{0x1F90C,0x1F93A},{0x1F93C,0x1F945},{0x1F947,0x1F9FF},{0x1FA70,0x1FA7C},
        {0x1FA80,0x1FA8A},{0x1FA8E,0x1FAC6},{0x1FAC8,0x1FAC8},{0x1FACD,0x1FADC},{0x1FADF,0x1FAEA},
        {0x1FAEF,0x1FAF8},
    };
    private static final int[][] EMOJI_PRESENTATION={
        {0x231A,0x231B},{0x23E9,0x23EC},{0x23F0,0x23F0},{0x23F3,0x23F3},{0x25FD,0x25FE},
        {0x2614,0x2615},{0x2648,0x2653},{0x267F,0x267F},{0x2693,0x2693},{0x26A1,0x26A1},
        {0x26AA,0x26AB},{0x26BD,0x26BE},{0x26C4,0x26C5},{0x26CE,0x26CE},{0x26D4,0x26D4},
        {0x26EA,0x26EA},{0x26F2,0x26F3},{0x26F5,0x26F5},{0x26FA,0x26FA},{0x26FD,0x26FD},
        {0x2705,0x2705},{0x270A,0x270B},{0x2728,0x2728},{0x274C,0x274C},{0x274E,0x274E},
        {0x2753,0x2755},{0x2757,0x2757},{0x2795,0x2797},{0x27B0,0x27B0},{0x27BF,0x27BF},
        {0x2B1B,0x2B1C},{0x2B50,0x2B50},{0x2B55,0x2B55},{0x1F004,0x1F004},{0x1F0CF,0x1F0CF},
        {0x1F18E,0x1F18E},{0x1F191,0x1F19A},{0x1F1E6,0x1F1FF},{0x1F201,0x1F201},{0x1F21A,0x1F21A},
        {0x1F22F,0x1F22F},{0x1F232,0x1F236},{0x1F238,0x1F23A},{0x1F250,0x1F251},{0x1F300,0x1F320},
        {0x1F32D,0x1F335},{0x1F337,0x1F37C},{0x1F37E,0x1F393},{0x1F3A0,0x1F3CA},{0x1F3CF,0x1F3D3},
        {0x1F3E0,0x1F3F0},{0x1F3F4,0x1F3F4},{0x1F3F8,0x1F43E},{0x1F440,0x1F440},{0x1F442,0x1F4FC},
        {0x1F4FF,0x1F53D},{0x1F54B,0x1F54E},{0x1F550,0x1F567},{0x1F57A,0x1F57A},{0x1F595,0x1F596},
        {0x1F5A4,0x1F5A4},{0x1F5FB,0x1F64F},{0x1F680,0x1F6C5},{0x1F6CC,0x1F6CC},{0x1F6D0,0x1F6D2},
        {0x1F6D5,0x1F6D8},{0x1F6DC,0x1F6DF},{0x1F6EB,0x1F6EC},{0x1F6F4,0x1F6FC},{0x1F7E0,0x1F7EB},
        {0x1F7F0,0x1F7F0},{0x1F90C,0x1F93A},{0x1F93C,0x1F945},{0x1F947,0x1F9FF},{0x1FA70,0x1FA7C},
        {0x1FA80,0x1FA8A},{0x1FA8E,0x1FAC6},{0x1FAC8,0x1FAC8},{0x1FACD,0x1FADC},{0x1FADF,0x1FAEA},
        {0x1FAEF,0x1FAF8},
    };
    public static final class JsonObjects {
        private final StringBuilder record=new StringBuilder();
        private int depth;private boolean quoted,escaped;
        public String feed(char c) {
            if(depth==0){if(Character.isWhitespace(c))return null;if(c!='{')throw new IllegalArgumentException("JSON start");}
            record.append(c);if(record.length()>256*1024)throw new IllegalArgumentException("JSON limit");
            if(quoted){if(escaped)escaped=false;else if(c=='\\')escaped=true;else if(c=='"')quoted=false;}
            else if(c=='"')quoted=true;else if(c=='{')depth++;else if(c=='}')depth--;
            if(depth!=0)return null;String result=record.toString();record.setLength(0);return result;
        }
        public void finish(){if(depth!=0 || record.length()!=0)throw new IllegalArgumentException("Truncated JSON");}
    }
    public static short[] pcm(byte[] bytes,int rate,int channels,int encoding) {
        int width=encoding==2?2:encoding==3?1:encoding==4?4:0;
        if(width==0 || rate<8000 || rate>96000 || channels<1 || channels>2 || bytes.length%(width*channels)!=0)
            throw new IllegalArgumentException("PCM format");
        int frames=bytes.length/(width*channels);float[] mono=new float[frames];
        for(int i=0;i<frames;i++)for(int c=0;c<channels;c++) {
            int p=(i*channels+c)*width;float value;
            if(width==1)value=((bytes[p]&255)-128)/128f;
            else if(width==2)value=(short)((bytes[p]&255)|((bytes[p+1]&255)<<8))/32768f;
            else value=Float.intBitsToFloat((int)u32(bytes,p));
            mono[i]+=value/channels;
        }
        short[] out=new short[(int)((long)frames*16000/rate)];
        for(int i=0;i<out.length;i++) {
            double position=(double)i*rate/16000;int at=(int)position;
            double value=mono[at]+(mono[Math.min(at+1,frames-1)]-mono[at])*(position-at);
            out[i]=(short)Math.max(-32768,Math.min(32767,Math.round(value*32768)));
        }
        return out;
    }
}
