package cn.nano20k.synth.core;
import java.util.*;
public final class Protocol {
    public static final int HELLO=1, STATUS_REQUEST=2, SET_STATE=0x10, SET_MAP=0x11, SET_KEYS=0x12, SET_PARAMS=0x13, ACK=0x80, HELLO_REPLY=0x81, STATUS=0x82, EVENT=0x83, PARAM_EVENT=0x84;
    public static final int CAP_SPLIT=8;
    public static final class Frame {
        public final int type,sequence; public final byte[] payload;
        public Frame(int t,int s,byte[] p) {type=t;sequence=s;payload=p;}
    }
    public static final class Decoder {
        private final ArrayList<Byte> buffer=new ArrayList<>();
        public int errors;
        public List<Frame> feed(byte[] bytes) {
            List<Frame> frames=new ArrayList<>();
            for(byte b:bytes) {
                buffer.add(b);
                while(buffer.size()>=2) {
                    if(u(0)!=0xa5 || u(1)!=0x5a) { buffer.remove(0); continue; }
                    if(buffer.size()<7) break;
                    int len=u(6);
                    if(u(2)!=1 || len>64) { errors++; buffer.remove(0); continue; }
                    int size=9+len;
                    if(buffer.size()<size) break;
                    byte[] candidate=new byte[size]; for(int i=0;i<size;i++)candidate[i]=buffer.get(i);
                    if(crc(candidate,2,5+len)!=(u(size-2)|(u(size-1)<<8))) {errors++;buffer.remove(0);continue;}
                    frames.add(new Frame(u(3),u(4)|(u(5)<<8),Arrays.copyOfRange(candidate,7,7+len)));
                    buffer.subList(0,size).clear();
                }
            }
            return frames;
        }
        private int u(int i) { return buffer.get(i)&255; }
    }
    public static byte[] encode(int type,int sequence,byte[] payload) {
        if(payload.length>64)throw new IllegalArgumentException("payload >64");
        byte[] f=new byte[payload.length+9]; f[0]=(byte)0xa5;f[1]=0x5a;f[2]=1;f[3]=(byte)type;
        f[4]=(byte)sequence;f[5]=(byte)(sequence>>8);f[6]=(byte)payload.length;
        System.arraycopy(payload,0,f,7,payload.length);int crc=crc(f,2,5+payload.length);
        f[f.length-2]=(byte)crc;f[f.length-1]=(byte)(crc>>8);return f;
    }
    public static int crc(byte[] b,int start,int len) {
        int c=0xffff;
        for(int i=start;i<start+len;i++){c^=(b[i]&255)<<8;for(int j=0;j<8;j++)c=((c&0x8000)!=0?(c<<1)^0x1021:c<<1)&0xffff;}
        return c;
    }
    public static byte[] state(long mask,int volume,int bend,int preset) {
        if(volume<0||volume>65535||bend<-32||bend>32||preset<0||preset>2)throw new IllegalArgumentException("state range");
        byte[] p=new byte[8];for(int i=0;i<4;i++)p[i]=(byte)(mask>>(8*i));p[4]=(byte)volume;p[5]=(byte)(volume>>8);p[6]=(byte)bend;p[7]=(byte)preset;return p;
    }
    public static long u32(byte[] p,int offset) { long r=0;for(int i=0;i<4;i++)r|=(long)(p[offset+i]&255)<<(8*i);return r; }
    public static int u16(byte[] p,int offset) { return (p[offset]&255)|((p[offset+1]&255)<<8); }
}
