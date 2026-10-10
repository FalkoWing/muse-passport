package ai.muse.passport;

import android.app.Activity;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.*;
import android.text.*;
import android.view.*;
import android.widget.*;
import java.util.*;

/** Cloud configuration is separate from the default system voice on the home page. */
public final class CloudSpeechActivity extends Activity {
    private static final int INK=0xff251d35,MUTED=0xff786c87,PURPLE=0xff7551bf;
    private SpeechSettings options;
    private Switch cloud,legacy;
    private EditText app,secret,customModel,customVoice;
    private Spinner model,voice;
    private LinearLayout fields;
    private TextView hint,accountHint,status;
    private Button preview,clear;
    private String displayedModel;
    private boolean savedLegacy;
    private final List<String> modelIDs=new ArrayList<>(),voiceIDs=new ArrayList<>();
    private final Handler tick=new Handler(Looper.getMainLooper());
    private final Runnable refresh=new Runnable(){public void run(){status.setText(SpeechEngine.status);tick.postDelayed(this,500);}};
    private int dp(int n){return Math.round(n*getResources().getDisplayMetrics().density);}
    private TextView text(String value,int size,int color,boolean bold){
        TextView t=new TextView(this);t.setText(value);t.setTextSize(size);t.setTextColor(color);t.setLineSpacing(dp(4),1);
        if(bold)t.setTypeface(null,Typeface.BOLD);return t;
    }
    private void add(LinearLayout box,View view,int top){LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,-2);p.topMargin=dp(top);box.addView(view,p);}
    private Button button(String value,boolean primary){
        Button b=new Button(this);b.setText(value);b.setAllCaps(false);b.setTextColor(primary?Color.WHITE:PURPLE);b.setTextSize(16);b.setMinHeight(dp(52));
        b.setBackgroundTintList(ColorStateList.valueOf(primary?PURPLE:0xffeee7f8));return b;
    }
    private Spinner selector(LinearLayout box,String label){
        TextView heading=text(label,14,MUTED,true);add(box,heading,16);
        Spinner spinner=new Spinner(this,Spinner.MODE_DROPDOWN);spinner.setContentDescription(label);spinner.setMinimumHeight(dp(48));add(box,spinner,4);return spinner;
    }
    private void choices(Spinner spinner,List<String> names){
        ArrayAdapter<String> adapter=new ArrayAdapter<>(this,android.R.layout.simple_spinner_item,names);
        adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);spinner.setAdapter(adapter);
    }
    @Override public void onCreate(Bundle bundle){
        super.onCreate(bundle);getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        options=new SpeechSettings(this);savedLegacy=options.legacy;
        ScrollView scroll=new ScrollView(this);scroll.setFillViewport(true);scroll.setBackgroundColor(0xfff5f2fa);
        LinearLayout box=new LinearLayout(this);box.setOrientation(LinearLayout.VERTICAL);box.setPadding(dp(24),dp(32),dp(24),dp(28));scroll.addView(box);
        scroll.setOnApplyWindowInsetsListener((v,insets)->{
            int top,bottom;
            if(Build.VERSION.SDK_INT>=30){android.graphics.Insets bars=insets.getInsets(WindowInsets.Type.systemBars());top=bars.top;bottom=bars.bottom;}
            else{top=insets.getSystemWindowInsetTop();bottom=insets.getSystemWindowInsetBottom();}
            box.setPadding(dp(24),top+dp(24),dp(24),bottom+dp(24));return insets;
        });
        Button back=button("‹ 返回",false);back.setOnClickListener(v->finish());add(box,back,0);
        add(box,text("云端模型配置",25,INK,true),20);
        add(box,text("火山引擎／豆包",14,MUTED,false),8);
        LinearLayout card=new LinearLayout(this);card.setOrientation(LinearLayout.VERTICAL);card.setPadding(dp(20),dp(20),dp(20),dp(20));
        GradientDrawable background=new GradientDrawable();background.setColor(Color.WHITE);background.setCornerRadius(dp(24));card.setBackground(background);add(box,card,20);
        cloud=new Switch(this);cloud.setText("启用云端 TTS");cloud.setChecked(options.cloud);add(card,cloud,0);
        hint=text("",14,MUTED,false);add(card,hint,8);
        fields=new LinearLayout(this);fields.setOrientation(LinearLayout.VERTICAL);add(card,fields,8);
        model=selector(fields,"语音模型");List<String> modelNames=new ArrayList<>();
        for(String[] m:CloudSpeechCatalog.MODELS){modelIDs.add(m[0]);modelNames.add(m[1]);}
        modelIDs.add(CloudSpeechCatalog.CUSTOM);modelNames.add("自定义");
        choices(model,modelNames);int selectedModel=modelIDs.indexOf(options.resource);
        model.setSelection(selectedModel>=0?selectedModel:modelIDs.size()-1);
        customModel=new EditText(this);customModel.setHint("模型资源 ID");customModel.setText(options.resource);customModel.setSingleLine(true);
        customModel.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);add(fields,customModel,8);
        voice=selector(fields,"音色");
        customVoice=new EditText(this);customVoice.setHint("音色 ID");customVoice.setText(options.voice);customVoice.setSingleLine(true);
        customVoice.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);add(fields,customVoice,8);
        loadVoices(selectedResource(),options.voice);
        add(fields,text("请在火山控制台开通所选服务。自定义音色需与模型资源 ID 匹配，保存后可试听。",13,MUTED,false),12);
        legacy=new Switch(this);legacy.setText("使用旧版 App ID / Access Token");legacy.setChecked(options.legacy);add(fields,legacy,20);
        app=new EditText(this);app.setHint("App ID");app.setText(options.appId);app.setSingleLine(true);
        app.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);add(fields,app,8);
        secret=new EditText(this);secret.setSingleLine(true);secret.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_PASSWORD);
        secret.setSaveEnabled(false);secret.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);add(fields,secret,8);
        accountHint=text("",13,MUTED,false);add(fields,accountHint,8);
        clear=button("清除已保存密钥",false);clear.setOnClickListener(v->{
            try{options.clear();secret.getText().clear();updateForm();Toast.makeText(this,"密钥已清除",Toast.LENGTH_SHORT).show();}
            catch(Exception e){Toast.makeText(this,"清除失败，请重试",Toast.LENGTH_SHORT).show();}
        });add(fields,clear,12);
        Button save=button("保存",true);save.setOnClickListener(v->{if(save()){finish();}});add(box,save,20);
        preview=button("保存并试听云端语音",false);preview.setOnClickListener(v->{if(save()){SpeechEngine.get(this).preview(true);}});add(box,preview,8);
        status=text("",14,MUTED,false);add(box,status,8);
        add(box,text("云端提供更多音色和更丰富的语气表现；需要联网，可能产生服务费用，回复文字会发送给火山引擎。密钥仅在本机安全加密保存。",14,MUTED,false),16);
        add(box,text("未配置、未开启或开播前失败时使用本机 TTS；已开播后失败只停止，文字仍可阅读。",14,MUTED,false),10);
        cloud.setOnCheckedChangeListener((b,checked)->updateForm());
        legacy.setOnCheckedChangeListener((b,checked)->{secret.getText().clear();updateForm();});
        model.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener(){
            public void onItemSelected(AdapterView<?> parent,View view,int position,long id){
                String chosen=selectedResource();
                if(!chosen.equals(displayedModel)) {
                    String selected=selectedVoice();
                    boolean custom=CloudSpeechCatalog.CUSTOM.equals(voiceIDs.get(voice.getSelectedItemPosition()));
                    String[][] voices=CloudSpeechCatalog.voices(chosen);
                    if(!custom && !CloudSpeechCatalog.CUSTOM.equals(modelIDs.get(position)) && voices.length>0)selected=voices[0][0];
                    loadVoices(chosen,selected);
                }
                updateForm();
            }
            public void onNothingSelected(AdapterView<?> parent){}
        });
        TextWatcher changed=new TextWatcher(){public void beforeTextChanged(CharSequence s,int start,int count,int after){}public void onTextChanged(CharSequence s,int start,int before,int count){updateForm();}public void afterTextChanged(Editable e){}};
        app.addTextChangedListener(changed);secret.addTextChangedListener(changed);
        customVoice.addTextChangedListener(changed);
        customModel.addTextChangedListener(new TextWatcher(){
            public void beforeTextChanged(CharSequence s,int start,int count,int after){}
            public void onTextChanged(CharSequence s,int start,int before,int count){
                String resource=selectedResource();
                if(!resource.equals(displayedModel))loadVoices(resource,selectedVoice());
                updateForm();
            }
            public void afterTextChanged(Editable e){}
        });
        voice.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener(){
            public void onItemSelected(AdapterView<?> parent,View view,int position,long id){updateForm();}
            public void onNothingSelected(AdapterView<?> parent){}
        });
        updateForm();setContentView(scroll);
    }
    private void loadVoices(String resource,String selected){
        displayedModel=resource;voiceIDs.clear();List<String> names=new ArrayList<>();
        for(String[] v:CloudSpeechCatalog.voices(resource)){voiceIDs.add(v[0]);names.add(v[1]);}
        voiceIDs.add(CloudSpeechCatalog.CUSTOM);names.add("自定义");
        choices(voice,names);int index=voiceIDs.indexOf(selected);
        if(index<0 && !selected.isEmpty())customVoice.setText(selected);
        voice.setSelection(index>=0?index:voiceIDs.size()-1);
    }
    private String selectedResource(){
        String selected=modelIDs.get(model.getSelectedItemPosition());
        return (CloudSpeechCatalog.CUSTOM.equals(selected)?customModel.getText().toString():selected).trim();
    }
    private String selectedVoice(){
        String selected=voiceIDs.get(voice.getSelectedItemPosition());
        return (CloudSpeechCatalog.CUSTOM.equals(selected)?customVoice.getText().toString():selected).trim();
    }
    private void updateForm(){
        fields.setVisibility(cloud.isChecked()?View.VISIBLE:View.GONE);
        customModel.setVisibility(CloudSpeechCatalog.CUSTOM.equals(modelIDs.get(model.getSelectedItemPosition()))?View.VISIBLE:View.GONE);
        customVoice.setVisibility(CloudSpeechCatalog.CUSTOM.equals(voiceIDs.get(voice.getSelectedItemPosition()))?View.VISIBLE:View.GONE);
        app.setVisibility(legacy.isChecked()?View.VISIBLE:View.GONE);
        hint.setText(cloud.isChecked()?"保存后优先使用云端；配置未完成时仍使用本机 TTS。":"当前使用本机 TTS。开启后可配置云端模型和音色，关闭不会删除已保存配置。");
        boolean kept=options.hasSecret() && legacy.isChecked()==savedLegacy;
        secret.setHint(kept?"已保存密钥，留空保持":legacy.isChecked()?"Access Token":"API Key");
        accountHint.setText(legacy.isChecked()?"填写旧版语音控制台的 App ID 和 Access Token。":"填写新版语音控制台的 API Key，无需 App ID。");
        clear.setEnabled(options.hasSecret());preview.setVisibility(cloud.isChecked()?View.VISIBLE:View.GONE);
        preview.setEnabled(!selectedResource().isEmpty() && !selectedVoice().isEmpty() && (kept || !secret.getText().toString().trim().isEmpty()) && (!legacy.isChecked() || !app.getText().toString().trim().isEmpty()));
    }
    private boolean save(){
        options.cloud=cloud.isChecked();options.legacy=legacy.isChecked();options.appId=app.getText().toString();
        options.resource=selectedResource();options.voice=selectedVoice();
        try{options.save(secret.getText().toString().trim());savedLegacy=options.legacy;secret.getText().clear();updateForm();
            Toast.makeText(this,options.cloud && !options.configured()?"已保存，云端配置未完成，仍使用本机 TTS":"已保存",Toast.LENGTH_SHORT).show();return true;}
        catch(IllegalArgumentException e){secret.setError("切换鉴权方式时，请填写对应密钥");return false;}
        catch(Exception e){Toast.makeText(this,"无法安全保存，请重试",Toast.LENGTH_SHORT).show();return false;}
    }
    @Override public void onResume(){super.onResume();tick.post(refresh);}
    @Override public void onPause(){tick.removeCallbacks(refresh);super.onPause();}
    @Override public void onDestroy(){secret.getText().clear();super.onDestroy();}
}
