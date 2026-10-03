package ai.muse.passport;

import android.app.*;
import android.bluetooth.*;
import android.bluetooth.le.*;
import android.content.*;
import android.os.*;
import com.chaquo.python.*;
import java.util.*;
import java.util.concurrent.*;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

@SuppressWarnings("MissingPermission")
public final class BridgeService extends Service {
    public static final String ACTION_SDK_SETTINGS="ai.muse.passport.SDK_SETTINGS";
    public static volatile boolean sdkSettingsSupported, sdkTokenConfigured, sdkSettingsPending;
    public static volatile String sdkSettingsStatus="连接 Passport 后可设置 SDK token";
    private int settingsRequest;
    public static final String ACTION_STOP="ai.muse.passport.STOP";
    private static final UUID SERVICE=UUID.fromString("4d757365-0010-4000-8000-6a6f6c6c7900");
    private static final UUID RX=UUID.fromString("4d757365-0011-4000-8000-6a6f6c6c7900");
    private static final UUID TX=UUID.fromString("4d757365-0012-4000-8000-6a6f6c6c7900");
    private static final UUID CCC=UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");
    public static volatile String status="尚未连接";
    public static volatile boolean running;
    private HandlerThread thread;
    private Handler handler;
    private final ExecutorService python=Executors.newSingleThreadExecutor();
    private BluetoothAdapter adapter;
    private BluetoothGatt gatt;
    private BluetoothGattCharacteristic rx;
    private BluetoothLeScanner scanner;
    private PyObject backend;
    private Network network;
    private final BridgeProtocol protocol=new BridgeProtocol();
    private final ArrayDeque<Write> writes=new ArrayDeque<>();
    private boolean busy, scanning, stopping, subscribed;
    private int mtu=23, sequence=1, failures;
    private long epoch;
    private record Write(byte[] packet, CountDownLatch complete, java.util.concurrent.atomic.AtomicBoolean ok) {}
    @Override public void onCreate() {
        super.onCreate();
        thread=new HandlerThread("PassportBLE"); thread.start(); handler=new Handler(thread.getLooper());
        adapter=((BluetoothManager)getSystemService(BLUETOOTH_SERVICE)).getAdapter();
        registerBondReceiver();
        NotificationManager nm=getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel("bridge","Passport 连接",NotificationManager.IMPORTANCE_LOW));
    }
    private Notification notification() {
        PendingIntent open=PendingIntent.getActivity(this,0,new Intent(this,MainActivity.class),PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_UPDATE_CURRENT);
        PendingIntent stop=PendingIntent.getService(this,1,new Intent(this,BridgeService.class).setAction(ACTION_STOP),PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(this,"bridge").setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(getString(R.string.app_name)).setContentText(status).setContentIntent(open)
                .addAction(new Notification.Action.Builder(null,"断开",stop).build()).setOngoing(true).build();
    }
    public void setStatus(String text) {
        status=text;
        if (running) getSystemService(NotificationManager.class).notify(1,notification());
    }
    @Override public int onStartCommand(Intent intent,int flags,int startId) {
        if (intent!=null && ACTION_STOP.equals(intent.getAction())) { stopSelf(); return START_NOT_STICKY; }
        if (intent!=null && ACTION_SDK_SETTINGS.equals(intent.getAction())) {
            String action=intent.getStringExtra("sdk_action");
            String token=intent.getStringExtra("sdk_token");
            intent.removeExtra("sdk_token");
            handler.post(() -> updateSdkSettings(action,token));
            return START_NOT_STICKY;
        }
        if (!running) {
            running=true; stopping=false; status="正在查找 Passport…";
            startForeground(1,notification()); handler.post(this::scan);
        }
        return START_NOT_STICKY;
    }
    private final ScanCallback scanCallback=new ScanCallback() {
        @Override public void onScanResult(int type,ScanResult result) { handler.post(() -> {
            if (!scanning || gatt!=null) return;
            BluetoothDevice d=result.getDevice();
            String preferred=getSharedPreferences("bridge",0).getString("device","");
            if (!preferred.isEmpty() && !preferred.equals(d.getAddress())) return;
            getSharedPreferences("bridge",0).edit().putString("device",d.getAddress()).apply();
            stopScan(); connect(d);
        }); }
        @Override public void onScanFailed(int error) { handler.post(() -> retry("蓝牙扫描失败 ("+error+")")); }
    };
    private void scan() {
        if (stopping || gatt!=null) return;
        if (getSharedPreferences("bridge",0).getString("device","").isEmpty()) {
            setStatus("请在应用中选择 Passport"); stopSelf(); return;
        }
        if (adapter==null || !adapter.isEnabled()) { retry("请打开手机蓝牙"); return; }
        scanner=adapter.getBluetoothLeScanner();
        if (scanner==null) { retry("蓝牙暂不可用"); return; }
        setStatus("正在查找 Passport；请保持设备开机"); scanning=true;
        // Name filter: the bridge service is discovered after connection because
        // firmware advertising already contains the Muse setup service UUID.
        String preferred=getSharedPreferences("bridge",0).getString("device","");
        ScanFilter.Builder filter=new ScanFilter.Builder();
        if (!preferred.isEmpty()) filter.setDeviceAddress(preferred);
        else filter.setDeviceName(getSharedPreferences("bridge",0).getString("name",""));
        scanner.startScan(Collections.singletonList(filter.build()),new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(),scanCallback);
        handler.postDelayed(() -> { if (scanning) { stopScan(); retry("还没找到 Passport，继续查找…"); } },15000);
    }
    private void stopScan() { if (scanning && scanner!=null) scanner.stopScan(scanCallback); scanning=false; }
    private void connect(BluetoothDevice device) {
        epoch++; mtu=23; rx=null; subscribed=false; protocol.reset();
        setStatus("正在连接 Passport 蓝牙…");
        gatt=device.connectGatt(this,false,gattCallback,BluetoothDevice.TRANSPORT_LE);
        long generation=epoch;
        handler.postDelayed(() -> { if (epoch==generation && !subscribed) retry("蓝牙配对超时，请确认手机配对弹窗"); },60000);
    }
    private final BluetoothGattCallback gattCallback=new BluetoothGattCallback() {
        @Override public void onConnectionStateChange(BluetoothGatt g,int code,int state) { handler.post(() -> {
            if (g!=gatt || stopping) return;
            if (code!=0 || state==BluetoothProfile.STATE_DISCONNECTED) { retry("Passport 已断开，正在重连…"); return; }
            if (state==BluetoothProfile.STATE_CONNECTED) {
                g.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH);
                if (!g.requestMtu(247)) g.discoverServices();
            }
        }); }
        @Override public void onMtuChanged(BluetoothGatt g,int value,int code) { handler.post(() -> {
            if (g!=gatt) return; if (code==0) mtu=value; g.discoverServices();
        }); }
        @Override public void onServicesDiscovered(BluetoothGatt g,int code) { handler.post(() -> {
            if (g!=gatt) return;
            BluetoothGattService s=g.getService(SERVICE);
            if (code!=0 || s==null) { retry("Passport 需要刷入蓝牙桥接固件"); return; }
            rx=s.getCharacteristic(RX);
            if (rx==null || s.getCharacteristic(TX)==null) { retry("Passport 蓝牙协议不完整"); return; }
            if (g.getDevice().getBondState()!=BluetoothDevice.BOND_BONDED) {
                setStatus("请在手机上配对，并输入 Passport 屏幕上的六位数字");
                if (!g.getDevice().createBond()) retry("无法开始蓝牙配对");
            } else subscribe();
        }); }
        @Override public void onDescriptorWrite(BluetoothGatt g,BluetoothGattDescriptor d,int code) { handler.post(() -> {
            if (g!=gatt) return;
            if (code!=0) { retry("蓝牙认证失败，请重新配对"); return; }
            subscribed=true; failures=0;
            setStatus("蓝牙已连接，正在获取 Muse 配对信息…");
            Network newNetwork=new Network(); network=newNetwork;
            long generation=epoch;
            python.execute(() -> {
                try {
                    PyObject b=Python.getInstance().getModule("passport_bridge").callAttr("Bridge",BridgeService.this,newNetwork);
                    handler.post(() -> {
                        if (generation!=epoch || stopping) { python.execute(() -> b.callAttr("stop")); newNetwork.close(); return; }
                        backend=b; enqueue(BridgeProtocol.HELLO,0,new byte[0],null,null);
                    });
                } catch (Exception e) { handler.post(() -> retry("Muse 运行模块启动失败")); }
            });
        }); }
        @Override public void onCharacteristicChanged(BluetoothGatt g,BluetoothGattCharacteristic c,byte[] value) { onPacket(g,value.clone()); }
        @Override public void onCharacteristicChanged(BluetoothGatt g,BluetoothGattCharacteristic c) {
            if (Build.VERSION.SDK_INT<33) onPacket(g,c.getValue().clone());
        }
        @Override public void onCharacteristicWrite(BluetoothGatt g,BluetoothGattCharacteristic c,int code) { handler.post(() -> {
            if (g!=gatt || writes.isEmpty()) return;
            Write w=writes.removeFirst(); busy=false;
            if (code!=0) { if (w.complete!=null) { w.ok.set(false); w.complete.countDown(); } retry("蓝牙发送失败"); return; }
            if (w.complete!=null) w.complete.countDown(); pump();
        }); }
    };
    private void onPacket(BluetoothGatt g,byte[] packet) { handler.post(() -> {
        if (g!=gatt || !subscribed) return;
        try {
            BridgeProtocol.Message m=protocol.feed(packet);
            if (m==null) return;
            enqueue(BridgeProtocol.ACK,m.sequence(),new byte[0],null,null);
            if (m.type()==BridgeProtocol.CREDENTIALS) {
                JSONObject info=new JSONObject(new String(m.body(),StandardCharsets.UTF_8));
                sdkTokenConfigured=info.optBoolean("sdk_token_configured",false);
                sdkSettingsSupported=info.optBoolean("sdk_settings",false);
                if (!sdkSettingsPending) sdkSettingsStatus=sdkSettingsSupported
                        ? (sdkTokenConfigured?"SDK token 已设置":"尚未设置 SDK token")
                        : "请升级 Passport 固件以设置 SDK token";
            }
            if (m.type()==BridgeProtocol.SDK_SETTINGS) {
                if (m.id()!=settingsRequest || !sdkSettingsPending) return;
                JSONObject reply=new JSONObject(new String(m.body(),StandardCharsets.UTF_8));
                sdkSettingsPending=false;
                if (!reply.optBoolean("ok")) {
                    sdkSettingsStatus="保存失败，请检查 token 格式并重试";
                } else {
                    sdkTokenConfigured=reply.optBoolean("configured");
                    sdkSettingsStatus=sdkTokenConfigured?"已保存到 Passport，设备正在重启…":"已清除，设备正在重启…";
                }
                return;
            }
            PyObject b=backend;
            if (b!=null) python.execute(() -> b.callAttr("feed",m.type(),m.id(),m.body()));
        } catch (Exception e) { retry("蓝牙数据顺序错误，请重连"); }
    }); }
    private void updateSdkSettings(String action,String token) {
        if (!running || !subscribed || !sdkSettingsSupported || sdkSettingsPending) {
            sdkSettingsStatus="请先连接支持设备设置的 Passport"; return;
        }
        if (!"clear".equals(action) && (!"set".equals(action) || token==null || !token.matches("mgst_[A-Za-z0-9_-]{1,58}"))) {
            sdkSettingsStatus="token 应以 mgst_ 开头，最多 63 个字符"; return;
        }
        try {
            JSONObject request=new JSONObject().put("action",action);
            if ("set".equals(action)) request.put("token",token);
            byte[] body=request.toString().getBytes(StandardCharsets.UTF_8);
            int id=settingsRequest=(settingsRequest+1)&65535;
            long generation=epoch;
            sdkSettingsPending=true; sdkSettingsStatus="正在保存到 Passport…";
            enqueue(BridgeProtocol.SDK_SETTINGS,id,body,null,null);
            Arrays.fill(body,(byte)0);
            handler.postDelayed(() -> {
                if (generation==epoch && id==settingsRequest && sdkSettingsPending) {
                    sdkSettingsPending=false;
                    sdkSettingsStatus="未收到保存确认，请重连后检查设置状态";
                }
            },10000);
        } catch (Exception e) {
            sdkSettingsPending=false; sdkSettingsStatus="无法保存，请重新连接后再试";
        }
    }
    private void subscribe() {
        if (gatt==null || rx==null) return;
        BluetoothGattCharacteristic tx=gatt.getService(SERVICE).getCharacteristic(TX);
        if (!gatt.setCharacteristicNotification(tx,true)) { retry("无法启用蓝牙接收"); return; }
        BluetoothGattDescriptor descriptor=tx.getDescriptor(CCC);
        if (descriptor==null) { retry("蓝牙通知描述符缺失"); return; }
        if (Build.VERSION.SDK_INT>=33) {
            if (gatt.writeDescriptor(descriptor,BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)!=BluetoothStatusCodes.SUCCESS) retry("无法启用蓝牙通知");
        } else {
            descriptor.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE);
            if (!gatt.writeDescriptor(descriptor)) retry("无法启用蓝牙通知");
        }
    }
    private final BroadcastReceiver bondReceiver=new BroadcastReceiver() {
        @Override public void onReceive(Context context,Intent intent) { handler.post(() -> {
            BluetoothDevice d=intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
            if (gatt==null || d==null || !d.equals(gatt.getDevice())) return;
            int state=intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE,0);
            if (state==BluetoothDevice.BOND_BONDED) subscribe();
            else if (state==BluetoothDevice.BOND_NONE) retry("配对取消，请在手机上重新配对");
        }); }
    };
    @Override public void onTaskRemoved(Intent root) { /* Keep the user-started connection while screen is locked. */ }
    private void enqueue(int type,int id,byte[] body,CountDownLatch complete,java.util.concurrent.atomic.AtomicBoolean ok) {
        if (gatt==null || rx==null || !subscribed || writes.size()>256) {
            if (complete!=null) { ok.set(false); complete.countDown(); } return;
        }
        List<byte[]> packets=BridgeProtocol.packets(type,id,sequence++ & 65535,body,mtu);
        for (int i=0;i<packets.size();i++) writes.addLast(new Write(packets.get(i),i==packets.size()-1?complete:null,ok));
        pump();
    }
    private void pump() {
        if (busy || writes.isEmpty() || gatt==null) return;
        busy=true; byte[] data=writes.peekFirst().packet;
        boolean accepted;
        if (Build.VERSION.SDK_INT>=33) accepted=gatt.writeCharacteristic(rx,data,BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)==BluetoothStatusCodes.SUCCESS;
        else { rx.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT); rx.setValue(data); accepted=gatt.writeCharacteristic(rx); }
        if (!accepted) { busy=false; retry("蓝牙发送繁忙，正在重连…"); }
    }
    public boolean sendMessage(int type,int id,byte[] body) {
        CountDownLatch done=new CountDownLatch(1);
        java.util.concurrent.atomic.AtomicBoolean ok=new java.util.concurrent.atomic.AtomicBoolean(true);
        handler.post(() -> enqueue(type,id,body,done,ok));
        try { return done.await(30,TimeUnit.SECONDS) && ok.get(); }
        catch (InterruptedException e) { Thread.currentThread().interrupt(); return false; }
    }
    private void clearConnection() {
        epoch++; stopScan(); subscribed=false; rx=null; protocol.reset();
        sdkSettingsSupported=false;
        if (sdkSettingsPending) sdkSettingsStatus="连接已中断，请重连后检查设置状态";
        sdkSettingsPending=false;
        if (gatt!=null) { gatt.disconnect(); gatt.close(); gatt=null; }
        for (Write w:writes) if (w.complete!=null) { w.ok.set(false); w.complete.countDown(); }
        writes.clear(); busy=false;
        PyObject b=backend; backend=null;
        if (b!=null) python.execute(() -> b.callAttr("stop"));
        if (network!=null) { network.close(); network=null; }
    }
    private void retry(String text) {
        clearConnection(); setStatus(text);
        if (!stopping) {
            long generation=epoch;
            handler.postDelayed(() -> { if (!stopping && epoch==generation) scan(); },Math.min(30000,2000L<<Math.min(failures++,4)));
        }
    }
    @Override public void onDestroy() {
        stopping=true; running=false;
        handler.post(() -> { clearConnection(); python.shutdown(); thread.quitSafely(); });
        unregisterReceiver(bondReceiver);
        status="已断开"; stopForeground(STOP_FOREGROUND_REMOVE); super.onDestroy();
    }
    @Override public IBinder onBind(Intent intent) { return null; }
    @Override public void onStart(Intent intent,int startId) { super.onStart(intent,startId); }
    private void registerBondReceiver() {
        IntentFilter f=new IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED);
        if (Build.VERSION.SDK_INT>=33) registerReceiver(bondReceiver,f,Context.RECEIVER_EXPORTED);
        else registerReceiver(bondReceiver,f);
    }
}
