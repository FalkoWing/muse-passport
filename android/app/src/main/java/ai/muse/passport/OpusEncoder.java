package ai.muse.passport;
final class OpusEncoder implements AutoCloseable {
    static { System.loadLibrary("passport_speech"); }
    private long handle=create();
    OpusEncoder() { if(handle==0)throw new IllegalStateException("Opus init"); }
    byte[] packet(short[] pcm) {
        byte[] result=encode(handle,pcm);
        if(result==null)throw new IllegalStateException("Opus encode");
        return result;
    }
    public void close() { destroy(handle);handle=0; }
    private static native long create();
    private static native byte[] encode(long handle,short[] pcm);
    private static native void destroy(long handle);
}
