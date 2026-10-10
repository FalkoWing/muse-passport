package ai.muse.passport;

import android.Manifest;
import android.app.*;
import android.bluetooth.*;
import android.bluetooth.le.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.*;
import android.view.*;
import android.widget.*;
import java.util.*;

/** A device companion: select Passport, connect, then talk on the device. */
@SuppressWarnings("MissingPermission")
public final class MainActivity extends Activity {
    private static final int INK=0xff251d35, MUTED=0xff786c87, PURPLE=0xff7551bf;
    private final Handler tick=new Handler(Looper.getMainLooper());
    private TextView state,deviceName,stateHint,settingsState;
    private Button settings;
    private Button connect,disconnect,choose;
    private TextView speechState,speechSource,localVoiceState;
    private Button downloadVoice,localPreview;
    private BluetoothLeScanner scanner;
    private AlertDialog picker;
    private ArrayAdapter<String> devicesAdapter;
    private TextView scanHint;
    private final LinkedHashMap<String,BluetoothDevice> devices=new LinkedHashMap<>();
    private boolean scanning,connectAfterSelection;
    private final Runnable refresh=new Runnable() { public void run() {
        if (state==null) return;
        state.setText(BridgeService.status);
        stateHint.setText(BridgeService.running ? "保持蓝牙和手机网络开启，锁屏后仍可使用。" : "连接后，在 Passport 上按住 OK 说话。");
        connect.setVisibility(BridgeService.running ? View.GONE : View.VISIBLE);
        disconnect.setVisibility(BridgeService.running ? View.VISIBLE : View.GONE);
        choose.setEnabled(!BridgeService.running);
        settingsState.setText(BridgeService.sdkSettingsStatus);
        settings.setEnabled(BridgeService.sdkSettingsSupported && !BridgeService.sdkSettingsPending);
        speechState.setText(SpeechEngine.status);
        speechState.setVisibility(SpeechEngine.status.isEmpty()?View.GONE:View.VISIBLE);
        speechSource.setText("当前朗读来源："+new SpeechSettings(MainActivity.this).sourceDescription());
        SpeechEngine.SystemVoice available=SpeechEngine.systemVoice;
        localVoiceState.setText(available==SpeechEngine.SystemVoice.READY?"本机中文语音可用，无需下载":
                available==SpeechEngine.SystemVoice.CHECKING?"正在检查本机中文语音…":
                available==SpeechEngine.SystemVoice.MISSING?"缺少中文离线声包，下载后可使用本机 TTS":"系统语音引擎不可用，请检查系统文字转语音设置");
        downloadVoice.setVisibility(available==SpeechEngine.SystemVoice.MISSING || available==SpeechEngine.SystemVoice.UNAVAILABLE?View.VISIBLE:View.GONE);
        localPreview.setEnabled(available==SpeechEngine.SystemVoice.READY);
        String selected=getSharedPreferences("bridge",0).getString("name","");
        deviceName.setText(selected.isEmpty() ? "尚未选择设备" : selected);
        tick.postDelayed(this,500);
    }};
    private int dp(int n) { return Math.round(n*getResources().getDisplayMetrics().density); }
    private TextView text(String value,int size,int color,boolean bold) {
        TextView t=new TextView(this);t.setText(value);t.setTextSize(size);t.setTextColor(color);
        t.setLineSpacing(dp(4),1);if(bold)t.setTypeface(null,Typeface.BOLD);return t;
    }
    private GradientDrawable background(int color,int radius) {
        GradientDrawable d=new GradientDrawable();d.setColor(color);d.setCornerRadius(dp(radius));return d;
    }
    private void add(LinearLayout box,View view,int top) {
        LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,-2);p.topMargin=dp(top);box.addView(view,p);
    }
    private LinearLayout card(LinearLayout box,int top) {
        LinearLayout c=new LinearLayout(this);c.setOrientation(LinearLayout.VERTICAL);c.setPadding(dp(20),dp(20),dp(20),dp(20));
        c.setBackground(background(Color.WHITE,24));add(box,c,top);return c;
    }
    private Button button(String value,boolean primary) {
        Button b=new Button(this);b.setText(value);b.setAllCaps(false);b.setTextSize(16);
        b.setTextColor(primary?Color.WHITE:PURPLE);b.setMinHeight(dp(52));
        b.setBackgroundTintList(android.content.res.ColorStateList.valueOf(primary?PURPLE:0xffeee7f8));return b;
    }
    @Override public void onCreate(Bundle bundle) {
        super.onCreate(bundle);
        if(bundle!=null)connectAfterSelection=bundle.getBoolean("connect_after_selection");
        // Remove obsolete options from earlier versions; the system owns routing.
        getSharedPreferences("bridge",0).edit().remove("socks").remove("port").apply();
        ScrollView scroll=new ScrollView(this);scroll.setFillViewport(true);scroll.setBackgroundColor(0xfff5f2fa);
        LinearLayout box=new LinearLayout(this);box.setOrientation(LinearLayout.VERTICAL);box.setPadding(dp(24),dp(32),dp(24),dp(28));scroll.addView(box);
        scroll.setOnApplyWindowInsetsListener((v,insets)->{
            int top,bottom;
            if(Build.VERSION.SDK_INT>=30){android.graphics.Insets bars=insets.getInsets(WindowInsets.Type.systemBars());top=bars.top;bottom=bars.bottom;}
            else{top=insets.getSystemWindowInsetTop();bottom=insets.getSystemWindowInsetBottom();}
            box.setPadding(dp(24),top+dp(24),dp(24),bottom+dp(24));return insets;
        });
        LinearLayout hero=new LinearLayout(this);hero.setGravity(Gravity.CENTER_VERTICAL);
        ImageView icon=new ImageView(this);icon.setImageResource(R.drawable.ic_passport_mark);icon.setContentDescription(getString(R.string.app_name));
        icon.setPadding(dp(10),dp(10),dp(10),dp(10));icon.setBackground(background(0xff241837,18));hero.addView(icon,new LinearLayout.LayoutParams(dp(60),dp(60)));
        LinearLayout title=new LinearLayout(this);title.setOrientation(LinearLayout.VERTICAL);title.setPadding(dp(16),0,0,0);
        title.addView(text(getString(R.string.app_name),25,INK,true));title.addView(text("把 Muse 装进口袋",14,MUTED,false));hero.addView(title);add(box,hero,0);
        add(box,text("让 Passport 通过蓝牙使用手机网络，随时与 Muse 对话。",16,MUTED,false),24);
        LinearLayout connection=card(box,24);
        add(connection,text("连接状态",13,MUTED,true),0);
        state=text(BridgeService.status,20,INK,true);add(connection,state,12);
        stateHint=text("",14,MUTED,false);add(connection,stateHint,8);
        connect=button("连接 Passport",true);connect.setOnClickListener(v->prepare(true));add(connection,connect,20);
        disconnect=button("断开连接",false);disconnect.setOnClickListener(v->stopService(new Intent(this,BridgeService.class)));add(connection,disconnect,20);
        LinearLayout device=card(box,16);
        add(device,text("你的 Passport",13,MUTED,true),0);deviceName=text("",17,INK,true);add(device,deviceName,10);
        choose=button("选择设备",false);choose.setOnClickListener(v->prepare(false));add(device,choose,14);
        settingsState=text("",14,MUTED,false);add(device,settingsState,14);
        settings=button("设备设置",false);settings.setOnClickListener(v->deviceSettings());add(device,settings,8);
        LinearLayout speech=card(box,16);
        add(speech,text("语音回复",18,INK,true),0);
        add(speech,text("默认使用本机 TTS，将 Muse 的文字回复朗读到 Passport，无需云端账号，也不会为语音合成上传回复文字。",14,MUTED,false),10);
        speechSource=text("",16,INK,true);add(speech,speechSource,12);
        localVoiceState=text("正在检查本机中文语音…",14,MUTED,false);add(speech,localVoiceState,10);
        downloadVoice=button("下载中文声包",false);downloadVoice.setVisibility(View.GONE);downloadVoice.setOnClickListener(v->downloadSystemVoice());add(speech,downloadVoice,8);
        localPreview=button("试听本机语音",false);localPreview.setOnClickListener(v->SpeechEngine.get(this).preview(false));add(speech,localPreview,8);
        Button voice=button("云端模型配置  ›",false);voice.setOnClickListener(v->startActivity(new Intent(this,CloudSpeechActivity.class)));add(speech,voice,16);
        add(speech,text("云端提供更多音色和更丰富的语气表现；需要联网，可能产生服务费用，回复文字会发送给火山引擎。",14,MUTED,false),10);
        add(speech,text("云端未配置或未开启时使用本机 TTS；开播前失败也会回退本机。已开播后失败只停止本条，文字仍可阅读。",14,MUTED,false),10);
        speechState=text(SpeechEngine.status,14,MUTED,false);add(speech,speechState,10);
        add(speech,text("朗读开关和音量在 Passport 菜单中设置。播放中短按 OK 停止，按住 OK 开始新录音。",14,MUTED,false),10);
        LinearLayout guide=card(box,16);
        add(guide,text("开始对话",18,INK,true),0);
        add(guide,text("01  按住 OK 说话，松开发送\n02  短按上下键，阅读转录与回复\n03  长按下键，打开设备设置",15,INK,false),14);
        add(guide,text("首次使用先刷入配套固件，在本应用设备设置中保存 SDK token，再到 Muse App 完成账号与 Wi-Fi 初始化。日常对话使用手机网络。蓝牙配对请输入设备显示的六位数字。",14,MUTED,false),14);
        TextView about=text("社区项目 · 1.0.2\n使用手机当前网络。网络受限时，请确保本应用可以连接 Muse。",12,MUTED,false);about.setGravity(Gravity.CENTER);add(box,about,24);
        setContentView(scroll);
    }
    private void deviceSettings() {
        new AlertDialog.Builder(this).setTitle("设备设置")
                .setMessage((BridgeService.sdkTokenConfigured?"SDK token 已设置。":"尚未设置 SDK token。")
                        +"\n\nSDK token 用于 Muse 开发者设备授权，可在 gadgets.muse.ai 的账号设置中创建。保存或清除后 Passport 会重启，并保留已有账号配对。")
                .setPositiveButton("设置 SDK token",(d,w)->editSdkToken())
                .setNeutralButton("清除 token",(d,w)->new AlertDialog.Builder(this).setTitle("清除 SDK token？")
                        .setMessage("这会移除 Passport 上的 SDK token。后续账号配对或授权续期可能需要重新设置；已有 Muse 账号配对信息会保留。")
                        .setPositiveButton("清除",(dialog,which)->sendSdkSettings("clear",null)).setNegativeButton("取消",null).show())
                .setNegativeButton("关闭",null).show();
    }
    private void downloadSystemVoice() {
        String engine=SpeechEngine.get(this).systemEngine();
        Intent install=new Intent(android.speech.tts.TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA);
        if(engine!=null && !engine.isEmpty())install.setPackage(engine);
        try{startActivity(install);}
        catch(ActivityNotFoundException e){new AlertDialog.Builder(this).setTitle("下载中文声包")
                .setMessage("请在系统设置中搜索“文字转语音”，为当前语音引擎下载中文离线声包。安装完成后返回本应用，会重新检查可用状态。")
                .setPositiveButton("打开系统设置",(d,w)->startActivity(new Intent(android.provider.Settings.ACTION_SETTINGS)))
                .setNegativeButton("关闭",null).show();}
    }
    private void editSdkToken() {
        EditText input=new EditText(this);input.setSingleLine(true);input.setHint("mgst_…");
        input.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD);
        input.setSaveEnabled(false);
        input.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);
        LinearLayout box=new LinearLayout(this);box.setOrientation(LinearLayout.VERTICAL);box.setPadding(dp(24),dp(8),dp(24),dp(8));
        box.addView(text("通过已配对的加密蓝牙连接保存到 Passport。本应用不持久保存或回显 token。",14,MUTED,false));add(box,input,14);
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle("设置 SDK token").setView(box)
                .setPositiveButton("保存到设备",null).setNegativeButton("取消",null).create();
        dialog.setOnDismissListener(d->input.getText().clear());
        dialog.show();dialog.getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v->{
            String token=input.getText().toString().trim();
            if(!token.matches("mgst_[A-Za-z0-9_-]{1,58}")){input.setError("请输入以 mgst_ 开头、最多 63 个字符的 SDK token");return;}
            sendSdkSettings("set",token);input.getText().clear();dialog.dismiss();
        });
    }
    private void sendSdkSettings(String action,String token) {
        if(!BridgeService.sdkSettingsSupported || BridgeService.sdkSettingsPending){Toast.makeText(this,"请先连接 Passport",Toast.LENGTH_SHORT).show();return;}
        Intent request=new Intent(this,BridgeService.class).setAction(BridgeService.ACTION_SDK_SETTINGS).putExtra("sdk_action",action);
        if(token!=null)request.putExtra("sdk_token",token);
        startService(request);
    }
    private void prepare(boolean connectAfter) {
        connectAfterSelection=connectAfter;
        List<String> required=new ArrayList<>();
        if(Build.VERSION.SDK_INT>=31){required.add(Manifest.permission.BLUETOOTH_SCAN);required.add(Manifest.permission.BLUETOOTH_CONNECT);}
        else required.add(Manifest.permission.ACCESS_FINE_LOCATION);
        if(connectAfter && Build.VERSION.SDK_INT>=33)required.add(Manifest.permission.POST_NOTIFICATIONS);
        List<String> missing=new ArrayList<>();for(String p:required)if(checkSelfPermission(p)!=PackageManager.PERMISSION_GRANTED)missing.add(p);
        if(!missing.isEmpty()){requestPermissions(missing.toArray(new String[0]),1);return;}
        continueAction();
    }
    private void continueAction() {
        BluetoothAdapter adapter=((BluetoothManager)getSystemService(BLUETOOTH_SERVICE)).getAdapter();
        if(adapter==null){Toast.makeText(this,"这台手机不支持蓝牙",Toast.LENGTH_LONG).show();return;}
        if(!adapter.isEnabled()){startActivityForResult(new Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE),2);return;}
        if(connectAfterSelection && !getSharedPreferences("bridge",0).getString("device","").isEmpty())startBridge();
        else selectDevice(adapter);
    }
    private void startBridge() {
        Intent service=new Intent(this,BridgeService.class);
        if(Build.VERSION.SDK_INT>=26)startForegroundService(service);else startService(service);
    }
    private void selectDevice(BluetoothAdapter adapter) {
        if(BridgeService.running)return;
        stopScan();devices.clear();
        LinearLayout list=new LinearLayout(this);list.setOrientation(LinearLayout.VERTICAL);list.setPadding(dp(24),dp(8),dp(24),dp(8));
        scanHint=text("正在查找，请保持 Passport 开机…",14,MUTED,false);list.addView(scanHint);
        ListView found=new ListView(this);devicesAdapter=new ArrayAdapter<>(this,android.R.layout.simple_list_item_1,new ArrayList<>());
        found.setAdapter(devicesAdapter);list.addView(found,new LinearLayout.LayoutParams(-1,dp(260)));
        picker=new AlertDialog.Builder(this).setTitle("选择 Passport").setView(list).setNegativeButton("取消",null).create();
        picker.setOnDismissListener(d->{stopScan();picker=null;});
        found.setOnItemClickListener((parent,view,index,id)->{
            BluetoothDevice selected=new ArrayList<>(devices.values()).get(index);
            String label=devicesAdapter.getItem(index);
            getSharedPreferences("bridge",0).edit().putString("device",selected.getAddress()).putString("name",label).apply();
            picker.dismiss();if(connectAfterSelection)startBridge();
        });
        picker.show();scanner=adapter.getBluetoothLeScanner();
        if(scanner==null){scanHint.setText("蓝牙暂不可用，请稍后重试");return;}
        scanning=true;
        scanner.startScan(null,new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(),scanCallback);
        tick.postDelayed(()->{if(scanning){stopScan();scanHint.setText(devices.isEmpty()?"未发现设备，请确认已刷入配套固件，再重新搜索。":"选择与 Passport 屏幕同名的设备。");}},15000);
    }
    private final ScanCallback scanCallback=new ScanCallback(){
        @Override public void onScanResult(int type,ScanResult result){runOnUiThread(()->{
            if(!scanning || result.getScanRecord()==null)return;
            String name=result.getScanRecord().getDeviceName();if(name==null || !name.startsWith("MuseGadget-"))return;
            String address=result.getDevice().getAddress();
            if(!devices.containsKey(address)){devices.put(address,result.getDevice());devicesAdapter.add(name);scanHint.setText("选择与 Passport 屏幕同名的设备。");}
        });}
        @Override public void onScanFailed(int code){runOnUiThread(()->{if(scanHint!=null)scanHint.setText("搜索暂不可用，请稍后重试");stopScan();});}
    };
    private void stopScan(){if(scanning && scanner!=null)scanner.stopScan(scanCallback);scanning=false;}
    @Override public void onRequestPermissionsResult(int r,String[] p,int[] results){
        super.onRequestPermissionsResult(r,p,results);if(r!=1)return;
        for(int i=0;i<p.length;i++)if(!p[i].equals(Manifest.permission.POST_NOTIFICATIONS) && results[i]!=PackageManager.PERMISSION_GRANTED){Toast.makeText(this,"需要蓝牙权限才能选择和连接 Passport",Toast.LENGTH_LONG).show();return;}
        continueAction(); // Notification refusal does not block the foreground service.
    }
    @Override protected void onActivityResult(int request,int result,Intent data){super.onActivityResult(request,result,data);if(request==2 && result==RESULT_OK)continueAction();}
    @Override protected void onSaveInstanceState(Bundle out){out.putBoolean("connect_after_selection",connectAfterSelection);super.onSaveInstanceState(out);}
    @Override public void onResume(){super.onResume();SpeechEngine.get(this).checkSystemVoice();tick.post(refresh);}
    @Override public void onPause(){tick.removeCallbacks(refresh);if(picker!=null)picker.dismiss();stopScan();super.onPause();}
}
