import ai.muse.passport.BridgeProtocol;
import java.util.Random;

/** Prints BLE framing vectors from the Android implementation as JSON. */
public class FrameVectors {
    static String hex(byte[] bytes) {
        StringBuilder out = new StringBuilder();
        for (byte b : bytes) out.append(String.format("%02x", b));
        return out.toString();
    }
    public static void main(String[] args) {
        StringBuilder out = new StringBuilder("[");
        int[][] cases = {{23, 0}, {23, 1}, {23, 12}, {23, 13}, {23, 100}, {185, 0}, {185, 174}, {185, 175}, {185, 600},
                         {247, 236}, {247, 237}, {247, 8192}, {517, 236}, {517, 237}, {517, 600}};
        for (int[] c : cases) {
            byte[] body = new byte[c[1]];
            new Random(20 + c[0] + c[1]).nextBytes(body);
            if (out.length() > 1) out.append(",");
            out.append("{\"type\":5,\"id\":42,\"sequence\":65535,\"mtu\":").append(c[0])
               .append(",\"body\":\"").append(hex(body)).append("\",\"packets\":[");
            boolean first = true;
            for (byte[] packet : BridgeProtocol.packets(5, 42, 65535, body, c[0])) {
                if (!first) out.append(",");
                first = false;
                out.append("\"").append(hex(packet)).append("\"");
            }
            out.append("]}");
        }
        System.out.println(out.append("]"));
    }
}
