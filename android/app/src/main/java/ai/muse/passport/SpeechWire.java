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
        for(int cp:text.codePoints().toArray()) {
            part.appendCodePoint(cp);count++;
            if("。！？!?；;\n".indexOf(cp)>=0 || count>=80) {
                if(!part.toString().trim().isEmpty())result.add(part.toString());part.setLength(0);count=0;
            }
        }
        if(!part.toString().trim().isEmpty())result.add(part.toString());return result;
    }
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
