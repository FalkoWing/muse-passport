package ai.muse.passport;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.List;

/** Version 1: type, flags, request ID, message sequence, byte offset (all u16 LE). */
public final class BridgeProtocol {
    public static final int HELLO=1, CREDENTIALS=2, READY=3, OPEN=4, DATA=5, CANCEL=6,
            RESPONSE=7, ACK=8, TOKENS=9, ERROR=10, TEXT=11, SDK_SETTINGS=12,
            SPEECH_REQUEST=13, SPEECH_DATA=14, SPEECH_STATUS=15;
    public static final int MAX_MESSAGE=8192, HEADER=8;
    public record Message(int type, int id, int sequence, byte[] body) {}
    private ByteArrayOutputStream buffer;
    private int type, id, sequence;
    public static int u16(byte[] b, int o) { return (b[o]&255) | ((b[o+1]&255)<<8); }
    public static void put16(byte[] b, int o, int n) { b[o]=(byte)n; b[o+1]=(byte)(n>>8); }
    public synchronized void reset() { buffer=null; }
    public synchronized Message feed(byte[] packet) {
        if (packet.length<HEADER || (packet[1]&~3)!=0) throw new IllegalArgumentException("BLE frame header");
        int t=packet[0]&255, flags=packet[1]&255, i=u16(packet,2), s=u16(packet,4), o=u16(packet,6);
        if ((flags&1)!=0) {
            if (buffer!=null || o!=0) { buffer=null; throw new IllegalArgumentException("BLE frame overlap"); }
            buffer=new ByteArrayOutputStream(); type=t; id=i; sequence=s;
        }
        if (buffer==null || type!=t || id!=i || sequence!=s || buffer.size()!=o || o+packet.length-HEADER>MAX_MESSAGE) {
            buffer=null; throw new IllegalArgumentException("BLE frame order/size");
        }
        buffer.write(packet,HEADER,packet.length-HEADER);
        if ((flags&2)==0) return null;
        Message result=new Message(type,id,sequence,buffer.toByteArray()); buffer=null; return result;
    }
    public static List<byte[]> packets(int type, int id, int sequence, byte[] body, int mtu) {
        if (body.length>MAX_MESSAGE || mtu<23) throw new IllegalArgumentException("BLE message size");
        int size=Math.min(mtu-3,244)-HEADER;
        List<byte[]> result=new ArrayList<>();
        for (int offset=0;;) {
            int n=Math.min(size,body.length-offset);
            byte[] b=new byte[HEADER+n]; b[0]=(byte)type;
            b[1]=(byte)((offset==0?1:0) | (offset+n==body.length?2:0));
            put16(b,2,id); put16(b,4,sequence); put16(b,6,offset);
            System.arraycopy(body,offset,b,HEADER,n); result.add(b); offset+=n;
            if (offset==body.length) return result;
        }
    }
}
