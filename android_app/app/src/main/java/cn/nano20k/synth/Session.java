package cn.nano20k.synth;

import android.bluetooth.BluetoothDevice;
import android.os.*;
import cn.nano20k.synth.core.*;
import java.util.*;

/** Main-thread state owner; phone MIDI never substitutes for FPGA audio synthesis. */
public final class Session implements BleTransport.Listener {
    public interface Ui{void changed();void device(BluetoothDevice device,int rssi);void message(String text);void recordingLimit();}
    private final Handler h=new Handler(Looper.getMainLooper());private final Ui ui;
    private final DeviceLink link;
    public BleTransport ble;public boolean ready,demo,recording,playing;public String status="未连接设备",firmware="等待协议 v1 固件",recordSource="";
    public int volume=16384,bend=0,preset=0,voices=4,capabilities=0;public long supported=0xffffffffL;
    public int[] mapping={0,1,2,3,4,5,6,7};
    private final Notes notes=new Notes();private int sequence;private long lastReply;
    private static final class Pending {final int type,parameterMask;final long time;Pending(int type,long time,int parameterMask){this.type=type;this.time=time;this.parameterMask=parameterMask;}}
    private final Map<Integer,Pending> pending=new HashMap<>();private final List<Library.Entry> captured=new ArrayList<>();
    private long recordStart,physicalMask,eventAnchorTick,eventAnchorMs;private int eventSequence=-1;private boolean complete=true;
    private int dirtyParameters,parameterSequence=-1,deviceVolume=16384,deviceBend,devicePreset;private long parameterTick;private boolean haveParameterTick,haveEventAnchor;
    private long physicalSnapshotTick,physicalStateTick;private boolean havePhysicalSnapshot,havePhysicalState;
    private int faultFlags;private long handshakeDeadline;
    // STATUS may overtake queued events: live snapshots must never erase recording history.
    private long recordBoundaryTick,recordPhysicalMask,recordBaselineParameterTick;private boolean haveRecordBoundary;
    private final long[] recordBaselinePhysicalTicks=new long[32];
    private int recordVolume,recordBend,recordPreset;private Library.Entry initialParameters;
    private final Library.Entry[] physicalBaselines=new Library.Entry[32];
    private Runnable playback,paramsSend,handshakeTimeout;private int handshakeSequence=-1,initialStatusSequence=-1,clearSequence=-1;private int playbackIndex;private List<Library.Entry> score;
    private long playStart;private final Map<Integer,ArrayDeque<String>> scoreOwners=new HashMap<>();private int ownerCounter;
    private static final int GET_PERFORMANCE=0x24, GET_KEY_PITCHES=0x25, SET_PRACTICE_LIGHTS=0x2a,
            PERFORMANCE=0x89, KEY_PITCHES=0x8b;
    private static final int PRACTICE_LIGHTS_FIRMWARE=0x0102;
    public Practice practice;
    public boolean physicalPractice;
    public String practiceMessage="";
    private int practiceRequest=-1, practiceReply, practiceRevision, practiceHeld;
    private long practiceDeadline, practiceTick, nextPracticePoll;
    private boolean practiceMapped, practiceLightsClaimed;
    private int firmwareVersion;
    private final List<Protocol.Frame> practiceEvents=new ArrayList<>();
    private final List<Protocol.Frame> practiceBatch=new ArrayList<>();
    public Session(Ui ui){this(ui,null);}
    public Session(Ui ui,DeviceLink link){this.ui=ui;this.link=link;h.postDelayed(heartbeat,200);}
    private DeviceLink transport(){return link!=null?link:ble;}
    public long mask(){return notes.mask();}
    public boolean supportsPhysicalPractice(){return ready&&(capabilities&0x84)==0x84;}
    public boolean supportsPracticeLights(){return supportsPhysicalPractice()&&firmwareVersion>=PRACTICE_LIGHTS_FIRMWARE;}
    public void startPractice(Midi.Song song,boolean physical){
        if(physical&&!supportsPhysicalPractice()){ui.message("请先连接 Beatit 的演奏固件");return;}
        Practice next;
        try{next=new Practice(song);}catch(IllegalArgumentException e){ui.message(e.getMessage());return;}
        panic();
        practice=next;physicalPractice=physical;
        practiceMessage=physical?"正在读取琴键音高…":"按亮起的键，松开后进入下一步";
        if(physical) requestPractice(GET_PERFORMANCE,PERFORMANCE);
        ui.changed();
    }
    public void stopPractice(String message){
        if(practiceLightsClaimed&&ready)command(SET_PRACTICE_LIGHTS,new byte[3],false);
        practiceLightsClaimed=false;
        practice=null;physicalPractice=false;practiceMapped=false;practiceRequest=-1;
        practiceEvents.clear();practiceBatch.clear();practiceMessage=message;ui.changed();
    }
    public boolean practiceMapped(){return !physicalPractice||practiceMapped;}
    private void requestPractice(int command,int reply){
        requestPractice(command,reply,new byte[0]);
    }
    private void requestPractice(int command,int reply,byte[] payload){
        practiceReply=reply;
        practiceDeadline=SystemClock.elapsedRealtime()+2000;
        practiceRequest=command(command,payload,false);
    }
    private void practiceFrame(Protocol.Frame frame){
        byte[] p=frame.payload;
        if(practiceReply==Protocol.ACK){
            if(frame.type!=Protocol.ACK||p.length!=2||(p[0]&255)!=SET_PRACTICE_LIGHTS)return;
            practiceRequest=-1;
            if(p[1]!=0)stopPractice("琴键灯暂不可用，请退出琴体设置或内置练习，检查键灯后重试");
            return;
        }
        if(frame.type==Protocol.ACK&&p.length==2&&(p[1]&255)!=0){
            stopPractice("设备暂时无法提供琴键状态");return;
        }
        if(frame.type!=practiceReply)return;
        if(frame.type==PERFORMANCE){
            if(p.length!=18)return;
            if((p[4]&1)!=0){stopPractice("请退出琴体设置，再开始练习");return;}
            if((p[3]&255)==4&&practice.hasChords()){stopPractice("此曲含和弦，请在琴体选择复音音色");return;}
            practiceHeld=p[7]&255;practiceRevision=Protocol.u16(p,10);practiceTick=Protocol.u32(p,12);
            requestPractice(GET_KEY_PITCHES,KEY_PITCHES);return;
        }
        if(p.length!=10)return;
        practiceRequest=-1;
        int revision=Protocol.u16(p,0);
        if(revision!=practiceRevision){stopPractice("琴体设置已改变，请重新开始练习");return;}
        if(!practiceMapped){
            int[] keys=new int[8];
            for(int i=0;i<8;i++){
                keys[i]=p[2+i]&255;
                if(keys[i]>127){stopPractice("琴键音高回传无效");return;}
            }
            try{practice.reset(keys,practiceHeld);}
            catch(IllegalArgumentException e){stopPractice(e.getMessage()+"。可调整琴体调性或使用手机练习");return;}
            practiceMapped=true;practiceMessage="按提示弹实体键，松开后进入下一步";
        }
        for(Protocol.Frame event:practiceBatch) practice.input(event.payload[4]&255,event.payload[5]!=0);
        practiceBatch.clear();
        nextPracticePoll=SystemClock.elapsedRealtime()+100;
        if(supportsPracticeLights()){
            int target=practice.target();
            practiceLightsClaimed=target!=0;
            requestPractice(SET_PRACTICE_LIGHTS,Protocol.ACK,
                    new byte[]{(byte)target,(byte)practiceRevision,(byte)(practiceRevision>>8)});
        }
        ui.changed();
    }
    private void practiceEvent(Protocol.Frame frame,long tick){
        if(practice==null||!physicalPractice||practice.done()
                ||(!practiceMapped&&practiceReply==PERFORMANCE)||(int)(tick-practiceTick)<=0)return;
        if(practiceEvents.size()>=64){stopPractice("按键回传积压，请重新开始练习");return;}
        practiceEvents.add(frame);
    }
    public boolean usable(){return ready||demo;}
    public void demo(boolean enabled){panic();if(enabled)transport().disconnect("演示模式 · 不输出声音");demo=enabled;ready=false;status=enabled?"演示模式 · 不输出声音":"未连接设备";ui.changed();}
    public void press(String owner,int key){if(!usable())return;if(ready&&(supported&(1L<<key))==0){ui.message("固件不支持 "+Notes.label(key));return;}long before=mask();notes.press(owner,key);notesChanged(before);}
    public void release(String owner){long before=mask();notes.release(owner);notesChanged(before);}
    private void notesChanged(long before){long after=mask();if(before==after)return;captureMasks(before,after,"手机演奏");sendState();ui.changed();}
    public void parameters(int v,int b,int p){Protocol.state(0,v,b,p);int changed=(v!=volume?1:0)|(b!=bend?2:0)|(p!=preset?4:0);if(changed==0)return;volume=v;bend=b;preset=p;if(ready){dirtyParameters|=changed;scheduleParameters();}else if(demo&&recording)append(new Library.Entry(elapsed(),"params",v,b,p));ui.changed();}
    private void scheduleParameters(){if(paramsSend!=null)h.removeCallbacks(paramsSend);paramsSend=this::sendParameters;h.postDelayed(paramsSend,50);}
    private void sendParameters(){if(!ready||dirtyParameters==0||parameterSequence>=0)return;int fields=dirtyParameters;dirtyParameters=0;if((capabilities&Protocol.CAP_SPLIT)!=0){byte[] payload={(byte)fields,(byte)volume,(byte)(volume>>8),(byte)bend,(byte)preset};parameterSequence=command(Protocol.SET_PARAMS,payload,true,fields);}else parameterSequence=command(Protocol.SET_STATE,Protocol.state(mask(),volume,bend,preset),true,7);}
    private void append(Library.Entry entry){if(captured.size()>=Midi.MAX_EVENTS-64){complete=false;stopRecordNotice();return;}captured.add(entry);}
    private void stopRecordNotice(){if(recording)ui.recordingLimit();}
    private long elapsed(){return Math.min(Midi.MAX_MS,SystemClock.elapsedRealtime()-recordStart);}
    private void captureMasks(long before,long after,String source){if(!recording)return;long now=elapsed();for(int key=0;key<32;key++)if(((before^after)&(1L<<key))!=0)append(new Library.Entry(now,"note",Notes.midiForKey(key),(after&(1L<<key))!=0?1:0,0));}
    private void sendState(){if(!ready)return;if((capabilities&Protocol.CAP_SPLIT)!=0)command(Protocol.SET_KEYS,keyPayload(mask()),true);else command(Protocol.SET_STATE,Protocol.state(mask(),volume,bend,preset),true);}
    private static byte[] keyPayload(long mask){byte[] p=new byte[4];for(int i=0;i<4;i++)p[i]=(byte)(mask>>(8*i));return p;}
    private int command(int type,byte[] payload,boolean ack){return command(type,payload,ack,0);}
    private int command(int type,byte[] payload,boolean ack,int fields){int seq=sequence++&65535;if(ack)pending.put(seq,new Pending(type,SystemClock.elapsedRealtime(),fields));transport().send(Protocol.encode(type,seq,payload));return seq;}
    public void applyMapping(int[] keys){panic();mapping=keys.clone();if(ready&&(capabilities&2)!=0){byte[] p=new byte[8];for(int i=0;i<8;i++)p[i]=(byte)keys[i];command(Protocol.SET_MAP,p,true);}ui.changed();}
    public void panic(){
        if(practice!=null)stopPractice("练习已结束");
        if(playback!=null)h.removeCallbacks(playback);playing=false;scoreOwners.clear();long before=mask();notes.clear();captureMasks(before,0,"手机演奏");sendState();ui.changed();
    }
    public void startRecording(){
        captured.clear();Arrays.fill(physicalBaselines,null);recordStart=SystemClock.elapsedRealtime();recording=true;complete=!(ready&&faultFlags!=0);recordSource=demo?"演示事件（无声音）":"手机事件";
        if(ready&&(capabilities&4)!=0)recordSource+=" + FPGA 实体按键回传";
        else if(ready)recordSource+=" + FPGA 实体状态快照";
        if(ready&&(capabilities&Protocol.CAP_SPLIT)!=0)recordSource+=" + FPGA 实际参数回传";
        recordVolume=ready&&haveParameterTick?deviceVolume:volume;recordBend=ready&&haveParameterTick?deviceBend:bend;recordPreset=ready&&haveParameterTick?devicePreset:preset;
        initialParameters=new Library.Entry(0,"params",recordVolume,recordBend,recordPreset);captured.add(initialParameters);captureMasks(0,mask(),recordSource);
        haveRecordBoundary=ready&&haveEventAnchor;recordBoundaryTick=(eventAnchorTick+(recordStart-eventAnchorMs)*48)&0xffffffffL;
        Arrays.fill(recordBaselinePhysicalTicks,physicalStateTick);recordBaselineParameterTick=parameterTick;recordPhysicalMask=ready?physicalMask:0;
        for(int key=0;key<32;key++)if((recordPhysicalMask&(1L<<key))!=0){physicalBaselines[key]=new Library.Entry(0,"note",Notes.midiForKey(key),1,0);captured.add(physicalBaselines[key]);}ui.changed();
    }
    public Library.Recording stopRecording(){
        if(!recording)return null;
        // Close event notes in the saved timeline without interrupting held hardware keys.
        long duration=elapsed();Map<Integer,Integer> active=new HashMap<>();
        for(Library.Entry e:captured)if(e.type.equals("note"))active.merge(e.a,e.b!=0?1:-1,Integer::sum);
        for(Map.Entry<Integer,Integer> e:active.entrySet())for(int i=0;i<Math.max(0,e.getValue());i++)captured.add(new Library.Entry(duration,"note",e.getKey(),0,0));
        captured.sort(Comparator.comparingLong(e->e.ms));
        recording=false;ui.changed();return new Library.Recording("演奏 "+new java.text.SimpleDateFormat("MM-dd HH:mm",Locale.CHINA).format(new Date()),recordSource,captured,duration,complete);
    }
    public void play(Midi.Song song){List<Library.Entry> events=new ArrayList<>();for(Midi.Event e:song.events)events.add(new Library.Entry(e.ms,"note",e.note,e.down?1:0,e.channel));play(events,song.durationMs);}
    public void play(List<Library.Entry> events,long duration){
        if(!usable()){ui.message("先连接固件，或开启演示模式");return;}
        if(recording){ui.message("先停止事件记录，再回放");return;}
        for(Library.Entry e:events)if(e.type.equals("note")){int key=Notes.keyForMidi(e.a);if(key<0||(ready&&(supported&(1L<<key))==0)){ui.message("音高 MIDI "+e.a+" 不在固件频率表中，无法发送");return;}}
        panic();score=new ArrayList<>(events);playbackIndex=0;playStart=SystemClock.elapsedRealtime();playing=true;
        playback=new Runnable(){public void run(){if(!playing)return;long now=SystemClock.elapsedRealtime()-playStart;
            while(playing&&playbackIndex<score.size()&&score.get(playbackIndex).ms<=now){Library.Entry e=score.get(playbackIndex++);if(e.type.equals("params")){parameters(e.a,e.b,e.c);}else{int token=(e.c<<8)|e.a;ArrayDeque<String> q=scoreOwners.computeIfAbsent(token,k->new ArrayDeque<>());if(e.b!=0){String owner="score"+(ownerCounter++);q.add(owner);press(owner,Notes.keyForMidi(e.a));}else if(!q.isEmpty())release(q.remove());}}
            if(!playing)return;
            ui.changed();if(playbackIndex<score.size())h.postDelayed(this,Math.max(1,score.get(playbackIndex).ms-now));else if(now<duration)h.postDelayed(this,duration-now);else panic();}};h.post(playback);ui.changed();
    }
    public long playElapsed(){return playing?SystemClock.elapsedRealtime()-playStart:0;}
    private final Runnable heartbeat=new Runnable(){public void run(){
        long now=SystemClock.elapsedRealtime();boolean expired=false;for(Pending request:pending.values())if(now-request.time>2000){expired=true;break;}
        if(expired||(ready&&now-lastReply>3000)){failConnection("FPGA 响应超时，已停止手机音符");}
        else if(!ready&&handshakeDeadline!=0&&now>=handshakeDeadline){failConnection("FPGA 握手超时，请重新连接");}
        else if(ready&&transport().pending()==0&&pending.size()<4){
            sendState();
            if(physicalPractice&&practiceMapped&&!practice.done()&&practiceRequest<0&&now>=nextPracticePoll){
                practiceBatch.addAll(practiceEvents);practiceEvents.clear();
                requestPractice(GET_KEY_PITCHES,KEY_PITCHES);
            }
        }
        if(physicalPractice&&practiceRequest>=0&&now>=practiceDeadline)stopPractice("琴键状态读取超时，请重新开始");
        if(recording&&elapsed()>=Midi.MAX_MS){complete=false;stopRecordNotice();}
        h.postDelayed(this,200);}};
    @Override public void status(String text,boolean connected){status=text;if(!connected){if(handshakeTimeout!=null)h.removeCallbacks(handshakeTimeout);if(paramsSend!=null)h.removeCallbacks(paramsSend);handshakeSequence=initialStatusSequence=clearSequence=parameterSequence=-1;handshakeDeadline=0;dirtyParameters=0;boolean wasReady=ready;ready=false;pending.clear();if(wasReady&&recording)complete=false;panic();physicalMask=0;}ui.changed();}
    @Override public void discovered(BluetoothDevice device,int rssi){ui.device(device,rssi);}
    @Override public void writable(){demo=false;ready=false;pending.clear();dirtyParameters=0;parameterSequence=initialStatusSequence=clearSequence=-1;haveParameterTick=haveEventAnchor=havePhysicalSnapshot=havePhysicalState=false;if(paramsSend!=null)h.removeCallbacks(paramsSend);if(handshakeTimeout!=null)h.removeCallbacks(handshakeTimeout);handshakeDeadline=SystemClock.elapsedRealtime()+2500;handshakeSequence=command(Protocol.HELLO,new byte[0],false);handshakeTimeout=()->{if(!ready&&handshakeDeadline!=0)failConnection("FPGA 握手超时，请重新连接");};h.postDelayed(handshakeTimeout,2500);}
    @Override public void frame(Protocol.Frame f){
        if(!ready&&handshakeDeadline!=0&&SystemClock.elapsedRealtime()>=handshakeDeadline){failConnection("FPGA 握手超时，请重新连接");return;}
        byte[] p=f.payload;
        if(physicalPractice&&f.sequence==practiceRequest
                &&(f.type==practiceReply||f.type==Protocol.ACK)){
            practiceFrame(f);return;
        }
        if(f.type==Protocol.HELLO_REPLY){if(handshakeSequence<0||f.sequence!=handshakeSequence)return;if(p.length!=13||p[0]!=1||(p[2]&1)==0||Protocol.u32(p,3)!=48000||(p[1]&255)<1||Protocol.u32(p,7)==0){status="固件协议 / 采样率不匹配";ui.changed();return;}
            handshakeSequence=-1;
            voices=p[1]&255;capabilities=p[2]&255;supported=Protocol.u32(p,7);firmwareVersion=Protocol.u16(p,11);firmware="协议 v1 · "+voices+" 复音 · 48 kHz · 固件 "+firmwareVersion;lastReply=SystemClock.elapsedRealtime();eventSequence=-1;status="读取 FPGA 参数…";initialStatusSequence=command(Protocol.STATUS_REQUEST,new byte[0],false);ui.changed();}
        else if(f.type==Protocol.ACK&&p.length==2){Pending request=pending.get(f.sequence);if(request!=null&&request.type==(p[0]&255)){if(SystemClock.elapsedRealtime()-request.time>2000){failConnection("FPGA 响应超时，已停止手机音符");return;}pending.remove(f.sequence);lastReply=SystemClock.elapsedRealtime();if(p[1]!=0){ui.message("FPGA 拒绝命令（状态 "+(p[1]&255)+"）");failConnection("固件命令被拒绝");}else if(f.sequence==clearSequence){clearSequence=-1;handshakeDeadline=0;ready=true;if(handshakeTimeout!=null)h.removeCallbacks(handshakeTimeout);status=faultFlags==0?"FPGA 已就绪":"FPGA 故障标志："+faultFlags;ui.changed();}else if(f.sequence==parameterSequence){parameterSequence=-1;command(Protocol.STATUS_REQUEST,new byte[0],false);if(dirtyParameters!=0)scheduleParameters();}}}
        else if(f.type==Protocol.STATUS&&p.length==18&&f.sequence==initialStatusSequence&&initialStatusSequence>=0){if(!validParameters(p[12],p[13]&255)||(p[0]&255)>voices)return;initialStatusSequence=-1;receiveParameters(Protocol.u32(p,14),Protocol.u16(p,10),p[12],p[13]&255);receivePhysicalSnapshot(Protocol.u32(p,14),Protocol.u32(p,6));notes.clear();clearSequence=(capabilities&Protocol.CAP_SPLIT)!=0?command(Protocol.SET_KEYS,keyPayload(0),true):command(Protocol.SET_STATE,Protocol.state(0,volume,bend,preset),true);fault(p[1]&255);ui.changed();}
        else if(f.type==Protocol.STATUS&&p.length==18&&ready){if(!validParameters(p[12],p[13]&255)||(p[0]&255)>voices)return;lastReply=SystemClock.elapsedRealtime();receivePhysicalSnapshot(Protocol.u32(p,14),Protocol.u32(p,6));receiveParameters(Protocol.u32(p,14),Protocol.u16(p,10),p[12],p[13]&255);fault(p[1]&255);ui.changed();}
        else if(f.type==Protocol.EVENT&&p.length==6&&(ready||clearSequence>=0)&&(capabilities&4)!=0){int key=p[4]&255,down=p[5]&255;if(key>=32||down>1)return;
            long tick=Protocol.u32(p,0);if(!event(f.sequence,tick))return;practiceEvent(f,tick);lastReply=SystemClock.elapsedRealtime();recordPhysicalEvent(tick,key,down);if((havePhysicalSnapshot&&(int)(tick-physicalSnapshotTick)<=0)||(havePhysicalState&&(int)(tick-physicalStateTick)<0))return;physicalStateTick=tick;havePhysicalState=true;
            long bit=1L<<key;long old=physicalMask;physicalMask=down!=0?old|bit:old&~bit;
            lastReply=SystemClock.elapsedRealtime();ui.changed();}
        else if(f.type==Protocol.PARAM_EVENT&&p.length==8&&(ready||clearSequence>=0)&&(capabilities&Protocol.CAP_SPLIT)!=0){if(!validParameters(p[6],p[7]&255))return;long tick=Protocol.u32(p,0);if(!event(f.sequence,tick))return;recordParameterEvent(tick,Protocol.u16(p,4),p[6],p[7]&255);receiveParameters(tick,Protocol.u16(p,4),p[6],p[7]&255);lastReply=SystemClock.elapsedRealtime();ui.changed();}
    }
    private static boolean validParameters(int bend,int preset){return bend>=-32&&bend<=32&&preset<=2;}
    private void fault(int flags){int before=faultFlags;faultFlags=flags;if(flags!=0){complete=false;status="FPGA 故障标志："+flags;if(physicalPractice)stopPractice("设备报告故障，请检查连接后重练");}else if(before!=0&&ready)status="FPGA 已就绪";}
    private void failConnection(String reason){status(reason,false);transport().disconnect(reason);}
    private boolean event(int seq,long tick){if(eventSequence>=0){int forward=(seq-eventSequence)&65535;if(forward==0||forward>32768)return false;if(forward!=1){complete=false;if(physicalPractice)stopPractice("按键回传有缺失，请重新开始练习");if(recording)ui.message("FPGA 事件回传有缺失，记录已标记不完整");}}eventSequence=seq;anchor(tick);return true;}
    private void anchor(long tick){if(!haveEventAnchor){haveEventAnchor=true;eventAnchorTick=tick;eventAnchorMs=SystemClock.elapsedRealtime();}}
    private long deviceTime(long tick){anchor(tick);return Math.max(0,Math.min(elapsed(),eventAnchorMs+(int)(tick-eventAnchorTick)/48-recordStart));}
    private void receiveParameters(long tick,int v,int b,int p){if(haveParameterTick&&(int)(tick-parameterTick)<0)return;boolean changed=!haveParameterTick||deviceVolume!=v||deviceBend!=b||devicePreset!=p;parameterTick=tick;haveParameterTick=true;deviceVolume=v;deviceBend=b;devicePreset=p;int protectedFields=dirtyParameters;for(Pending request:pending.values())protectedFields|=request.parameterMask;if((protectedFields&1)==0)volume=v;if((protectedFields&2)==0)bend=b;if((protectedFields&4)==0)preset=p;if(recording&&changed&&(capabilities&Protocol.CAP_SPLIT)==0)append(new Library.Entry(deviceTime(tick),"params",v,b,p));anchor(tick);}
    private void receivePhysicalSnapshot(long tick,long mask){if(havePhysicalState&&(int)(tick-physicalStateTick)<0)return;physicalStateTick=physicalSnapshotTick=tick;havePhysicalState=havePhysicalSnapshot=true;long before=physicalMask;physicalMask=mask;if(recording&&(capabilities&4)==0){long ms=deviceTime(tick);for(int key=0;key<32;key++)if(((before^mask)&(1L<<key))!=0)append(new Library.Entry(ms,"note",Notes.midiForKey(key),(mask&(1L<<key))!=0?1:0,0));}}
    private boolean beforeRecording(long tick){return haveRecordBoundary&&(int)(tick-recordBoundaryTick)<0;}
    private void recordPhysicalEvent(long tick,int key,int down){
        if(!recording)return;long bit=1L<<key;
        if(beforeRecording(tick)){
            if((int)(tick-recordBaselinePhysicalTicks[key])<=0)return;
            recordBaselinePhysicalTicks[key]=tick;recordPhysicalMask=down!=0?recordPhysicalMask|bit:recordPhysicalMask&~bit;
            if(physicalBaselines[key]!=null){captured.remove(physicalBaselines[key]);physicalBaselines[key]=null;}
            if(down!=0){physicalBaselines[key]=new Library.Entry(0,"note",Notes.midiForKey(key),1,0);captured.add(physicalBaselines[key]);}return;
        }
        long before=recordPhysicalMask;recordPhysicalMask=down!=0?before|bit:before&~bit;
        if(before!=recordPhysicalMask)append(new Library.Entry(deviceTime(tick),"note",Notes.midiForKey(key),down,0));
    }
    private void recordParameterEvent(long tick,int v,int b,int p){
        if(!recording)return;
        if(beforeRecording(tick)){
            if((int)(tick-recordBaselineParameterTick)<=0)return;
            recordBaselineParameterTick=tick;recordVolume=v;recordBend=b;recordPreset=p;captured.remove(initialParameters);initialParameters=new Library.Entry(0,"params",v,b,p);captured.add(initialParameters);return;
        }
        if(recordVolume!=v||recordBend!=b||recordPreset!=p){recordVolume=v;recordBend=b;recordPreset=p;append(new Library.Entry(deviceTime(tick),"params",v,b,p));}
    }
    public void background(){panic();if(!demo)transport().disconnect("App 进入后台，设备已断开");}
    public void close(){h.removeCallbacksAndMessages(null);transport().disconnect("已关闭");}
}
