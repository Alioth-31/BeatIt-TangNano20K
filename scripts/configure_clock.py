"""Read BL616 clock configuration; --set configures CLK0 and --save persists it."""
import argparse
from pathlib import Path
import time
import serial

ROOT=Path(__file__).resolve().parents[1]

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port',required=True,help='BL616 UART port')
    p.add_argument('--set',action='store_true',help='Enable CLK0 at 49152K; changes FPGA clock immediately')
    p.add_argument('--save',action='store_true',help='Persist verified CLK0 configuration in BL616')
    a=p.parse_args()
    transcript=[]
    with serial.Serial(a.port,115200,timeout=0.2,write_timeout=1) as port:
        def send(data):
            port.write(data); port.flush(); time.sleep(0.2)
            reply=port.read(16384).decode(errors='replace')
            transcript.append(repr(data)+'\n'+reply); return reply
        send(bytes([24])); send(bytes([3])); send(b'\r')
        before=send(b'pll_clk\r')
        if 'O0:' not in before: raise RuntimeError('BL616 terminal did not respond; check port')
        if a.set: send(b'pll_clk O0=49152K\r')
        after=send(b'pll_clk\r')
        if a.set or a.save:
            if not any(token in after for token in ['[ EN]O0: 49152000','[ EN]O0: 49152001']):
                raise RuntimeError('CLK0 enable/frequency readback mismatch; no save performed')
        if a.save:
            saved=send(b'pll_clk -s\r')
            if 'save success' not in saved.lower(): raise RuntimeError('Clock save did not report success')
    text='\n'.join(transcript)
    (ROOT/'build').mkdir(exist_ok=True)
    log=ROOT/'build'/('clock_'+time.strftime('%Y%m%d_%H%M%S')+'.log')
    log.write_text(text,encoding='utf-8'); print(text); print('Log:',log)

if __name__=='__main__': main()
