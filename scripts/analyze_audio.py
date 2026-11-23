"""Analyze independently decoded I2S PCM and 4/8/16/32-voice captures."""
import json
from pathlib import Path
import wave
import numpy as np

ROOT=Path(__file__).resolve().parents[1]
def peak_near(samples,freq):
    nfft=262144
    spectrum=np.abs(np.fft.rfft(samples*np.hanning(len(samples)),n=nfft))
    bins=np.fft.rfftfreq(nfft,1/48000)
    area=np.flatnonzero(abs(bins-freq)<2.5)
    k=area[np.argmax(spectrum[area])]
    return float(bins[k]),float(spectrum[k]),float(np.median(spectrum[(bins>50)&(bins<1000)]))

def main():
    table=json.loads((ROOT/'docs/tables.json').read_text())['notes']
    results={}
    for voices in [4,8,16,32]:
        pcm=np.loadtxt(ROOT/f'build/poly{voices}.pcm.txt',dtype=np.int32)
        assert len(pcm)==24000 and pcm.min()<0<pcm.max() and max(abs(pcm))<=32767
        peaks=[]
        for note in table[:voices]:
            actual,amp,floor=peak_near(pcm,note['frequency'])
            assert abs(actual-note['frequency'])<0.5,(voices,note,actual)
            assert amp>floor*20,(voices,note,'missing peak')
            peaks.append(dict(midi=note['midi'],expected_hz=note['frequency'],measured_hz=actual))
        results[str(voices)]=dict(min=int(pcm.min()),max=int(pcm.max()),peaks=peaks)
    tone=np.loadtxt(ROOT/'build/tone440_i2s.pcm.txt',dtype=np.int32)
    hz,amp,floor=peak_near(tone[-24000:],440)
    assert abs(hz-440)<0.2 and amp>floor*100
    first=int(np.flatnonzero(tone)[0])
    assert first/48000<0.010
    results['i2s_440']=dict(hz=hz,first_nonzero_frame=first,simulated_input_to_i2s_ms=first/48,
                           note='Ideal switch edge; does not include mechanical bounce or MAX98357A latency.')
    timing=json.loads((ROOT/'build/system_latency.json').read_text())
    results['latency']=dict(input_to_pcm_ms=timing['input_to_pcm_cycles']*1000/timing['clock_hz'],
                           input_to_i2s_ms=timing['input_to_i2s_cycles']*1000/timing['clock_hz'],
                           note='Ideal raw switch edge to first nonzero PCM / fully received left-channel I2S word; no analog measurement.')
    assert 0<results['latency']['input_to_pcm_ms']<10
    assert 0<results['latency']['input_to_i2s_ms']<10
    with wave.open(str(ROOT/'build/synth_demo.wav'),'wb') as out:
        pcm=np.loadtxt(ROOT/'build/poly4.pcm.txt',dtype=np.int16)
        out.setnchannels(1);out.setsampwidth(2);out.setframerate(48000);out.writeframes(pcm.astype('<i2').tobytes())
    (ROOT/'build/audio_analysis.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
    print(f'PASS all 60 polyphonic spectral peaks; I2S A4={hz:.3f} Hz; latency={results["latency"]}')
if __name__=='__main__': main()
