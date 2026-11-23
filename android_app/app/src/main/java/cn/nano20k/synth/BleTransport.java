package cn.nano20k.synth;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.bluetooth.*;
import android.bluetooth.le.*;
import android.content.pm.PackageManager;
import android.os.*;
import cn.nano20k.synth.core.Protocol;
import java.util.*;

/** Foreground BLE UART only. Every callback is delivered to the main thread. */
@SuppressLint("MissingPermission")
public final class BleTransport implements DeviceLink {
    public interface Listener {
        void status(String text,boolean connected);
        void discovered(BluetoothDevice device,int rssi);
        void frame(Protocol.Frame frame);
        void writable();
    }
    private static final UUID NUS=UUID.fromString("6e400001-b5a3-f393-e0a9-e50e24dcca9e"), RX=UUID.fromString("6e400002-b5a3-f393-e0a9-e50e24dcca9e"), TX=UUID.fromString("6e400003-b5a3-f393-e0a9-e50e24dcca9e"), HM=UUID.fromString("0000ffe0-0000-1000-8000-00805f9b34fb"), HM_CHAR=UUID.fromString("0000ffe1-0000-1000-8000-00805f9b34fb"), CCC=UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");
    private final Activity activity;private final Listener listener;private final Handler handler=new Handler(Looper.getMainLooper());
    private final BluetoothAdapter adapter;
    private BluetoothLeScanner scanner;private BluetoothGatt gatt;private BluetoothGattCharacteristic writer;
    private Protocol.Decoder decoder=new Protocol.Decoder();
    private final ArrayDeque<byte[]> queue=new ArrayDeque<>();private boolean writing,connected;private int writeType;
    private Runnable writeTimeout,scanTimeout,connectTimeout;
    public BleTransport(Activity a,Listener l){activity=a;listener=l;BluetoothManager manager=a.getSystemService(BluetoothManager.class);adapter=manager==null?null:manager.getAdapter();}
    public boolean available(){return adapter!=null;}
    public boolean permitted(){if(Build.VERSION.SDK_INT>=31)return activity.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN)==PackageManager.PERMISSION_GRANTED&&activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT)==PackageManager.PERMISSION_GRANTED;return activity.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)==PackageManager.PERMISSION_GRANTED;}
    public boolean enabled(){return adapter!=null&&permitted()&&adapter.isEnabled();}
    public int pending(){return queue.size();}
    private final ScanCallback scanCallback=new ScanCallback(){
        @Override public void onScanResult(int type,ScanResult result){handler.post(()->listener.discovered(result.getDevice(),result.getRssi()));}
        @Override public void onScanFailed(int error){handler.post(()->listener.status("蓝牙搜索失败（"+error+"）",connected));}
    };
    public void scan(){
        if(!enabled()){listener.status(adapter==null?"此设备没有蓝牙适配器":"请授权并开启蓝牙",false);return;}
        stopScan();scanner=adapter.getBluetoothLeScanner();if(scanner==null){listener.status("蓝牙搜索不可用",false);return;}
        scanner.startScan(null,new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(),scanCallback);
        listener.status("正在搜索 BLE 设备 · 12 秒",connected);scanTimeout=()->{stopScan();listener.status(connected?"蓝牙已连接":"搜索结束，点击设备连接",connected);};handler.postDelayed(scanTimeout,12000);
    }
    public void stopScan(){if(scanTimeout!=null)handler.removeCallbacks(scanTimeout);if(scanner!=null&&permitted()){try{scanner.stopScan(scanCallback);}catch(RuntimeException ignored){} }scanner=null;}
    public void connect(BluetoothDevice device){
        stopScan();disconnect("正在连接设备");decoder=new Protocol.Decoder();
        gatt=device.connectGatt(activity,false,callback,BluetoothDevice.TRANSPORT_LE);
        connectTimeout=()->fail("连接或服务发现超时，请重试");handler.postDelayed(connectTimeout,12000);
    }
    public void send(byte[] frame){
        if(!connected||gatt==null||writer==null)return;
        if(queue.size()+(frame.length+19)/20>48){fail("蓝牙发送积压，已断开以避免卡音");return;}
        for(int offset=0;offset<frame.length;offset+=20)queue.add(Arrays.copyOfRange(frame,offset,Math.min(offset+20,frame.length)));
        pump();
    }
    private void pump(){
        if(writing||queue.isEmpty()||gatt==null||writer==null)return;
        writing=true;byte[] bytes=queue.peek();boolean accepted;
        if(Build.VERSION.SDK_INT>=33)accepted=gatt.writeCharacteristic(writer,bytes,writeType)==BluetoothStatusCodes.SUCCESS;
        else {writer.setWriteType(writeType);writer.setValue(bytes);accepted=gatt.writeCharacteristic(writer);}
        if(!accepted){fail("蓝牙写入失败，请重新连接");return;}
        final BluetoothGatt current=gatt;
        if(writeType==BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE){handler.postDelayed(()->{if(gatt==current&&writing)completeWrite();},25);}
        else{writeTimeout=()->{if(gatt==current&&writing)fail("蓝牙写入超时");};handler.postDelayed(writeTimeout,2000);}
    }
    private void completeWrite(){if(writeTimeout!=null)handler.removeCallbacks(writeTimeout);writing=false;queue.poll();pump();}
    private void fail(String reason){disconnect(reason);}
    public void disconnect(String reason){
        stopScan();if(connectTimeout!=null)handler.removeCallbacks(connectTimeout);if(writeTimeout!=null)handler.removeCallbacks(writeTimeout);
        BluetoothGatt old=gatt;gatt=null;writer=null;connected=false;writing=false;queue.clear();if(old!=null){try{old.disconnect();}catch(RuntimeException ignored){}old.close();}listener.status(reason,false);
    }
    private final BluetoothGattCallback callback=new BluetoothGattCallback(){
        @Override public void onConnectionStateChange(BluetoothGatt source,int status,int newState){handler.post(()->{
            if(source!=gatt)return;
            if(status!=BluetoothGatt.GATT_SUCCESS||newState==BluetoothProfile.STATE_DISCONNECTED){fail("蓝牙已断开（"+status+"）");return;}
            if(newState==BluetoothProfile.STATE_CONNECTED){listener.status("蓝牙已连接，发现 UART 服务…",true);if(!source.discoverServices())fail("无法发现服务");}
        });}
        @Override public void onServicesDiscovered(BluetoothGatt source,int status){handler.post(()->{
            if(source!=gatt)return;if(status!=BluetoothGatt.GATT_SUCCESS){fail("服务发现失败");return;}
            BluetoothGattService service=source.getService(NUS);BluetoothGattCharacteristic notify;
            if(service!=null){writer=service.getCharacteristic(RX);notify=service.getCharacteristic(TX);}
            else{service=source.getService(HM);writer=service==null?null:service.getCharacteristic(HM_CHAR);notify=writer;}
            if(writer==null||notify==null){fail("设备没有 NUS / HM-10 BLE UART 服务");return;}
            int props=writer.getProperties();if((props&BluetoothGattCharacteristic.PROPERTY_WRITE)!=0)writeType=BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT;
            else if((props&BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE)!=0)writeType=BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE;
            else{fail("UART 特征不可写");return;}
            boolean indication=(notify.getProperties()&BluetoothGattCharacteristic.PROPERTY_NOTIFY)==0;
            if(indication&&(notify.getProperties()&BluetoothGattCharacteristic.PROPERTY_INDICATE)==0){fail("UART 特征不支持回传");return;}
            BluetoothGattDescriptor descriptor=notify.getDescriptor(CCC);
            if(descriptor==null||!source.setCharacteristicNotification(notify,true)){fail("无法订阅 UART 回传");return;}
            byte[] value=indication?BluetoothGattDescriptor.ENABLE_INDICATION_VALUE:BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE;
            boolean ok;if(Build.VERSION.SDK_INT>=33)ok=source.writeDescriptor(descriptor,value)==BluetoothStatusCodes.SUCCESS;
            else{descriptor.setValue(value);ok=source.writeDescriptor(descriptor);}
            if(!ok)fail("无法设置蓝牙通知");
        });}
        @Override public void onDescriptorWrite(BluetoothGatt source,BluetoothGattDescriptor descriptor,int status){handler.post(()->{
            if(source!=gatt)return;if(status!=BluetoothGatt.GATT_SUCCESS){fail("蓝牙通知订阅失败");return;}
            if(connectTimeout!=null)handler.removeCallbacks(connectTimeout);connected=true;listener.status("蓝牙已连接，等待 FPGA 固件握手…",true);listener.writable();
        });}
        @Override public void onCharacteristicWrite(BluetoothGatt source,BluetoothGattCharacteristic characteristic,int status){handler.post(()->{if(source!=gatt||writeType==BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE)return;if(status!=BluetoothGatt.GATT_SUCCESS)fail("蓝牙写入被设备拒绝");else if(writing)completeWrite();});}
        @Override public void onCharacteristicChanged(BluetoothGatt source,BluetoothGattCharacteristic c,byte[] value){received(source,value.clone());}
        @Override public void onCharacteristicChanged(BluetoothGatt source,BluetoothGattCharacteristic c){byte[] value=c.getValue();if(value!=null)received(source,value.clone());}
        private void received(BluetoothGatt source,byte[] value){handler.post(()->{if(source==gatt)for(Protocol.Frame frame:decoder.feed(value))listener.frame(frame);});}
    };
}
