package cn.nano20k.synth.core;
import java.util.*;
public final class Notes {
    private static final int[] MIDI={60,62,64,65,67,69,71,72,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59};
    private final Map<String,Integer> owners=new HashMap<>();
    public void press(String owner,int key) { if(key<0||key>=32)throw new IllegalArgumentException("key");owners.put(owner,key); }
    public void release(String owner) { owners.remove(owner); }
    public void clear() { owners.clear(); }
    public long mask() { long mask=0;for(int key:owners.values()) mask|=1L<<key;return mask; }
    public static int keyForMidi(int midi) { for(int i=0;i<MIDI.length;i++)if(MIDI[i]==midi)return i;return -1; }
    public static int midiForKey(int key) { if(key<0||key>=32)throw new IllegalArgumentException("key");return MIDI[key]; }
    public static String label(int key) { return midiLabel(midiForKey(key)); }
    public static String midiLabel(int n) { return new String[]{"C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B"}[n%12]+(n/12-1); }
}
