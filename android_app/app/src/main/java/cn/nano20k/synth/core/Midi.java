package cn.nano20k.synth.core;
import java.io.*;
import java.util.*;
public final class Midi {
    public static final class Event {
        public final long ms; public final int note,channel; public final boolean down;
        public Event(long ms,int note,boolean down,int channel) { this.ms=ms;this.note=note;this.down=down;this.channel=channel; }
    }
    public static final int MAX_BYTES=1048576, MAX_EVENTS=50000;
    public static final long MAX_MS=600000;
    public static final class Song {
        public final List<Event> events; public final long durationMs;
        public Song(List<Event> e,long duration) {events=Collections.unmodifiableList(new ArrayList<>(e));durationMs=duration;}
        public Set<Integer> unsupported() { Set<Integer> r=new TreeSet<>();for(Event e:events)if(Notes.keyForMidi(e.note)<0)r.add(e.note);return r; }
    }
    private static final class Raw { long tick;int note,channel,tempo,order;boolean down; }
    private static final class Reader {
        final byte[] data;int pos,end;
        Reader(byte[] b,int start,int stop) {data=b;pos=start;end=stop;}
        int get()throws IOException {if(pos>=end)throw new IOException("MIDI 数据被截断");return data[pos++]&255;}
        int word()throws IOException {return (get()<<8)|get();}
        long integer()throws IOException {return ((long)word()<<16)|word();}
        long variable()throws IOException {long v=0;for(int i=0;i<4;i++){int b=get();v=(v<<7)|(b&127);if(b<128)return v;}throw new IOException("MIDI 变长数超过 4 字节");}
        void skip(long n)throws IOException {if(n<0||n>end-pos)throw new IOException("MIDI 块长度错误");pos+=(int)n;}
        int data()throws IOException {int b=get();if(b>=128)throw new IOException("MIDI 数据字节错误");return b;}
    }
    public static Song read(byte[] bytes) throws IOException {
        if(bytes.length>MAX_BYTES)throw new IOException("曲谱超过 1 MB");
        Reader r=new Reader(bytes,0,bytes.length);
        if(r.integer()!=0x4d546864L)throw new IOException("不是标准 MIDI 文件");
        long header=r.integer();if(header<6)throw new IOException("MIDI 文件头错误");
        int format=r.word(),tracks=r.word(),division=r.word();r.skip(header-6);
        if(format>1||tracks<1||tracks>64||(format==0&&tracks!=1))throw new IOException("仅支持 MIDI 0/1，最多 64 轨");
        if(division==0||(division&0x8000)!=0)throw new IOException("仅支持按拍计时的 MIDI");
        List<Raw> raw=new ArrayList<>();long lastTick=0;int order=0,totalEvents=0;
        for(int t=0;t<tracks;t++) {
            if(r.integer()!=0x4d54726bL)throw new IOException("缺少 MIDI 音轨块");
            long size=r.integer();if(size>r.end-r.pos)throw new IOException("音轨被截断");
            Reader tr=new Reader(bytes,r.pos,r.pos+(int)size);r.skip(size);
            long tick=0;int running=0;boolean eot=false;
            while(tr.pos<tr.end) {
                if(++totalEvents>MAX_EVENTS)throw new IOException("曲谱事件超过 50000");
                tick+=tr.variable();if(tick>Integer.MAX_VALUE)throw new IOException("音轨过长");
                int status=tr.get();if(status<128){if(running==0)throw new IOException("缺少 MIDI 状态");tr.pos--;status=running;}
                if(status==0xff) {
                    running=0;int meta=tr.get();long len=tr.variable();
                    if(meta==0x51){if(len!=3)throw new IOException("速度事件长度错误");int tempo=(tr.get()<<16)|(tr.get()<<8)|tr.get();if(tempo==0)throw new IOException("速度不能为零");Raw a=new Raw();a.tick=tick;a.tempo=tempo;a.order=order++;raw.add(a);}
                    else if(meta==0x2f){if(len!=0)throw new IOException("音轨结束事件错误");eot=true;break;}
                    else tr.skip(len);
                } else if(status==0xf0||status==0xf7){running=0;tr.skip(tr.variable());}
                else if(status>=0x80&&status<=0xef) {
                    running=status;int kind=status>>4,ch=status&15,a=tr.data(),b=(kind==0xc||kind==0xd)?0:tr.data();
                    if(kind==8||kind==9){Raw event=new Raw();event.tick=tick;event.note=a;event.channel=ch;event.down=kind==9&&b>0;event.order=order++;raw.add(event);}
                    else if(kind==0xb&&(a==120||a==123)){Raw event=new Raw();event.tick=tick;event.note=-1;event.channel=ch;event.order=order++;raw.add(event);}
                } else throw new IOException("不支持的 MIDI 状态");
            }
            if(!eot)throw new IOException("音轨没有结束标记");
            lastTick=Math.max(lastTick,tick);
            if(raw.size()>MAX_EVENTS)throw new IOException("曲谱事件过多");
        }
        raw.sort(Comparator.comparingLong((Raw e)->e.tick).thenComparingInt(e->e.order));
        long previousTick=0,scaledUs=0;int tempo=500000;List<Event> events=new ArrayList<>();int[][] active=new int[16][128];
        for(Raw e:raw) {
            scaledUs+=(e.tick-previousTick)*tempo;previousTick=e.tick;
            long ms=scaledUs/division/1000;if(ms>MAX_MS)throw new IOException("曲谱超过 10 分钟");
            if(e.tempo!=0){tempo=e.tempo;continue;}
            if(e.note==-1){for(int n=0;n<128;n++)while(active[e.channel][n]>0){active[e.channel][n]--;events.add(new Event(ms,n,false,e.channel));}continue;}
            if(e.down){active[e.channel][e.note]++;events.add(new Event(ms,e.note,true,e.channel));}
            else if(active[e.channel][e.note]>0){active[e.channel][e.note]--;events.add(new Event(ms,e.note,false,e.channel));}
        }
        long duration=(scaledUs+(lastTick-previousTick)*tempo)/division/1000;
        if(duration>MAX_MS)throw new IOException("曲谱超过 10 分钟");
        for(int c=0;c<16;c++)for(int n=0;n<128;n++)while(active[c][n]-->0)events.add(new Event(duration,n,false,c));
        if(events.isEmpty())throw new IOException("曲谱没有可演奏音符");
        return new Song(events,duration);
    }
    public static byte[] write(List<Event> input) throws IOException {
        long duration=0;for(Event event:input)duration=Math.max(duration,event.ms);return write(input,duration);
    }
    public static byte[] write(List<Event> input,long duration) throws IOException {
        if(duration<0||duration>MAX_MS)throw new IOException("时长范围错误");
        if(input.size()>MAX_EVENTS)throw new IOException("事件太多");
        List<Event> events=new ArrayList<>(input);events.sort(Comparator.comparingLong(e->e.ms));
        ByteArrayOutputStream data=new ByteArrayOutputStream();DataOutputStream track=new DataOutputStream(data);
        track.write(new byte[]{0,(byte)0xff,0x51,3,7,(byte)0xa1,0x20});long previous=0;
        for(Event e:events){if(e.ms<0||e.ms>MAX_MS||e.note<0||e.note>127||e.channel<0||e.channel>15)throw new IOException("事件范围错误");variable(track,e.ms-previous);previous=e.ms;track.writeByte((e.down?0x90:0x80)|e.channel);track.writeByte(e.note);track.writeByte(e.down?100:0);}
        if(duration<previous)throw new IOException("时长小于最后一个事件");
        variable(track,duration-previous);track.write(new byte[]{(byte)0xff,0x2f,0});
        ByteArrayOutputStream result=new ByteArrayOutputStream();DataOutputStream out=new DataOutputStream(result);
        out.writeInt(0x4d546864);out.writeInt(6);out.writeShort(0);out.writeShort(1);out.writeShort(500);out.writeInt(0x4d54726b);out.writeInt(data.size());data.writeTo(out);return result.toByteArray();
    }
    private static void variable(DataOutputStream out,long v)throws IOException {int b=(int)(v&127);while((v>>=7)!=0){b<<=8;b|=(v&127)|128;}while(true){out.writeByte(b);if((b&128)==0)break;b>>>=8;}}
    public static Song melody(int... notes) {
        List<Event> events = new ArrayList<>();
        long time = 0;
        for (int note : notes) {
            events.add(new Event(time, note, true, 0));
            events.add(new Event(time + 420, note, false, 0));
            time += 480;
        }
        return new Song(events, time);
    }
    public static Song twinkle() {
        int[] melody={60,60,67,67,69,69,67,65,65,64,64,62,62,60,67,67,65,65,64,64,62,67,67,65,65,64,64,62,60,60,67,67,69,69,67,65,65,64,64,62,62,60};
        List<Event> e=new ArrayList<>();long ms=0;for(int i=0;i<melody.length;i++){long len=(i%7==6)?800:400;e.add(new Event(ms,melody[i],true,0));e.add(new Event(ms+len-40,melody[i],false,0));ms+=len;}return new Song(e,ms);
    }
    public static Song ode() {
        int[] melody={64,64,65,67,67,65,64,62,60,60,62,64,64,62,62,64,64,65,67,67,65,64,62,60,60,62,64,62,60,60};
        List<Event> e=new ArrayList<>();long ms=0;for(int n:melody){e.add(new Event(ms,n,true,0));e.add(new Event(ms+420,n,false,0));ms+=480;}return new Song(e,ms);
    }
}
