"""Set or query the optional FPGA tone filter over the existing UART protocol.

Requires a protocol-enabled --app --live-tone FPGA image and pyserial.
No audio samples are transmitted by this utility.
The port must already be a transparent UART; for Nano 20K USB, run
device_link.py --port COM6 first to select the BL616 UART bridge.
"""
import argparse
import time


def crc16(data):
    crc = 0xffff
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ (0x1021 if crc & 0x8000 else 0)) & 0xffff
    return crc


def make_frame(command, seq, payload=b''):
    if len(payload) > 64:
        raise ValueError('Payload too long')
    body = bytes((1, command, seq & 255, (seq >> 8) & 255, len(payload))) + payload
    checksum = crc16(body)
    return b'\xa5\x5a' + body + checksum.to_bytes(2, 'little')


class FrameDecoder:
    def __init__(self):
        self.buffer = bytearray()

    def feed(self, data):
        self.buffer.extend(data)
        frames = []
        while len(self.buffer) >= 2:
            if self.buffer[:2] != b'\xa5\x5a':
                del self.buffer[0]
                continue
            if len(self.buffer) < 7:
                break
            size = self.buffer[6] + 9
            if self.buffer[2] != 1 or self.buffer[6] > 64:
                del self.buffer[0]
                continue
            if len(self.buffer) < size:
                break
            data = bytes(self.buffer[:size])
            if crc16(data[2:-2]) != int.from_bytes(data[-2:], 'little'):
                del self.buffer[0]
                continue
            frames.append((data[3], data[4] | (data[5] << 8), data[7:-2]))
            del self.buffer[:size]
        return frames


def exchange(port, command, payload, seq, timeout=2.0):
    port.write(make_frame(command, seq, payload))
    decoder = FrameDecoder()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for kind, received_seq, reply in decoder.feed(port.read(64)):
            if received_seq != seq:
                continue
            if kind == 0x80:
                if len(reply) != 2 or reply[0] != command:
                    raise RuntimeError('Malformed acknowledgement')
                status = reply[1]
                if status != 0:
                    raise RuntimeError(f'Command 0x{command:02X} failed: status={status}')
                return reply
            if ((command == 0x04 and kind == 0x86) or
                (command == 0x05 and kind == 0x87)):
                if len(reply) != 1 or reply[0] > 3:
                    raise RuntimeError('Malformed sound parameter response')
                return reply
    raise TimeoutError(f'No reply to command 0x{command:02X}')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port', required=True, help='USB/BLE transparent UART port, e.g. COM6')
    p.add_argument('--tone', type=int, choices=range(4), help='0=dry, 1=bright, 2=warm, 3=dark')
    p.add_argument('--wave', type=int, choices=range(4), help='0=sine, 1=saw, 2=pulse, 3=triangle')
    p.add_argument('--timeout', type=float, default=2)
    args = p.parse_args()
    try:
        import serial
    except ImportError as exc:
        raise SystemExit('Requires pyserial: pip install pyserial') from exc
    with serial.Serial(args.port, 115200, timeout=0.05, write_timeout=2) as ser:
        if args.tone is not None:
            exchange(ser, 0x14, bytes((args.tone,)), 0x1420, args.timeout)
        if args.tone is not None or args.wave is None:
            tone = exchange(ser, 0x04, b'', 0x1421, args.timeout)[0]
            print('Active tone mode:', tone)
            if args.tone is not None and tone != args.tone:
                raise SystemExit('Tone readback mismatch')
        if args.wave is not None:
            exchange(ser, 0x15, bytes((args.wave,)), 0x1520, args.timeout)
            wave = exchange(ser, 0x05, b'', 0x1521, args.timeout)[0]
            print('Active waveform mode:', wave)
            if wave != args.wave:
                raise SystemExit('Waveform readback mismatch')


if __name__ == '__main__':
    main()
