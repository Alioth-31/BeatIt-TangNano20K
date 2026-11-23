package cn.nano20k.synth;

/** Ordered foreground byte transport used by the protocol session. */
public interface DeviceLink {
    void send(byte[] frame);
    int pending();
    void disconnect(String reason);
}
