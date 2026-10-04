package ai.muse.passport;

import java.io.IOException;
import java.net.ConnectException;
import java.net.SocketTimeoutException;
import java.net.UnknownHostException;
import javax.net.ssl.SSLException;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import okhttp3.*;
import okio.ByteString;
import org.json.JSONObject;

/** Android TLS trust and default system routing (including system VPN). */
public final class Network implements AutoCloseable {
    // Stable, credential-free markers consumed by the Python bridge. Never
    // forward exception messages: they can contain URLs or request headers.
    private static String failureReason(Throwable error) {
        for (Throwable cause=error; cause!=null; cause=cause.getCause()) {
            if (cause instanceof UnknownHostException) return "PASSPORT_NET_DNS";
            if (cause instanceof SocketTimeoutException) return "PASSPORT_NET_TIMEOUT";
            if (cause instanceof SSLException) return "PASSPORT_NET_TLS";
            if (cause instanceof ConnectException) return "PASSPORT_NET_CONNECT";
        }
        return "PASSPORT_NET_IO";
    }
    private final OkHttpClient client;
    public Network() {
        OkHttpClient.Builder builder=new OkHttpClient.Builder()
                .connectTimeout(20,TimeUnit.SECONDS).readTimeout(25,TimeUnit.SECONDS)
                .writeTimeout(25,TimeUnit.SECONDS).pingInterval(20,TimeUnit.SECONDS)
                .followRedirects(false).followSslRedirects(false);
        // Preserve Android default routing and ProxySelector; never bypass VPN.
        client=builder.build();
    }
    private static Request.Builder request(String url, String headers) throws Exception {
        if (!url.startsWith("https://") && !url.startsWith("wss://")) throw new IOException("需要加密的 Muse 地址");
        Request.Builder b=new Request.Builder().url(url);
        JSONObject json=new JSONObject(headers);
        for (java.util.Iterator<String> it=json.keys();it.hasNext();) { String k=it.next(); b.header(k,json.getString(k)); }
        return b;
    }
    public String http(String method,String url,String headers,String body) throws Exception {
        RequestBody data=method.equals("GET")?null:RequestBody.create(body,MediaType.get("application/json"));
        try (Response r=client.newCall(request(url,headers).method(method,data).build()).execute()) {
            if (r.body()==null || r.body().contentLength()>1024*1024) throw new IOException("API 响应过大");
            java.io.ByteArrayOutputStream output=new java.io.ByteArrayOutputStream();
            java.io.InputStream input=r.body().byteStream(); byte[] chunk=new byte[8192]; int n;
            while ((n=input.read(chunk))!=-1) { output.write(chunk,0,n); if (output.size()>1024*1024) throw new IOException("API 响应过大"); }
            byte[] bytes=output.toByteArray();
            if (bytes.length>1024*1024) throw new IOException("API 响应过大");
            return new JSONObject().put("status",r.code()).put("body",new String(bytes,java.nio.charset.StandardCharsets.UTF_8)).toString();
        } catch (IOException error) {
            throw new IOException(failureReason(error));
        }
    }
    public Channel open(String url,String headers) throws Exception {
        Channel c=new Channel(); c.socket=client.newWebSocket(request(url,headers).build(),c);
        if (!c.opened.await(25,TimeUnit.SECONDS)) { c.close(); throw new IOException("PASSPORT_NET_TIMEOUT"); }
        if (c.failure!=null) { c.close(); throw new IOException(c.failure); }
        return c;
    }
    public static final class Channel extends WebSocketListener implements AutoCloseable {
        private final BlockingQueue<byte[]> incoming=new ArrayBlockingQueue<>(64);
        private final CountDownLatch opened=new CountDownLatch(1);
        private final AtomicBoolean closed=new AtomicBoolean();
        private volatile String failure;
        private WebSocket socket;
        @Override public void onOpen(WebSocket ws,Response r) { opened.countDown(); }
        @Override public void onMessage(WebSocket ws,ByteString bytes) {
            if (bytes.size()>1024*1024 || !incoming.offer(bytes.toByteArray())) { failure="Muse 接收队列已满"; close(); }
        }
        @Override public void onMessage(WebSocket ws,String text) { failure="Muse 返回非二进制协议"; close(); }
        @Override public void onFailure(WebSocket ws,Throwable t,Response r) {
            failure=r==null?failureReason(t):"PASSPORT_WS_HTTP_"+r.code(); closed.set(true); opened.countDown();
        }
        @Override public void onClosed(WebSocket ws,int code,String reason) { closed.set(true); opened.countDown(); }
        @Override public void onClosing(WebSocket ws,int code,String reason) { ws.close(code,null); closed.set(true); }
        public byte[] receive() throws Exception {
            byte[] b=incoming.poll(1,TimeUnit.SECONDS);
            if (b!=null) return b;
            if (closed.get()) throw new IOException(failure==null?"Muse 连接结束":failure);
            return null;
        }
        public void send(byte[] data) throws IOException {
            if (closed.get() || socket.queueSize()>1024*1024 || !socket.send(ByteString.of(data))) throw new IOException("Muse 发送连接结束");
        }
        @Override public void close() { closed.set(true); if (socket!=null) socket.cancel(); }
    }
    @Override public void close() { client.dispatcher().executorService().shutdownNow(); client.connectionPool().evictAll(); }
}
