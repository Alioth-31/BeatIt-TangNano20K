package cn.nano20k.synth;

import android.app.*;
import android.content.*;
import android.bluetooth.BluetoothDevice;
import android.os.*;
import android.view.*;
import android.widget.*;
import android.net.Uri;
import android.provider.MediaStore;
import android.media.MediaMetadataRetriever;
import android.view.accessibility.AccessibilityNodeInfo;
import java.io.*;
import cn.nano20k.synth.core.*;
import java.lang.reflect.*;
import java.util.*;

/** Dependency-free instrumentation runner. Failures return RESULT_CANCELED. */
public final class SmokeTest extends Instrumentation {
    private MainActivity activity;private int checks;
    private void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    @Override public void onCreate(Bundle arguments){super.onCreate(arguments);start();}
    @Override public void onStart(){Bundle result=new Bundle();try{
        activity=(MainActivity)startActivitySync(new Intent(getTargetContext(),MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));waitForIdleSync();
        ui(()->{check(find("指尖，成为和弦")!=null,"Chinese performance page");click("设备");check(find("连接你的 Nano")!=null,"device page");click("开启演示模式（无声音）");click("演奏");});
        Session s=state();ui(()->{check(s.demo&&!s.ready,"demo cannot imply hardware ready");s.startRecording();s.press("one",0);s.press("two",0);s.release("one");check(s.mask()==1,"multi-owner hold");s.release("two");s.parameters(30000,-32,2);});
        SystemClock.sleep(80);ui(()->{Library.Recording recording=s.stopRecording();check(recording.events.stream().filter(e->e.type.equals("note")).count()==2,"record aggregate transitions");try{Library.Recording parsed=Library.Recording.parse(recording.json());check(parsed.events.size()==recording.events.size(),"JSON parameters round trip");check(Midi.read(Midi.write(recording.notes())).events.size()==2,"record MIDI export");}catch(Exception e){throw new RuntimeException(e);}click("曲谱");click("播放此曲谱");check(s.playing,"score scheduling");});
        SystemClock.sleep(80);ui(()->{check(s.mask()!=0,"score note on");s.panic();check(s.mask()==0&&!s.playing,"panic cancels scheduler");click("演奏");click("自定义键位 ↗");});
        waitForIdleSync();AccessibilityNodeInfo dialog=null;for(int i=0;i<30&&dialog==null;i++){dialog=getUiAutomation().getRootInActiveWindow();if(dialog==null)SystemClock.sleep(100);}check(dialog!=null,"accessible active dialog");List<AccessibilityNodeInfo> save=dialog.findAccessibilityNodeInfosByText("保存");check(!save.isEmpty(),"mapping dialog shown");save.get(0).performAction(AccessibilityNodeInfo.ACTION_CLICK);SystemClock.sleep(100);waitForIdleSync();
        ui(()->{s.applyMapping(new int[]{0,1,2,3,4,5,6,7});try{Field f=MainActivity.class.getDeclaredField("pad");f.setAccessible(true);PadView pad=(PadView)f.get(activity);touch(pad,MotionEvent.ACTION_DOWN,1);touch(pad,MotionEvent.ACTION_POINTER_DOWN|(1<<MotionEvent.ACTION_POINTER_INDEX_SHIFT),2);check(s.mask()==5,"native pad multi-touch chord");touch(pad,MotionEvent.ACTION_POINTER_UP,2);check(s.mask()==4,"one finger up preserves another");touch(pad,MotionEvent.ACTION_CANCEL,1);check(s.mask()==0,"cancel releases pad ownership");}catch(Exception e){throw new RuntimeException(e);}});
        ui(()->{s.press("focus",0);s.play(Midi.twinkle());activity.onWindowFocusChanged(false);check(!s.playing&&s.mask()==0,"window focus loss cancels notes and playback");activity.onWindowFocusChanged(true);});
        byte[] midi=Midi.write(Midi.twinkle().events);ContentValues values=new ContentValues();values.put(MediaStore.Downloads.DISPLAY_NAME,"nanosynth-test.mid");values.put(MediaStore.Downloads.MIME_TYPE,"audio/midi");Uri imported=getTargetContext().getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI,values);try(OutputStream out=getTargetContext().getContentResolver().openOutputStream(imported)){out.write(midi);}
        ui(()->activity.onActivityResult(20,Activity.RESULT_OK,new Intent().setData(imported)));SystemClock.sleep(250);waitForIdleSync();ui(()->check(find("让乐谱发声")!=null,"SAF import adds score"));getTargetContext().getContentResolver().delete(imported,null,null);
        try{Library.download("http://example.com/test.mid");throw new AssertionError("HTTP accepted");}catch(IOException expected){check(true,"HTTPS required before networking");}
        ui(()->click("记录"));ui(()->click("开始麦克风录音"));SystemClock.sleep(1200);ui(()->click("停止并保存录音"));
        List<File> files=new Library(activity).files();File audio=files.stream().filter(f->f.getName().endsWith(".m4a")).findFirst().orElseThrow();MediaMetadataRetriever metadata=new MediaMetadataRetriever();metadata.setDataSource(audio.getAbsolutePath());check(Long.parseLong(metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION))>500,"microphone produces valid M4A");metadata.release();
        ui(()->{s.demo(false);s.status("蓝牙已连接",true);check(!s.ready,"BLE link is not FPGA handshake");s.frame(hello());check(!s.ready,"unsolicited handshake rejected");s.writable();s.frame(new Protocol.Frame(Protocol.HELLO_REPLY,0,new byte[13]));check(!s.ready,"invalid handshake rejected");s.frame(hello());check(!s.ready,"HELLO must wait for authoritative STATUS before remote clear");s.frame(status(1,42000,-16,2,0));check(!s.ready&&s.volume==42000&&s.bend==-16&&s.preset==2,"legacy handshake reads physical parameters");s.frame(new Protocol.Frame(Protocol.ACK,2,new byte[]{Protocol.SET_MAP,0}));check(!s.ready,"wrong ACK type cannot finish clear");s.frame(new Protocol.Frame(Protocol.ACK,2,new byte[]{Protocol.SET_STATE,0}));check(s.ready,"legacy handshake ready only after clear ACK");s.frame(new Protocol.Frame(Protocol.EVENT,10,new byte[]{0,0,0,0,1,1}));s.startRecording();});
        SystemClock.sleep(60);ui(()->{s.parameters(20000,0,0);s.frame(new Protocol.Frame(Protocol.EVENT,11,new byte[]{48,0,0,0,1,0}));Library.Recording rec=s.stopRecording();try{Library.Recording.parse(rec.json());check(true,"delayed telemetry remains a valid timeline");}catch(Exception e){throw new AssertionError("out-of-order event timeline",e);}s.status("断开",false);check(!s.ready&&s.mask()==0,"disconnect clears remote notes");s.close();});
        ui(()->{
            click("曲谱");click("手机练习");
            check(s.practice!=null&&!s.physicalPractice&&s.practice.target()==1,"library opens offline practice");
            try{
                Field field=MainActivity.class.getDeclaredField("pad");field.setAccessible(true);
                PadView practicePad=(PadView)field.get(activity);
                check(practicePad.getAccessibilityNodeProvider().performAction(0,
                        AccessibilityNodeInfo.ACTION_CLICK,null),"accessible target can be played");
            }catch(ReflectiveOperationException error){throw new AssertionError(error);}
            check(s.practice.step()==1,"practice page advances after played note");
            click("返回曲库");check(s.practice==null,"leaving practice clears active lesson");
        });
        deviceSyncTests();
        result.putString("stream","PASS "+checks+" Android checks\n");finish(Activity.RESULT_OK,result);
    }catch(Throwable e){result.putString("stream","FAIL after "+checks+" checks: "+e+"\n"+android.util.Log.getStackTraceString(e));finish(Activity.RESULT_CANCELED,result);}}
    private Protocol.Frame hello(){return new Protocol.Frame(Protocol.HELLO_REPLY,0,new byte[]{1,4,7,(byte)0x80,(byte)0xbb,0,0,(byte)0xff,(byte)0xff,(byte)0xff,(byte)0xff,1,0});}
    private Protocol.Frame status(int sequence,int volume,int bend,int preset,long tick){byte[] p=new byte[18];p[0]=4;p[10]=(byte)volume;p[11]=(byte)(volume>>8);p[12]=(byte)bend;p[13]=(byte)preset;for(int i=0;i<4;i++)p[14+i]=(byte)(tick>>(8*i));return new Protocol.Frame(Protocol.STATUS,sequence,p);}
    private static final class CaptureLink implements DeviceLink {
        final List<Protocol.Frame> sent=new ArrayList<>();String reason="";
        public void send(byte[] bytes){sent.addAll(new Protocol.Decoder().feed(bytes));}
        public int pending(){return 0;}
        public void disconnect(String message){reason=message;}
        Protocol.Frame last(){return sent.get(sent.size()-1);}
    }
    private static final class QuietUi implements Session.Ui {
        final List<String> messages=new ArrayList<>();
        public void changed(){}public void device(BluetoothDevice device,int rssi){}public void message(String text){messages.add(text);}public void recordingLimit(){}
    }
    private Protocol.Frame parameterEvent(int sequence,int volume,int bend,int preset,long tick){byte[] p=new byte[8];for(int i=0;i<4;i++)p[i]=(byte)(tick>>(8*i));p[4]=(byte)volume;p[5]=(byte)(volume>>8);p[6]=(byte)bend;p[7]=(byte)preset;return new Protocol.Frame(0x84,sequence,p);}
    private Session initialized(CaptureLink link,QuietUi ui){Session s=new Session(ui,link);s.ready=true;s.capabilities=15;return s;}
    private void deviceSyncTests() {
        List<String> failures=new ArrayList<>();
        scenario(failures,"physical practice protocol",()->{
            CaptureLink link=new CaptureLink();
            Session s=new Session(new QuietUi(),link);
            try{
                s.writable();
                s.frame(new Protocol.Frame(Protocol.HELLO_REPLY,link.last().sequence,
                        new byte[]{1,32,(byte)0x8f,(byte)0x80,(byte)0xbb,0,0,-1,-1,-1,-1,2,1}));
                byte[] initial=new byte[18];
                s.frame(new Protocol.Frame(Protocol.STATUS,link.last().sequence,initial));
                s.frame(new Protocol.Frame(Protocol.ACK,link.last().sequence,new byte[]{0x12,0}));
                check(s.supportsPracticeLights(),"new firmware announces phone LED support");
                s.startPractice(Midi.melody(60,60),true);
                check(link.last().type==0x24&&!s.practiceMapped(),"practice requests instrument snapshot");
                byte[] snapshot=new byte[18];snapshot[10]=7;snapshot[12]=100;
                s.frame(new Protocol.Frame(0x89,link.last().sequence,snapshot));
                check(link.last().type==0x25,"practice fetches mapped pitches");
                byte[] pitches={7,0,62,60,64,65,67,69,71,72};
                s.frame(new Protocol.Frame(0x8b,link.last().sequence,pitches));
                check(s.practice.target()==2,"practice follows current physical mapping");
                check(link.last().type==0x2a&&Arrays.equals(link.last().payload,new byte[]{2,7,0}),"practice sends target with mapping revision");
                s.frame(new Protocol.Frame(Protocol.ACK,link.last().sequence,new byte[]{0x2a,0}));
                s.frame(new Protocol.Frame(0x83,10,new byte[]{101,0,0,0,1,1}));
                s.frame(new Protocol.Frame(0x83,11,new byte[]{102,0,0,0,1,0}));
                check(s.practice.step()==0,"queued presses await mapping confirmation");
                try{
                    Field f=Session.class.getDeclaredField("nextPracticePoll");f.setAccessible(true);f.setLong(s,0);
                    f=Session.class.getDeclaredField("heartbeat");f.setAccessible(true);((Runnable)f.get(s)).run();
                }catch(ReflectiveOperationException error){throw new AssertionError(error);}
                s.frame(new Protocol.Frame(0x8b,link.last().sequence,pitches));
                check(s.practice.step()==1,"short physical tap counts even between polls");
                check(link.last().type==0x2a&&link.last().payload[0]==2,"repeated note renews the same target");
                s.frame(new Protocol.Frame(0x83,13,new byte[]{103,0,0,0,1,1}));
                check(s.practice==null,"event gap stops physical judgement");
                check(link.last().type==0x2a&&link.last().payload[0]==0,"stopping practice explicitly clears target");
            }finally{s.close();}
        });
        scenario(failures,"split handshake",()->{CaptureLink link=new CaptureLink();Session s=new Session(new QuietUi(),link);try{s.writable();s.frame(new Protocol.Frame(Protocol.HELLO_REPLY,0,new byte[]{1,4,15,(byte)0x80,(byte)0xbb,0,0,-1,-1,-1,-1,1,1}));check(link.sent.size()==2&&link.last().type==2&&!s.ready,"HELLO only requests STATUS");s.frame(status(99,1,0,0,0));check(link.sent.size()==2,"unsolicited STATUS cannot initialize");s.frame(status(1,42000,-16,2,4800));check(link.last().type==0x12&&link.last().payload.length==4&&Protocol.u32(link.last().payload,0)==0,"split handshake clears keys without writing physical parameters");check(!s.ready&&s.volume==42000&&s.bend==-16&&s.preset==2,"split reads authoritative values before ready");s.frame(new Protocol.Frame(0x80,2,new byte[]{0x13,0}));check(!s.ready,"wrong clear ACK rejected");s.frame(new Protocol.Frame(0x80,2,new byte[]{0x12,0}));check(s.ready,"matching clear ACK finishes handshake");}finally{s.close();}});
        scenario(failures,"split controls",()->{CaptureLink link=new CaptureLink();Session s=initialized(link,new QuietUi());try{s.press("one",31);check(link.last().type==0x12&&Protocol.u32(link.last().payload,0)==0x80000000L,"note sends only key mask");s.parameters(16384,16,0);try{Field f=Session.class.getDeclaredField("paramsSend");f.setAccessible(true);((Runnable)f.get(s)).run();}catch(Exception e){throw new RuntimeException(e);}check(link.last().type==0x13&&Arrays.equals(link.last().payload,new byte[]{2,0,64,16,0}),"bend change sends only bend field");int before=link.sent.size();s.parameters(16384,16,0);check(link.sent.size()==before,"unchanged parameters emit no update");try{Field f=Session.class.getDeclaredField("lastReply");f.setAccessible(true);f.setLong(s,SystemClock.elapsedRealtime());f=Session.class.getDeclaredField("heartbeat");f.setAccessible(true);((Runnable)f.get(s)).run();}catch(Exception e){throw new RuntimeException(e);}check(link.last().type==0x12,"heartbeat cannot overwrite encoder parameters");}finally{s.close();}});
        scenario(failures,"authoritative events",()->{CaptureLink link=new CaptureLink();QuietUi ui=new QuietUi();Session s=initialized(link,ui);try{s.startRecording();s.frame(status(33,60000,-31,2,4800));check(s.volume==60000&&s.bend==-31&&s.preset==2,"STATUS updates all actual parameters");s.frame(new Protocol.Frame(0x83,65535,new byte[]{(byte)0xc0,0x12,0,0,1,1}));s.frame(parameterEvent(0,61000,-32,1,4848));check(s.volume==61000&&s.bend==-32&&s.preset==1,"PARAM_EVENT updates actual parameters");s.frame(new Protocol.Frame(0x83,1,new byte[]{0x20,0x13,0,0,1,0}));Library.Recording rec=s.stopRecording();check(rec.complete&&rec.events.stream().filter(e->e.type.equals("params")).count()==2,"shared key and parameter event sequence wraps without false gap; STATUS is not synthetic parameter history");check(link.sent.isEmpty(),"authoritative notifications never feed back commands");try{Library.Recording.parse(rec.json());}catch(Exception e){throw new RuntimeException(e);}s.startRecording();s.frame(parameterEvent(3,62000,0,0,4896));check(!s.stopRecording().complete&&!ui.messages.isEmpty(),"parameter event gap marks recording incomplete");}finally{s.close();}});
        scenario(failures,"pending parameter edits",()->{CaptureLink link=new CaptureLink();Session s=initialized(link,new QuietUi());try{s.parameters(22000,0,0);s.frame(parameterEvent(0,20000,-8,1,100));check(s.volume==22000&&s.bend==-8&&s.preset==1,"dirty volume survives device event while untouched fields synchronize");try{Field f=Session.class.getDeclaredField("paramsSend");f.setAccessible(true);((Runnable)f.get(s)).run();}catch(Exception e){throw new RuntimeException(e);}Protocol.Frame update=link.last();check(update.type==0x13&&(update.payload[0]&255)==1,"only explicit phone volume field sent");s.parameters(23000,-8,1);s.frame(new Protocol.Frame(0x80,update.sequence,new byte[]{0x13,0}));check(s.volume==23000,"old ACK cannot overwrite newer local edit");check(link.last().type==2,"parameter ACK requests actual state to resolve physical arbitration");s.frame(status(link.last().sequence,22000,-4,2,101));check(s.volume==23000&&s.bend==-4&&s.preset==2,"readback preserves next local edit and synchronizes other fields");}finally{s.close();}});
        scenario(failures,"actual recording baseline",()->{CaptureLink link=new CaptureLink();Session s=initialized(link,new QuietUi());try{s.frame(status(40,40000,-2,1,100));s.parameters(41000,-2,1);s.startRecording();Library.Recording rec=s.stopRecording();check(rec.events.get(0).a==40000,"connected recording begins with last actual device value, not unsent UI edit");}finally{s.close();}});
        scenario(failures,"handshake notification race",()->{CaptureLink link=new CaptureLink();Session s=new Session(new QuietUi(),link);try{s.writable();s.frame(new Protocol.Frame(0x81,0,new byte[]{1,4,15,(byte)0x80,(byte)0xbb,0,0,-1,-1,-1,-1,1,1}));s.frame(status(1,40000,0,0,100));s.frame(parameterEvent(8,43000,8,2,101));s.frame(new Protocol.Frame(0x83,9,new byte[]{101,0,0,0,1,1}));s.frame(new Protocol.Frame(0x80,2,new byte[]{0x12,0}));check(s.ready&&s.volume==43000&&s.bend==8&&s.preset==2,"notifications during remote clear preserve newest physical parameters");s.startRecording();Library.Recording rec=s.stopRecording();check(rec.events.stream().anyMatch(e->e.type.equals("note")&&e.a==62&&e.b==1),"physical note arriving during handshake is available to recording");}finally{s.close();}});
        scenario(failures,"snapshot overtakes queued events",()->{CaptureLink link=new CaptureLink();Session s=initialized(link,new QuietUi());try{s.frame(status(50,40000,0,0,100));s.startRecording();s.frame(new Protocol.Frame(0x83,20,new byte[]{99,0,0,0,1,1}));s.frame(new Protocol.Frame(0x83,21,new byte[]{100,0,0,0,1,0}));Library.Recording rec=s.stopRecording();check(rec.events.stream().noneMatch(e->e.type.equals("note")),"old queued key events cannot resurrect notes covered by newer snapshot");s.startRecording();s.frame(parameterEvent(22,40000,8,1,101));check(s.stopRecording().complete,"discarded old key state still participates in shared event sequence");}finally{s.close();}});
        scenario(failures,"stale snapshot after fresh event",()->{CaptureLink link=new CaptureLink();Session s=initialized(link,new QuietUi());try{s.frame(status(40,40000,0,0,100));s.frame(new Protocol.Frame(0x83,0,new byte[]{110,0,0,0,1,1}));s.frame(status(41,39000,0,0,105));s.startRecording();Library.Recording rec=s.stopRecording();check(rec.events.stream().anyMatch(e->e.type.equals("note")&&e.a==62&&e.b==1),"older STATUS cannot undo newer physical key event");}finally{s.close();}});
        scenario(failures,"delayed history after future snapshot",()->{CaptureLink link=new CaptureLink();Session s=initialized(link,new QuietUi());try{s.frame(status(40,16384,0,0,0));s.startRecording();s.frame(status(41,30000,8,2,1096));s.frame(new Protocol.Frame(0x83,10,new byte[]{(byte)0xe8,3,0,0,1,1}));s.frame(new Protocol.Frame(0x83,11,new byte[]{24,4,0,0,1,0}));s.frame(parameterEvent(12,20000,4,1,1000));s.frame(parameterEvent(13,30000,8,2,1048));Library.Recording rec=s.stopRecording();check(rec.events.stream().filter(e->e.type.equals("note")).count()==2,"future STATUS must not erase delayed note-on/off history");List<Library.Entry> params=new ArrayList<>();for(Library.Entry e:rec.events)if(e.type.equals("params"))params.add(e);check(params.size()==3&&params.stream().anyMatch(e->e.a==20000)&&params.stream().anyMatch(e->e.a==30000),"actual parameter stream preserves intermediate history without synthetic STATUS entries");check(rec.complete&&s.volume==30000,"delayed history leaves live state and completeness intact");}finally{s.close();}});
        scenario(failures,"snapshot and held baseline dedup",()->{CaptureLink link=new CaptureLink();Session s=initialized(link,new QuietUi());try{Protocol.Frame initial=status(40,16384,0,0,100);initial.payload[6]=2;s.frame(initial);s.startRecording();s.frame(new Protocol.Frame(0x83,10,new byte[]{99,0,0,0,1,1}));s.frame(parameterEvent(11,16384,0,0,99));Library.Recording rec=s.stopRecording();check(rec.events.stream().filter(e->e.type.equals("note")&&e.b!=0).count()==1,"pre-start queued event cannot duplicate held baseline");check(rec.events.stream().filter(e->e.type.equals("params")).count()==1,"pre-start parameter event cannot duplicate parameter baseline");}finally{s.close();}});
        scenario(failures,"pre-start queued release corrects old baseline",()->{CaptureLink link=new CaptureLink();Session s=initialized(link,new QuietUi());try{Protocol.Frame initial=status(40,16384,0,0,100);initial.payload[6]=2;s.frame(initial);try{Field f=Session.class.getDeclaredField("eventAnchorMs");f.setAccessible(true);f.setLong(s,SystemClock.elapsedRealtime()-100);}catch(Exception e){throw new RuntimeException(e);}s.startRecording();s.frame(new Protocol.Frame(0x83,10,new byte[]{101,0,0,0,1,0}));Library.Recording rec=s.stopRecording();check(rec.events.stream().noneMatch(e->e.type.equals("note")),"release before record boundary removes outdated held baseline without synthetic note");}finally{s.close();}});
        scenario(failures,"recording while fault latched",()->{CaptureLink link=new CaptureLink();Session s=initialized(link,new QuietUi());try{Protocol.Frame faulty=status(40,16384,0,0,100);faulty.payload[1]=2;s.frame(faulty);s.startRecording();check(!s.stopRecording().complete,"new recording cannot hide already latched device fault");s.frame(status(41,16384,0,0,101));s.startRecording();check(s.stopRecording().complete,"fresh zero-fault STATUS restores recording baseline");}finally{s.close();}});
        scenario(failures,"handshake timeout rejects late ACK",()->{CaptureLink link=new CaptureLink();Session s=new Session(new QuietUi(),link);try{s.writable();s.frame(new Protocol.Frame(0x81,0,new byte[]{1,4,15,(byte)0x80,(byte)0xbb,0,0,-1,-1,-1,-1,1,1}));s.frame(status(1,16384,0,0,0));try{Field f=Session.class.getDeclaredField("handshakeTimeout");f.setAccessible(true);((Runnable)f.get(s)).run();}catch(Exception e){throw new RuntimeException(e);}check(!link.reason.isEmpty(),"handshake deadline disconnects transport");s.frame(new Protocol.Frame(0x80,2,new byte[]{0x12,0}));check(!s.ready,"late clear ACK cannot resurrect expired handshake");}finally{s.close();}});
        scenario(failures,"clear ACK watchdog before ready",()->{CaptureLink link=new CaptureLink();Session s=new Session(new QuietUi(),link);try{s.writable();s.frame(new Protocol.Frame(0x81,0,new byte[]{1,4,15,(byte)0x80,(byte)0xbb,0,0,-1,-1,-1,-1,1,1}));s.frame(status(1,16384,0,0,0));try{Field f=Session.class.getDeclaredField("pending");f.setAccessible(true);Object request=((Map<?,?>)f.get(s)).get(2);f=request.getClass().getDeclaredField("time");f.setAccessible(true);f.setLong(request,SystemClock.elapsedRealtime()-2100);f=Session.class.getDeclaredField("heartbeat");f.setAccessible(true);((Runnable)f.get(s)).run();}catch(Exception e){throw new RuntimeException(e);}check(!link.reason.isEmpty(),"clear ACK expires after two seconds before ready");s.frame(new Protocol.Frame(0x80,2,new byte[]{0x12,0}));check(!s.ready,"expired clear request removed from pending state");}finally{s.close();}});
        scenario(failures,"same-frame pre-start chord baseline",()->{CaptureLink link=new CaptureLink();Session s=initialized(link,new QuietUi());try{s.frame(status(40,16384,0,0,100));try{Field f=Session.class.getDeclaredField("eventAnchorMs");f.setAccessible(true);f.setLong(s,SystemClock.elapsedRealtime()-100);}catch(Exception e){throw new RuntimeException(e);}s.startRecording();s.frame(new Protocol.Frame(0x83,10,new byte[]{101,0,0,0,1,1}));s.frame(new Protocol.Frame(0x83,11,new byte[]{101,0,0,0,2,1}));Library.Recording rec=s.stopRecording();check(rec.events.stream().filter(e->e.type.equals("note")&&e.b==1).count()==2,"all keys in same-frame queued pre-start chord update baseline");}finally{s.close();}});
        scenario(failures,"shared sequence history deduplication",()->{CaptureLink link=new CaptureLink();Session s=initialized(link,new QuietUi());try{s.frame(status(40,16384,0,0,0));s.startRecording();s.frame(parameterEvent(10,20000,0,0,1000));s.frame(parameterEvent(11,30000,0,0,1048));s.frame(parameterEvent(10,20000,0,0,1000));Library.Recording rec=s.stopRecording();check(rec.complete&&rec.events.stream().filter(e->e.type.equals("params")).count()==3,"already consumed event sequence cannot duplicate history or create false gap");}finally{s.close();}});
        if(!failures.isEmpty())throw new AssertionError(String.join("\n",failures));
    }
    private void scenario(List<String> failures,String name,Runnable action){try{ui(action);}catch(Throwable e){failures.add(name+": "+e);}}
    private void ui(Runnable action){final Throwable[] error={null};runOnMainSync(()->{try{action.run();}catch(Throwable e){error[0]=e;}});if(error[0]!=null)throw new AssertionError(error[0]);waitForIdleSync();}
    private Session state()throws Exception{Field f=MainActivity.class.getDeclaredField("session");f.setAccessible(true);return(Session)f.get(activity);}
    private TextView find(String label){return search(activity.findViewById(android.R.id.content),label);}
    private TextView search(View view,String label){if(view instanceof TextView&&((TextView)view).getText().toString().equals(label))return(TextView)view;if(view instanceof ViewGroup){ViewGroup group=(ViewGroup)view;for(int i=0;i<group.getChildCount();i++){TextView child=search(group.getChildAt(i),label);if(child!=null)return child;}}return null;}
    private void click(String label){TextView view=find(label);check(view!=null,"control exists: "+label);check(view.performClick(),"control acts: "+label);}
    private void touch(PadView pad,int action,int count){MotionEvent.PointerProperties[] props=new MotionEvent.PointerProperties[count];MotionEvent.PointerCoords[] coords=new MotionEvent.PointerCoords[count];for(int i=0;i<count;i++){props[i]=new MotionEvent.PointerProperties();props[i].id=i;props[i].toolType=MotionEvent.TOOL_TYPE_FINGER;coords[i]=new MotionEvent.PointerCoords();coords[i].x=pad.getWidth()*(i==0?0.125f:0.625f);coords[i].y=pad.getHeight()*0.25f;coords[i].pressure=1;coords[i].size=1;}long now=SystemClock.uptimeMillis();MotionEvent event=MotionEvent.obtain(now,now,action,count,props,coords,0,0,1,1,0,0,android.view.InputDevice.SOURCE_TOUCHSCREEN,0);pad.onTouchEvent(event);event.recycle();}
}

