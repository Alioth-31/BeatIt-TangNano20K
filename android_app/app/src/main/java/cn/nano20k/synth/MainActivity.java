package cn.nano20k.synth;

import android.Manifest;
import android.app.*;
import android.bluetooth.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.media.*;
import android.net.Uri;
import android.os.*;
import android.view.*;
import android.widget.*;
import cn.nano20k.synth.core.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;

public final class MainActivity extends Activity implements Session.Ui {
    private static final int BG=0xff10171c,CARD=0xff1a252d,TEXT=0xffedf3f4,MUTED=0xff94a7b2,ACCENT=0xff65e1c2;
    private final Handler h=new Handler(Looper.getMainLooper());private final ExecutorService io=Executors.newSingleThreadExecutor();
    private Session session;private Library library;private LinearLayout root,content,nav,deviceList;private TextView connection,modeLabel,volumeLabel,bendLabel,scoreLabel,recordLabel,deviceLabel;private Button recordButton,playButton,micButton;
    private PadView pad;private SeekBar volumeSlider,bendSlider;private RadioGroup presetGroup;private boolean binding;
    private TextView practiceStatus;
    private ProgressBar practiceProgress;
    private int tab;private final Map<String,BluetoothDevice> devices=new LinkedHashMap<>();
    private final LinkedHashMap<String,Midi.Song> songs=new LinkedHashMap<>();private String selected="小星星";
    private MediaRecorder microphone;private MediaPlayer localAudio;private File microphoneFile;
    private byte[] exportData;private File exportFile;private boolean visible;
    private final Runnable ticker=new Runnable(){public void run(){if(visible){changed();h.postDelayed(this,200);}}};
    private int d(float x){return Math.round(x*getResources().getDisplayMetrics().density);}
    @Override public void onCreate(Bundle state){
        super.onCreate(state);session=new Session(this);session.ble=new BleTransport(this,session);library=new Library(this);
        SharedPreferences prefs=getSharedPreferences("settings",MODE_PRIVATE);session.volume=prefs.getInt("volume",16384);session.preset=prefs.getInt("preset",0);
        for(int i=0;i<8;i++)session.mapping[i]=Math.max(0,Math.min(31,prefs.getInt("key"+i,i)));
        songs.put("小星星",Midi.twinkle());songs.put("欢乐颂",Midi.ode());
        songs.put("两只老虎",Midi.melody(60,62,64,60,60,62,64,60,64,65,67,64,65,67,67,69,67,65,64,60,67,69,67,65,64,60,60,67,60,60,67,60));
        songs.put("玛丽有只小羊羔",Midi.melody(64,62,60,62,64,64,64,62,62,62,64,67,67,64,62,60,62,64,64,64,64,62,62,64,62,60));
        File scores=new File(getFilesDir(),"scores");File[] files=scores.listFiles((dir,name)->name.endsWith(".mid"));if(files!=null)for(File f:files)try(FileInputStream in=new FileInputStream(f)){songs.put(f.getName(),Midi.read(Library.readBounded(in,Midi.MAX_BYTES)));}catch(Exception ignored){}
        createShell();showTab(0);
    }
    private void createShell(){
        root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setBackgroundColor(BG);root.setPadding(d(20),0,d(20),0);
        root.setOnApplyWindowInsetsListener((v,insets)->{if(Build.VERSION.SDK_INT>=30){android.graphics.Insets i=insets.getInsets(WindowInsets.Type.systemBars()|WindowInsets.Type.displayCutout());root.setPadding(d(20)+i.left,i.top+d(10),d(20)+i.right,i.bottom+d(8));}else{root.setPadding(d(20)+insets.getSystemWindowInsetLeft(),d(10),d(20)+insets.getSystemWindowInsetRight(),d(8));}return insets;});
        LinearLayout head=row();TextView logo=text("NANO / SYNTH",23,TEXT);logo.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));head.addView(logo,new LinearLayout.LayoutParams(0,-2,1));TextView version=text("20K",12,ACCENT);version.setPadding(d(10),d(7),d(10),d(7));version.setBackground(shape(0xff233b37,10));head.addView(version);root.addView(head);
        connection=text("○ 未连接设备",12,MUTED);connection.setPadding(0,d(8),0,d(14));connection.setOnClickListener(v->showTab(3));root.addView(connection);
        ScrollView scroll=new ScrollView(this);scroll.setFillViewport(true);scroll.setClipToPadding(false);content=new LinearLayout(this);content.setOrientation(LinearLayout.VERTICAL);scroll.addView(content);root.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
        nav=row();nav.setPadding(0,d(12),0,0);root.addView(nav);setContentView(root);root.requestApplyInsets();
    }
    private TextView text(String value,int size,int color){TextView t=new TextView(this);t.setText(value);t.setTextSize(size);t.setTextColor(color);t.setLineSpacing(d(3),1);return t;}
    private LinearLayout row(){LinearLayout r=new LinearLayout(this);r.setOrientation(LinearLayout.HORIZONTAL);r.setGravity(Gravity.CENTER_VERTICAL);return r;}
    private GradientDrawable shape(int color,int radius){GradientDrawable g=new GradientDrawable();g.setColor(color);g.setCornerRadius(d(radius));return g;}
    private LinearLayout card(){LinearLayout c=new LinearLayout(this);c.setOrientation(LinearLayout.VERTICAL);c.setPadding(d(16),d(16),d(16),d(16));c.setBackground(shape(CARD,18));LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,-2);p.bottomMargin=d(14);content.addView(c,p);return c;}
    private void gap(LinearLayout box,int height){View v=new View(this);box.addView(v,new LinearLayout.LayoutParams(1,d(height)));}
    private Button button(String label,boolean accent,Runnable action){Button b=new Button(this);b.setText(label);b.setTextSize(13);b.setAllCaps(false);b.setTextColor(accent?BG:TEXT);b.setBackground(shape(accent?ACCENT:0xff293944,12));b.setMinHeight(d(48));b.setMinimumHeight(d(48));b.setPadding(d(12),d(7),d(12),d(7));b.setOnClickListener(v->action.run());return b;}
    private void full(LinearLayout box,Button button){box.addView(button,new LinearLayout.LayoutParams(-1,d(48)));}
    private void pair(LinearLayout box,Button a,Button b){LinearLayout r=row();LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(0,d(48),1);lp.rightMargin=d(8);r.addView(a,lp);r.addView(b,new LinearLayout.LayoutParams(0,d(48),1));box.addView(r);}
    private void heading(String small,String title,String subtitle){content.addView(text(small,11,ACCENT));TextView name=text(title,28,TEXT);name.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));name.setPadding(0,d(6),0,d(5));content.addView(name);TextView sub=text(subtitle,12,MUTED);sub.setPadding(0,0,0,d(20));content.addView(sub);}
    private void showTab(int index){
        if(tab==4&&index!=4&&session.practice!=null)session.stopPractice("");
        practiceStatus=null;practiceProgress=null;
        if(pad!=null)pad.releaseFingers();tab=index;content.removeAllViews();nav.removeAllViews();pad=null;volumeLabel=null;bendLabel=null;volumeSlider=null;bendSlider=null;presetGroup=null;recordLabel=null;recordButton=null;micButton=null;scoreLabel=null;playButton=null;deviceLabel=null;deviceList=null;modeLabel=null;
        String[] labels={"演奏","曲谱","记录","设备"};for(int i=0;i<4;i++){final int n=i;Button b=button(labels[i],i==(tab==4?1:tab),()->showTab(n));LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(0,d(48),1);if(i<3)p.rightMargin=d(6);nav.addView(b,p);}
        if(index==0)performance();else if(index==1)scores();else if(index==2)recordings();else if(index==4)practicePage();else equipment();changed();
    }
    private void performance(){
        heading("LIVE INSTRUMENT","指尖，成为和弦","实时控制 FPGA · 8 个琴键 · 独立声部");
        LinearLayout meta=row();modeLabel=text("4 VOICES",11,ACCENT);meta.addView(modeLabel,new LinearLayout.LayoutParams(0,-2,1));TextView edit=text("自定义键位 ↗",12,MUTED);edit.setPadding(d(8),d(10),0,d(10));edit.setOnClickListener(v->mappingDialog());meta.addView(edit);content.addView(meta);gap(content,8);
        pad=new PadView(this,session);content.addView(pad,new LinearLayout.LayoutParams(-1,d(224)));gap(content,16);
        LinearLayout controls=card();volumeLabel=text("",13,TEXT);controls.addView(volumeLabel);volumeSlider=new SeekBar(this);volumeSlider.setMax(65535);volumeSlider.setContentDescription("总音量");volumeSlider.setProgress(session.volume);controls.addView(volumeSlider,new LinearLayout.LayoutParams(-1,d(48)));
        volumeSlider.setOnSeekBarChangeListener(slider((p)->session.parameters(p,session.bend,session.preset)));
        gap(controls,6);LinearLayout bendHead=row();bendLabel=text("",13,TEXT);bendHead.addView(bendLabel,new LinearLayout.LayoutParams(0,-2,1));TextView reset=text("归零",12,ACCENT);reset.setPadding(d(10),d(10),d(4),d(10));reset.setOnClickListener(v->session.parameters(session.volume,0,session.preset));bendHead.addView(reset);controls.addView(bendHead);
        bendSlider=new SeekBar(this);bendSlider.setMax(64);bendSlider.setProgress(session.bend+32);bendSlider.setContentDescription("弯音，负二至正二半音");controls.addView(bendSlider,new LinearLayout.LayoutParams(-1,d(48)));bendSlider.setOnSeekBarChangeListener(slider((p)->session.parameters(session.volume,p-32,session.preset)));
        LinearLayout envelope=card();envelope.addView(text("包络预设",13,TEXT));gap(envelope,10);presetGroup=new RadioGroup(this);presetGroup.setOrientation(LinearLayout.HORIZONTAL);String[] presets={"标准","短音","长音"};
        for(int i=0;i<3;i++){RadioButton b=new RadioButton(this);b.setId(100+i);b.setText(presets[i]);b.setTextColor(TEXT);b.setTextSize(13);presetGroup.addView(b,new RadioGroup.LayoutParams(0,d(48),1));}presetGroup.check(100+session.preset);presetGroup.setOnCheckedChangeListener((g,id)->{if(!binding)session.parameters(session.volume,session.bend,id-100);});envelope.addView(presetGroup);envelope.addView(text("预设对新触发音符生效；弯音保持相位连续。",11,MUTED));
        pair(content,button("● 记录演奏",false,()->{toggleEventRecording();}),button("停止所有音符",false,session::panic));gap(content,16);
        TextView note=text("连接设备后，声音由 Nano 20K 生成。演示模式只检验操作与事件，不输出声音。",11,MUTED);content.addView(note);gap(content,20);
    }
    private interface Progress {void change(int progress);}
    private SeekBar.OnSeekBarChangeListener slider(Progress callback){return new SeekBar.OnSeekBarChangeListener(){public void onProgressChanged(SeekBar s,int p,boolean user){if(user&&!binding)callback.change(p);}public void onStartTrackingTouch(SeekBar s){}public void onStopTrackingTouch(SeekBar s){}};}
    private void mappingDialog(){
        session.panic();LinearLayout box=new LinearLayout(this);box.setOrientation(LinearLayout.VERTICAL);box.setPadding(d(16),d(4),d(16),d(8));Spinner[] spinners=new Spinner[8];String[] names=new String[32];for(int k=0;k<32;k++)names[k]=Notes.label(k)+"  · MIDI "+Notes.midiForKey(k);
        for(int i=0;i<8;i++){LinearLayout r=row();r.addView(text("键 "+(i+1),13,TEXT));Spinner s=new Spinner(this);ArrayAdapter<String> a=new ArrayAdapter<>(this,android.R.layout.simple_spinner_dropdown_item,names);s.setAdapter(a);s.setSelection(session.mapping[i]);r.addView(s,new LinearLayout.LayoutParams(0,d(48),1));box.addView(r);spinners[i]=s;}
        new AlertDialog.Builder(this).setTitle("自定义八个琴键").setView(box).setPositiveButton("保存",(dialog,which)->{int[] keys=new int[8];for(int i=0;i<8;i++)keys[i]=spinners[i].getSelectedItemPosition();session.applyMapping(keys);persist();changed();}).setNeutralButton("恢复默认",(dialog,which)->{session.applyMapping(new int[]{0,1,2,3,4,5,6,7});persist();}).setNegativeButton("取消",null).show();
    }
    private void scores(){
        heading("SCORE LIBRARY","让乐谱发声","选一首曲子跟弹，或用 FPGA 回放");
        LinearLayout actions=card();actions.addView(text("导入标准 MIDI 0 / 1",15,TEXT));gap(actions,8);actions.addView(text("支持速度变化与多轨。单文件 ≤1 MB，时长 ≤10 分钟。",11,MUTED));gap(actions,14);
        pair(actions,button("导入 MIDI",true,()->{Intent intent=new Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE);startActivityForResult(intent,20);}),button("在线下载",false,this::downloadDialog));
        for(Map.Entry<String,Midi.Song> e:songs.entrySet()){
            String name=e.getKey();Midi.Song song=e.getValue();LinearLayout c=card();LinearLayout top=row();TextView title=text(name,17,TEXT);top.addView(title,new LinearLayout.LayoutParams(0,-2,1));TextView tag=text(name.equals(selected)?"已选择":"MIDI",10,ACCENT);top.addView(tag);c.addView(top);gap(c,6);
            c.addView(text(String.format(Locale.CHINA,"%d 个音符 · %s",song.events.size()/2,time(song.durationMs)),11,MUTED));gap(c,12);
            pair(c,button("用琴体跟弹",true,()->openPractice(name,true)),button("手机练习",false,()->openPractice(name,false)));
            gap(c,8);full(c,button("播放此曲谱",false,()->{selected=name;session.play(song);changed();}));
        }
        LinearLayout transport=card();scoreLabel=text("",13,ACCENT);transport.addView(scoreLabel);gap(transport,12);playButton=button("停止播放",false,session::panic);full(transport,playButton);
        content.addView(text("内置曲谱采用公版旋律。下载请输入可直接获取 .mid 文件的 HTTPS 地址；网页或音频文件无法作为曲谱导入。",11,MUTED));gap(content,20);
    }
    private void openPractice(String name,boolean physical){
        session.startPractice(songs.get(name),physical);
        if(session.practice!=null){selected=name;showTab(4);}
    }
    private void practicePage(){
        heading("PRACTICE",selected,"亮起的键是当前目标。和弦需要同时按住，松开后进入下一步。");
        LinearLayout panel=card();
        practiceStatus=text("",17,TEXT);practiceStatus.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        panel.addView(practiceStatus);gap(panel,10);
        practiceProgress=new ProgressBar(this,null,android.R.attr.progressBarStyleHorizontal);
        panel.addView(practiceProgress,new LinearLayout.LayoutParams(-1,d(10)));
        pad=new PadView(this,session,true,this::changed);content.addView(pad,new LinearLayout.LayoutParams(-1,d(224)));gap(content,14);
        pair(content,button("重练 · 琴体",true,()->openPractice(selected,true)),button("重练 · 手机",false,()->openPractice(selected,false)));
        gap(content,8);full(content,button("返回曲库",false,()->showTab(1)));
        gap(content,12);content.addView(text("琴体跟弹建议在自由演奏模式下开始。手机练习为无声多点触控，可离线使用。",12,MUTED));
    }
    private void downloadDialog(){EditText address=new EditText(this);address.setHint("https://…/score.mid");address.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_VARIATION_URI);address.setSingleLine(true);
        new AlertDialog.Builder(this).setTitle("下载 MIDI 曲谱").setMessage("使用你有权下载的 HTTPS 曲谱直链。文件解析成功后才会加入曲谱库。").setView(address).setPositiveButton("下载",(dlg,n)->{String url=address.getText().toString();message("正在下载曲谱…");io.execute(()->{try{byte[] data=Library.download(url);Midi.Song song=Midi.read(data);saveSong(data,song,"下载曲谱");}catch(Exception error){h.post(()->message("下载失败："+error.getMessage()));}});}).setNegativeButton("取消",null).show();
    }
    private void saveSong(byte[] data,Midi.Song song,String label)throws IOException {
        File dir=new File(getFilesDir(),"scores");if(!dir.isDirectory()&&!dir.mkdirs())throw new IOException("无法建立曲谱目录");String name=label+"_"+System.currentTimeMillis()+".mid";try(FileOutputStream out=new FileOutputStream(new File(dir,name))){out.write(data);}h.post(()->{if(isDestroyed())return;songs.put(name,song);showTab(1);selected=name;changed();message("曲谱已加入，可选择跟弹");});
    }
    private void recordings(){
        heading("PERFORMANCE ARCHIVE","留下这次演奏","事件可回放 · 麦克风音频可分享");
        LinearLayout events=card();events.addView(text("演奏事件",18,TEXT));gap(events,6);events.addView(text("保存按键、音量、弯音和包络参数。支持固件回传时一并记录实体按键；JSON 保留参数，MIDI 仅导出音符。",11,MUTED));gap(events,12);recordLabel=text("",12,ACCENT);events.addView(recordLabel);gap(events,12);recordButton=button("开始记录事件",true,this::toggleEventRecording);full(events,recordButton);
        LinearLayout audio=card();audio.addView(text("扬声器录音",18,TEXT));gap(audio,6);audio.addView(text("用手机麦克风录制现场声音，保存 M4A。这是声学录音；当前板卡没有数字音频回传。切到后台会自动停止并保存。",11,MUTED));gap(audio,12);micButton=button("开始麦克风录音",false,this::toggleMicrophone);full(audio,micButton);
        content.addView(text("本地记录",12,MUTED));gap(content,12);
        List<File> files=library.files();if(files.isEmpty()){LinearLayout empty=card();empty.addView(text("还没有记录",17,TEXT));gap(empty,5);empty.addView(text("开始一段演奏，保存后会显示在这里。",12,MUTED));}
        for(File file:files){LinearLayout c=card();boolean isAudio=file.getName().endsWith(".m4a");String name=isAudio?"现场录音 · "+new java.text.SimpleDateFormat("MM-dd HH:mm",Locale.CHINA).format(new Date(file.lastModified())):file.getName();Library.Recording rec=null;
            if(!isAudio)try{rec=library.read(file);name=rec.name;}catch(Exception e){c.addView(text("损坏的记录："+file.getName(),12,MUTED));continue;}
            c.addView(text(name,16,TEXT));gap(c,6);Library.Recording recording=rec;c.addView(text(isAudio?"M4A · 手机麦克风 · "+(file.length()/1024)+" KB":recording.source+" · "+time(recording.duration)+(recording.complete?"":" · 事件不完整"),11,MUTED));gap(c,12);
            if(isAudio)pair(c,button("试听 / 停止",false,()->listen(file)),button("导出 M4A",false,()->export(file,"audio/mp4",file.getName())));
            else{pair(c,button("回放事件",false,()->{if(!recording.complete)new AlertDialog.Builder(this).setTitle("事件记录不完整").setMessage("部分回传事件可能缺失。仍可回放已保存部分。").setPositiveButton("回放",(dialog,id)->session.play(recording.events,recording.duration)).setNegativeButton("取消",null).show();else session.play(recording.events,recording.duration);}),button("导出 JSON",false,()->export(file,"application/json",file.getName())));gap(c,8);full(c,button("导出 MIDI 音符",false,()->{try{export(Midi.write(recording.notes(),recording.duration),"audio/midi",file.getName().replace(".json",".mid"));}catch(Exception e){message(e.getMessage());}}));}
        }gap(content,20);
    }
    private void toggleEventRecording(){
        if(session.recording){saveRecording();if(tab==2)showTab(2);}else{if(!session.usable()){message("先连接固件，或在设备页开启演示模式");return;}session.startRecording();message("开始记录演奏事件");}
    }
    private void saveRecording(){Library.Recording recording=session.stopRecording();if(recording==null)return;try{library.save(recording);message("演奏事件已保存");}catch(Exception e){message("保存失败："+e.getMessage());}}
    private void toggleMicrophone(){if(microphone!=null){stopMicrophone();showTab(2);return;}if(checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED){requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO},31);return;}startMicrophone();}
    private void startMicrophone(){
        stopAudio();microphoneFile=library.audioFile();microphone=Build.VERSION.SDK_INT>=31?new MediaRecorder(this):new MediaRecorder();
        try{microphone.setAudioSource(MediaRecorder.AudioSource.MIC);microphone.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);microphone.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);microphone.setAudioSamplingRate(48000);microphone.setAudioEncodingBitRate(128000);microphone.setMaxDuration(600000);microphone.setMaxFileSize(100*1024*1024);microphone.setOutputFile(microphoneFile.getAbsolutePath());microphone.setOnInfoListener((rec,what,extra)->{if(what==MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED||what==MediaRecorder.MEDIA_RECORDER_INFO_MAX_FILESIZE_REACHED){stopMicrophone();if(tab==2)showTab(2);}});microphone.prepare();microphone.start();message("麦克风录音已开始");}
        catch(Exception e){microphone.release();microphone=null;if(microphoneFile!=null)microphoneFile.delete();message("无法启动录音："+e.getMessage());}changed();
    }
    private void stopMicrophone(){if(microphone==null)return;boolean saved=true;try{microphone.stop();}catch(RuntimeException e){saved=false;}finally{microphone.release();microphone=null;}if(!saved&&microphoneFile!=null)microphoneFile.delete();message(saved?"现场录音已保存":"录音太短，未保存音频");changed();}
    private void listen(File f){if(localAudio!=null){stopAudio();return;}if(microphone!=null){message("请先停止麦克风录音");return;}session.panic();try{localAudio=new MediaPlayer();localAudio.setDataSource(f.getAbsolutePath());localAudio.setOnCompletionListener(p->stopAudio());localAudio.setOnErrorListener((p,w,e)->{stopAudio();message("无法播放音频");return true;});localAudio.prepare();localAudio.start();message("播放手机录音");}catch(Exception e){stopAudio();message("试听失败："+e.getMessage());}}
    private void stopAudio(){if(localAudio!=null){localAudio.release();localAudio=null;}}
    private void equipment(){
        heading("DEVICE LINK","连接你的 Nano","BLE UART → FPGA → 板载功放");
        LinearLayout state=card();deviceLabel=text("",15,ACCENT);state.addView(deviceLabel);gap(state,12);state.addView(text("接入 BLE 模块并下载配套 BLE 固件。连接后等待「FPGA 已就绪」再演奏。",12,MUTED));gap(state,14);
        pair(state,button("搜索 BLE 设备",true,this::scan),button("断开 / 停止",false,()->{session.panic();session.ble.disconnect("已手动断开");session.demo=false;changed();}));gap(state,8);full(state,button(session.demo?"退出演示模式":"开启演示模式（无声音）",false,()->{session.demo(!session.demo);showTab(3);}));
        content.addView(text("附近设备",12,MUTED));gap(content,10);deviceList=new LinearLayout(this);deviceList.setOrientation(LinearLayout.VERTICAL);content.addView(deviceList);renderDevices();
        LinearLayout steps=card();steps.addView(text("首次接入",16,TEXT));gap(steps,8);steps.addView(text("1  准备兼容 NUS 或 HM-10 的 BLE 模块。\n2  按接线表连接模块，信号电平 3.3 V、共地。\n3  下载提供的 BLE 版固件到板卡。\n4  App 连接设备，等待「FPGA 已就绪」。",12,MUTED));gap(steps,10);steps.addView(text("手机蓝牙延迟需实测；赛题 ≤10 ms 验收以实体控制到音频输出链路为基线。",11,MUTED));
        LinearLayout privacy=card();privacy.addView(text("权限与本地数据",15,TEXT));gap(privacy,6);privacy.addView(text("蓝牙仅在连接设备时使用；麦克风仅在前台主动录音。曲谱、键位与记录保存在手机本地，无账号、无分析上传。App 进入后台时停止手机音符并断开连接。",11,MUTED));gap(content,20);
    }
    private void scan(){
        if(!session.ble.available()){message("当前 Android 设备没有蓝牙适配器");return;}
        if(!session.ble.permitted()){requestPermissions(Build.VERSION.SDK_INT>=31?new String[]{Manifest.permission.BLUETOOTH_SCAN,Manifest.permission.BLUETOOTH_CONNECT}:new String[]{Manifest.permission.ACCESS_FINE_LOCATION},30);return;}
        if(!session.ble.enabled()){try{startActivityForResult(new Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE),22);}catch(SecurityException e){message("蓝牙权限已撤销，请重新授权");}return;}
        devices.clear();renderDevices();session.ble.scan();
    }
    @Override public void device(BluetoothDevice device,int rssi){try{String address=device.getAddress();if(!devices.containsKey(address)){devices.put(address,device);renderDevices();}}catch(SecurityException e){message("蓝牙权限已撤销");}}
    private void renderDevices(){if(deviceList==null)return;deviceList.removeAllViews();if(devices.isEmpty()){TextView empty=text("尚未发现设备，开启模块后点击搜索。",12,MUTED);empty.setPadding(d(8),d(14),d(8),d(18));deviceList.addView(empty);return;}
        for(BluetoothDevice device:devices.values()){String name,address;try{name=device.getName();address=device.getAddress();}catch(SecurityException e){continue;}String label=(name==null?"未命名 BLE 设备":name)+"\n"+address;Button b=button(label,false,()->{session.panic();session.demo=false;try{session.ble.connect(device);}catch(SecurityException e){message("蓝牙权限已撤销，请重新授权");}});LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,d(64));p.bottomMargin=d(10);deviceList.addView(b,p);}
    }
    private void export(File f,String mime,String name){exportFile=f;exportData=null;startActivityForResult(new Intent(Intent.ACTION_CREATE_DOCUMENT).setType(mime).addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_TITLE,name),21);}
    private void export(byte[] bytes,String mime,String name){exportData=bytes;exportFile=null;startActivityForResult(new Intent(Intent.ACTION_CREATE_DOCUMENT).setType(mime).addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_TITLE,name),21);}
    @Override public void onActivityResult(int request,int result,Intent data){super.onActivityResult(request,result,data);if(request==22){if(result==RESULT_OK)scan();return;}if(result!=RESULT_OK||data==null||data.getData()==null)return;Uri uri=data.getData();
        if(request==20){io.execute(()->{try(InputStream in=getContentResolver().openInputStream(uri)){if(in==null)throw new IOException("无法打开文件");byte[] bytes=Library.readBounded(in,Midi.MAX_BYTES);saveSong(bytes,Midi.read(bytes),"导入曲谱");}catch(Exception e){h.post(()->message("导入失败："+e.getMessage()));}});}
        else if(request==21){byte[] bytes=exportData;File file=exportFile;exportData=null;exportFile=null;if(bytes==null&&file==null){message("导出中断，请重新选择记录");return;}io.execute(()->{try(OutputStream out=getContentResolver().openOutputStream(uri,"w")){if(out==null)throw new IOException("无法写入文件");if(bytes!=null)out.write(bytes);else try(InputStream in=new FileInputStream(file)){byte[] b=new byte[8192];int n;while((n=in.read(b))!=-1)out.write(b,0,n);}h.post(()->message("文件已导出"));}catch(Exception e){h.post(()->message("导出失败："+e.getMessage()));}});}
    }
    @Override public void onRequestPermissionsResult(int request,String[] permissions,int[] granted){super.onRequestPermissionsResult(request,permissions,granted);boolean ok=granted.length>0;for(int g:granted)ok&=g==PackageManager.PERMISSION_GRANTED;if(!ok){message("权限未授权；可继续使用本地曲谱和演示功能");return;}if(request==30)scan();else if(request==31)startMicrophone();}
    @Override public void changed(){
        if(connection==null||isDestroyed())return;binding=true;connection.setText((session.ready?"● ":session.demo?"◇ ":"○ ")+session.status);connection.setTextColor(session.ready||session.demo?ACCENT:MUTED);
        if(modeLabel!=null)modeLabel.setText(session.voices+" VOICES / "+(session.demo?"DEMO":session.ready?"LIVE":"OFFLINE"));if(pad!=null)pad.invalidate();
        if(practiceStatus!=null){
            Practice p=session.practice;
            String line=session.practiceMessage;
            if(p!=null&&session.practiceMapped()){
                String mode=session.physicalPractice?"琴体跟弹":"手机无声练习";
                line=p.done()?mode+" · 已完成 "+p.total()+" 步":mode+" · "+(p.step()+1)+"/"+p.total()
                        +"\n"+(p.waitingForRelease()?"松开所有琴键":"请弹 "+p.targetLabel());
                line+="\n错键 "+p.wrong()+" 次";
                if(session.physicalPractice&&!session.supportsPracticeLights())line+="\n更新琴体固件后可同步亮灯";
            }
            if(!line.contentEquals(practiceStatus.getText()))practiceStatus.setText(line);
            practiceProgress.setMax(p==null?1:p.total());practiceProgress.setProgress(p==null?0:p.step());
        }
        if(volumeLabel!=null)volumeLabel.setText("总音量                                      "+Math.round(session.volume*100.0/65535)+"%");if(bendLabel!=null)bendLabel.setText(String.format(Locale.CHINA,"弯音                       %+.2f 半音",session.bend/16.0));
        if(volumeSlider!=null&&!volumeSlider.isPressed())volumeSlider.setProgress(session.volume);if(bendSlider!=null&&!bendSlider.isPressed())bendSlider.setProgress(session.bend+32);if(presetGroup!=null)presetGroup.check(100+session.preset);
        if(recordLabel!=null)recordLabel.setText(session.recording?"● 正在记录 · "+session.recordSource:"准备记录 · 事件与真实音频分别保存");if(recordButton!=null)recordButton.setText(session.recording?"停止并保存事件":"开始记录事件");if(micButton!=null)micButton.setText(microphone!=null?"停止并保存录音":"开始麦克风录音");
        if(scoreLabel!=null)scoreLabel.setText(session.playing?"▶ 播放中 · "+time(session.playElapsed())+(session.demo?" · 演示无声":""):"当前曲谱："+selected);if(playButton!=null)playButton.setEnabled(session.playing);if(deviceLabel!=null)deviceLabel.setText(session.status+"\n"+session.firmware);binding=false;
    }
    @Override public void message(String text){if(!isDestroyed())Toast.makeText(this,text,Toast.LENGTH_LONG).show();}
    @Override public void recordingLimit(){saveRecording();message("事件记录达到时长或数量上限，已自动保存");if(tab==2)showTab(2);}
    private static String time(long ms){return String.format(Locale.CHINA,"%d:%02d",ms/60000,(ms/1000)%60);}
    private void persist(){SharedPreferences.Editor e=getSharedPreferences("settings",MODE_PRIVATE).edit().putInt("volume",session.volume).putInt("preset",session.preset);for(int i=0;i<8;i++)e.putInt("key"+i,session.mapping[i]);e.apply();}
    @Override protected void onResume(){super.onResume();visible=true;h.removeCallbacks(ticker);h.post(ticker);}
    @Override public void onWindowFocusChanged(boolean focused){super.onWindowFocusChanged(focused);if(!focused&&session!=null){if(pad!=null)pad.releaseFingers();session.panic();}}
    @Override protected void onPause(){visible=false;h.removeCallbacks(ticker);if(pad!=null)pad.releaseFingers();session.panic();if(session.recording)saveRecording();stopMicrophone();stopAudio();session.background();persist();super.onPause();}
    @Override protected void onDestroy(){session.close();io.shutdownNow();h.removeCallbacksAndMessages(null);super.onDestroy();}
}
