import ai.muse.passport.BridgeProtocol;
import java.util.*;
public class ProtocolTest {
    static void require(boolean b) { if (!b) throw new AssertionError(); }
    public static void main(String[] args) {
        for (int mtu:new int[]{23,247,517}) {
            for (int size:new int[]{0,1,12,236,2049,8192}) {
                byte[] data=new byte[size]; new Random(20+size).nextBytes(data);
                BridgeProtocol receiver=new BridgeProtocol(); BridgeProtocol.Message m=null;
                for (byte[] p:BridgeProtocol.packets(5,42,123,data,mtu)) m=receiver.feed(p);
                require(m!=null && m.id()==42 && m.sequence()==123 && Arrays.equals(data,m.body()));
            }
        }
        var packets=BridgeProtocol.packets(5,42,123,new byte[800],247);
        var r=new BridgeProtocol(); r.feed(packets.get(0));
        try { r.feed(packets.get(2)); throw new AssertionError("gap accepted"); }
        catch (IllegalArgumentException expected) {}
        r=new BridgeProtocol(); r.feed(packets.get(0));
        try { r.feed(packets.get(0)); throw new AssertionError("duplicate accepted"); }
        catch (IllegalArgumentException expected) {}
        r=new BridgeProtocol();
        byte[] malformed=packets.get(0).clone(); malformed[6]=1;
        try { r.feed(malformed); throw new AssertionError("offset accepted"); }
        catch (IllegalArgumentException expected) {}
        r=new BridgeProtocol();
        try { r.feed(new byte[7]); throw new AssertionError("short header accepted"); }
        catch (IllegalArgumentException expected) {}
        System.out.println("Protocol: MTU 23/247/517, empty/full frames, gaps, duplicates and invalid headers passed");
    }
}
