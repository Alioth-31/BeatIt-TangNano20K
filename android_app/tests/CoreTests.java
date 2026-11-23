import cn.nano20k.synth.core.*;
import java.io.*;
import java.util.*;

public class CoreTests {
    private static int checks;
    private static void check(boolean b, String why) { checks++; if (!b) throw new AssertionError(why); }
    private static void rejects(byte[] bytes) throws Exception {
        try { Midi.read(bytes); throw new AssertionError("malformed MIDI accepted"); }
        catch (IOException expected) { checks++; }
    }
    public static void main(String[] args) throws Exception {
        byte[] frame = Protocol.encode(0x10, 65535, new byte[]{1,2,3,4});
        Protocol.Decoder decoder = new Protocol.Decoder();
        List<Protocol.Frame> out = new ArrayList<>();
        for (byte b: frame) out.addAll(decoder.feed(new byte[]{b}));
        check(out.size()==1 && out.get(0).sequence==65535 && out.get(0).payload[3]==4,"fragmented protocol");
        byte[] corrupt=frame.clone(); corrupt[7]^=1;
        check(decoder.feed(corrupt).isEmpty(),"CRC rejects corruption");
        decoder.feed(new byte[]{7,(byte)0xa5,4});
        check(decoder.feed(frame).size()==1,"resync after noise");
        check(Protocol.crc("123456789".getBytes(),0,9)==0x29b1,"CCITT reference");
        byte[] state=Protocol.state(0x80000001L,65535,-32,2);
        check(state.length==8 && (state[3]&255)==128 && state[6]==-32,"signed bend and mask");
        Notes notes=new Notes();
        notes.press("finger1",31); notes.press("score1",31);
        check(notes.mask()==0x80000000L,"32-bit note mask");
        notes.release("finger1"); check(notes.mask()==0x80000000L,"shared note release");
        notes.press("score1",0); check(notes.mask()==1,"move owner between notes");
        notes.clear(); check(notes.mask()==0,"panic clears ownership");
        List<Midi.Event> ev=List.of(new Midi.Event(0,60,true,0),new Midi.Event(500,60,false,0),new Midi.Event(500,64,true,0),new Midi.Event(1000,64,false,0));
        Midi.Song song=Midi.read(Midi.write(ev));
        check(song.events.size()==4 && song.durationMs==1000,"MIDI export round trip");
        check(song.events.get(1).ms==500 && !song.events.get(1).down,"same-time note off before on");
        check(Midi.read(Midi.write(ev,5000)).durationMs==5000,"MIDI trailing silence duration");
        byte[] running=hex("4d546864000000060000000100604d54726b0000001200903c64003e6460803c00603e0000ff2f00");
        Midi.Song rs=Midi.read(running);
        check(rs.events.size()==4,"running status");
        check(rs.events.get(2).ms==500 && rs.durationMs==1000,"tempo default 500000 us/qn");
        rejects(new byte[]{1,2,3}); rejects(Arrays.copyOf(Midi.write(ev),20));
        byte[] badTempo=hex("4d546864000000060000000100604d54726b0000000b00ff510300000000ff2f00");
        rejects(badTempo);
        byte[] tempo=hex("4d546864000000060000000100604d54726b0000001a00ff510307a12000903c6460ff510303d09060803c0000ff2f00");
        Midi.Song timed=Midi.read(tempo);
        check(timed.durationMs==750,"tempo change conversion");
        check(Notes.keyForMidi(60)==0 && Notes.keyForMidi(61)==-1 && Notes.midiForKey(31)==59,"FPGA pitch table");
        Midi.Song built=Midi.twinkle();
        check(built.events.size()>20 && built.events.stream().allMatch(e->Notes.keyForMidi(e.note)>=0),"built-in playable pitches");
        byte[] allOff=hex("4d546864000000060000000100604d54726b0000001100903c64003c6460b07b0060ff2f00");
        allOff[21]=0x0f;
        Midi.Song stopped=Midi.read(allOff);
        check(stopped.events.size()==4 && stopped.events.get(2).ms==500 && stopped.events.get(3).ms==500,"CC123 releases overlapping notes");
        byte[] tooMany=Protocol.encode(0x10,1,new byte[64]);
        Protocol.Decoder stream=new Protocol.Decoder();List<Protocol.Frame> repeated=new ArrayList<>();for(int i=0;i<1000;i++)repeated.addAll(stream.feed(tooMany));check(repeated.size()==1000,"protocol sustained stream");
        rejects(new byte[Midi.MAX_BYTES+1]);
        byte[] smpte=Midi.write(ev);smpte[12]=(byte)0xe7;rejects(smpte);
        check(Midi.read(Midi.write(List.of(new Midi.Event(0,61,true,0),new Midi.Event(20,61,false,0)))).unsupported().contains(61),"unsupported pitches preserved for UI rejection");
        Practice practice=new Practice(new Midi.Song(List.of(
                new Midi.Event(0,60,true,0),new Midi.Event(0,64,true,1),
                new Midi.Event(0,60,true,2),new Midi.Event(400,60,true,0)),800));
        check(practice.total()==2&&practice.target()==3,"practice groups simultaneous onsets and deduplicates tracks");
        practice.input(0,true);practice.input(0,false);practice.input(1,true);
        check(!practice.waitingForRelease()&&practice.step()==0,"chord requires simultaneous hold");
        practice.input(0,true);practice.input(1,false);
        check(practice.waitingForRelease()&&practice.step()==0,"partially released chord does not advance");
        practice.input(0,false);
        check(practice.step()==1&&practice.target()==1,"chord release advances to repeated pitch");
        practice.input(1,true);practice.input(1,false);
        check(practice.wrong()==1&&!practice.done(),"wrong pitch does not advance");
        practice.input(0,true);practice.cancelTouches();
        check(practice.step()==1&&!practice.waitingForRelease(),"cancelled touch does not score");
        practice.input(0,true);practice.input(0,false);
        check(practice.done(),"fresh onset completes repeated pitch");
        practice.reset(new int[]{62,64,60,65,67,69,71,72},4);
        check(practice.target()==6&&practice.waitingForRelease(),"physical layout and pre-held baseline");
        practice.input(2,false);
        check(practice.step()==0&&!practice.waitingForRelease(),"pre-held release does not score");
        try{
            practice.reset(new int[]{62,63,64,65,66,67,68,69},0);
            throw new AssertionError("unsupported physical map accepted");
        }catch(IllegalArgumentException expected){check(expected.getMessage().contains("C4"),"missing physical pitch is identified");}
        System.out.println("PASS "+checks+" core checks");
    }
    static byte[] hex(String s) { byte[] r=new byte[s.length()/2]; for(int i=0;i<r.length;i++) r[i]=(byte)Integer.parseInt(s.substring(i*2,i*2+2),16); return r; }
}
