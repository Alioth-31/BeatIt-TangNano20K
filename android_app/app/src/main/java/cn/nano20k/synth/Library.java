package cn.nano20k.synth;

import android.content.Context;
import cn.nano20k.synth.core.Midi;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import javax.net.ssl.HttpsURLConnection;
import java.net.URI;

public final class Library {
    public static final class Entry {
        public long ms;public String type;public int a,b,c;
        public Entry(long ms,String type,int a,int b,int c){this.ms=ms;this.type=type;this.a=a;this.b=b;this.c=c;}
    }
    public static final class Recording {
        public final String name,source;public final List<Entry> events;public final long duration;public final boolean complete;
        public Recording(String name,String source,List<Entry> events,long duration,boolean complete){this.name=name;this.source=source;this.events=new ArrayList<>(events);this.duration=duration;this.complete=complete;}
        public List<Midi.Event> notes(){List<Midi.Event> r=new ArrayList<>();for(Entry e:events)if(e.type.equals("note"))r.add(new Midi.Event(e.ms,e.a,e.b!=0,0));return r;}
        public byte[] json()throws JSONException {
            JSONObject root=new JSONObject();root.put("schema","nanosynth.recording.v1");root.put("name",name);root.put("source",source);root.put("duration_ms",duration);root.put("complete",complete);
            JSONArray list=new JSONArray();for(Entry e:events){JSONObject a=new JSONObject();a.put("ms",e.ms);a.put("type",e.type);a.put("a",e.a);a.put("b",e.b);a.put("c",e.c);list.put(a);}root.put("events",list);return root.toString(2).getBytes(StandardCharsets.UTF_8);
        }
        static Recording parse(byte[] data)throws JSONException {
            JSONObject root=new JSONObject(new String(data,StandardCharsets.UTF_8));if(!root.getString("schema").equals("nanosynth.recording.v1"))throw new JSONException("未知格式");
            JSONArray a=root.getJSONArray("events");if(a.length()>Midi.MAX_EVENTS)throw new JSONException("事件过多");List<Entry> ev=new ArrayList<>();long prior=0;
            for(int i=0;i<a.length();i++){JSONObject x=a.getJSONObject(i);long ms=x.getLong("ms");String type=x.getString("type");int p=x.getInt("a"),q=x.getInt("b"),s=x.getInt("c");
                if(ms<prior||ms>Midi.MAX_MS)throw new JSONException("时间错误");prior=ms;
                if(type.equals("note")){if(p<0||p>127||q<0||q>1)throw new JSONException("音符错误");}
                else if(type.equals("params")){if(p<0||p>65535||q<-32||q>32||s<0||s>2)throw new JSONException("参数错误");}
                else throw new JSONException("未知事件");ev.add(new Entry(ms,type,p,q,s));}
            long duration=root.getLong("duration_ms");if(duration<prior||duration>Midi.MAX_MS)throw new JSONException("时长错误");
            return new Recording(root.getString("name"),root.getString("source"),ev,duration,root.optBoolean("complete",false));
        }
    }
    private final File dir;
    public Library(Context c){dir=new File(c.getFilesDir(),"recordings");if(!dir.isDirectory()&&!dir.mkdirs())throw new IllegalStateException("无法建立录音目录");}
    public File audioFile(){return new File(dir,"mic_"+System.currentTimeMillis()+".m4a");}
    public List<File> files(){File[] a=dir.listFiles((d,n)->n.endsWith(".json")||n.endsWith(".m4a"));List<File> r=a==null?new ArrayList<>():new ArrayList<>(Arrays.asList(a));r.sort(Comparator.comparingLong(File::lastModified).reversed());return r;}
    public void save(Recording recording)throws Exception{File f=new File(dir,"events_"+System.currentTimeMillis()+".json");try(FileOutputStream out=new FileOutputStream(f)){out.write(recording.json());}}
    public Recording read(File f)throws Exception{try(FileInputStream in=new FileInputStream(f)){return Recording.parse(readBounded(in,8*Midi.MAX_BYTES));}}
    public static byte[] readBounded(InputStream in,int max)throws IOException {ByteArrayOutputStream out=new ByteArrayOutputStream();byte[] b=new byte[8192];int n;while((n=in.read(b))!=-1){if(out.size()+n>max)throw new IOException("文件超过大小限制");out.write(b,0,n);}return out.toByteArray();}
    public static byte[] download(String url)throws Exception {
        URI uri=new URI(url.trim());
        for(int count=0;count<4;count++){
            if(!"https".equalsIgnoreCase(uri.getScheme())||uri.getHost()==null||uri.getUserInfo()!=null)throw new IOException("仅支持不含用户名密码的 HTTPS 曲谱直链");
            HttpsURLConnection connection=(HttpsURLConnection)uri.toURL().openConnection();connection.setConnectTimeout(8000);connection.setReadTimeout(8000);connection.setInstanceFollowRedirects(false);connection.setRequestProperty("Accept","audio/midi,application/octet-stream");
            try{int status=connection.getResponseCode();if(status==301||status==302||status==303||status==307||status==308){String location=connection.getHeaderField("Location");if(location==null)throw new IOException("跳转没有地址");uri=uri.resolve(location);continue;}if(status!=200)throw new IOException("服务器返回 HTTP "+status);if(connection.getContentLengthLong()>Midi.MAX_BYTES)throw new IOException("曲谱超过 1 MB");try(InputStream in=connection.getInputStream()){return readBounded(in,Midi.MAX_BYTES);}}
            finally{connection.disconnect();}
        }
        throw new IOException("下载跳转次数过多");
    }
}
