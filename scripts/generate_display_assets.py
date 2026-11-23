"""Generate a small, fixed Chinese UI font/layout, not a framebuffer.

Use the Noto Sans CJK SC Regular OTF or another compatible redistributable font.
All generated memories have a power-of-two depth and explicit blank padding.
"""
import argparse
from pathlib import Path
import json
import hashlib
import math
from PIL import Image, ImageDraw, ImageFont

ROOT=Path(__file__).resolve().parents[1]
WAVE_CAPTION='波形 自适配 / 48kHz / 512点'
PATCHES=['长笛','羽管键琴','风琴','手动自定义','单簧管']
MODES=['自由演奏','设置中','诊断测试','启动中','练习中','暂停中','完成']
SCALES=['大调','小调','半音']
FIELDS=['音色','调性','音域','模式','曲目','速度']
REASONS=['','启动中','不适配','不适配','灯故障','设置中']
GUIDE_ROWS={8:'曲目：    速度：      步：',9:'练习：1 2 3 4 5 6 7 8',10:'右旋钮短按：启动/暂停',11:'漏：      错：'}

def generate(font_path):
    screens=[]
    for settings in (False,True):
        rows=[' '*32 for _ in range(16)]
        def put(row,col,text):
            assert col+len(text)<=32
            rows[row]=rows[row][:col]+text+rows[row][col+len(text):]
        put(0,0,'BeatIt 电子乐器')
        put(1,0,'FPGA 硬件实时合成')
        put(2,0,'模式：')
        put(3,0,'音色：')
        put(4,0,'调性：');put(4,14,'音域：')
        put(5,0,'音量：   %');put(5,14,'声部：')
        put(6,0,'琴键：1 2 3 4 5 6 7 8')
        if settings:
            put(8,0,'项目：');put(8,12,'预览：')
            put(9,0,'K1音色 K2调性 K3音域')
            put(10,0,'K4模式 K5曲目 K6速度')
            put(11,0,'右旋钮修改，短按确认；松开左旋钮退出')
        else:
            put(8,0,'左旋钮：音量   右旋钮：音色')
            put(9,0,'按住左旋钮进入设置')
        put(12,0,WAVE_CAPTION)
        put(12,28,'XY')
        for row,rate in enumerate((48000,24000,12000),start=13):
            put(row,0,'频谱 Hz')
            for col,bin_index in zip((6,14,22,28),(8,16,24,32)):
                put(row,col,str(rate*bin_index//256).rjust(4))
        screens.append(rows)
    repertoire=set(''.join(''.join(s) for s in screens)+''.join(PATCHES+MODES+SCALES+FIELDS+REASONS+list(GUIDE_ROWS.values()))+
        '0123456789ABCDEFG#音色调性音域系统故障')
    chars=[' ']+sorted(repertoire-{' '})
    assert len(chars)<=128, 'Guide must not double font BSRAM allocation'
    ids={c:i for i,c in enumerate(chars)}
    def gid(c):return f"8'd{ids[c]}"
    def choose(expr,strings,index):
        return ''.join(f'({expr}=={n})?{gid(s[index] if index<len(s) else " ")}:' for n,s in enumerate(strings))+gid(' ')
    slots={}
    for j in range(5):
        slots[(2,3+j)]=choose('display_mode',MODES,j)
        slots[(3,3+j)]=choose('timbre',PATCHES,j)
    slots[(4,3)]='note_glyph(root)'
    slots[(4,4)]="sharp(root)?"+gid('#')+':'+gid(' ')
    for j in range(2):slots[(4,6+j)]=choose('scale',SCALES,j)
    slots[(4,17)]='digit({1\'b0,octave})'
    for j,expr in enumerate(('percent/100','(percent/10)%10','percent%10')):slots[(5,3+j)]=f'digit({expr})'
    slots[(5,17)]='digit(active/10)';slots[(5,18)]='digit(active%10)'
    for col,char in enumerate('256',start=WAVE_CAPTION.index('512')):
        slots[(12,col)]=f'short_window?{gid(char)}:base'
    for col,(half,quarter) in enumerate(zip('24','12'),start=WAVE_CAPTION.index('48')):
        slots[(12,col)]=f'wave_stride[1]?{gid(quarter)}:wave_stride[0]?{gid(half)}:base'
    # Overlay practice details onto the same two text pages; no framebuffer or
    # third text ROM. Actual played keys remain visible on row6.
    for row,line in GUIDE_ROWS.items():
        for col in range(32):
            char=line[col] if col<len(line) else ' '
            slots[(row,col)]=f'(!settings && guide_mode)?{gid(char)}:base'
    slots[(8,3)]="(!settings && guide_mode)?digit({31'd0,guide_state[14]}+1):base"
    for j,expr in enumerate(('guide_bpm/100','(guide_bpm/10)%10','guide_bpm%10')):
        slots[(8,10+j)]=f'(!settings && guide_mode)?digit({expr}):base'
    for col,expr in ((18,'({28\'d0,guide_state[11:8]}+1)/10'),(19,'({28\'d0,guide_state[11:8]}+1)%10')):
        slots[(8,col)]=f'(!settings && guide_mode)?digit({expr}):base'
    for start,expr in ((2,'guide_missed'),(10,'guide_wrong')):
        for j,part in enumerate((f'{expr}/100',f'({expr}/10)%10',f'{expr}%10')):
            slots[(11,start+j)]=f'(!settings && guide_mode)?digit({part}):base'
    for j in range(4):slots[(7,j)]='guide_mode?('+choose('guide_reason',REASONS,j)+'):base'
    for col in range(14):
        slots[(10,col)]=f'settings?((GUIDE_ENABLED && ({col}<5 || guide_mode))?base:{gid(" ")}):({slots[(10,col)]})'
    for j in range(5):
        selected=choose('field',FIELDS,j)
        slots[(8,3+j)]='settings?('+selected+'):('+slots[(8,3+j)]+')'
        preview_patch=choose('preview[2:0]',PATCHES,j)
        preview_key=(['note_glyph(preview_root)',"sharp(preview_root)?"+gid('#')+':'+gid(' '),gid(' '),
            'preview>=12?'+gid('小')+':'+gid('大'),gid('调')][j])
        preview_oct='digit(preview[3:0])' if j==0 else gid(' ')
        preview_mode=choose('preview[0]',['自由演奏','练习'],j)
        preview_song='digit({31\'d0,preview[0]}+1)' if j==0 else gid(' ')
        preview_tempo=f'digit({["preview_bpm/100","(preview_bpm/10)%10","preview_bpm%10"][j]})' if j<3 else gid(' ')
        slots[(8,15+j)]=f'settings?((field==0)?({preview_patch}):(field==1)?({preview_key}):(field==2)?({preview_oct}):(field==3)?({preview_mode}):(field==4)?({preview_song}):({preview_tempo})):({slots[(8,15+j)]})'
    for j in range(4):slots[(1,j)]=f'fault?{gid("系统故障"[j])}:base'
    case_lines=[f"            9'd{row*32+col}:dynamic_glyph={expr};" for (row,col),expr in sorted(slots.items())]
    values='''// Generated by scripts/generate_display_assets.py.
    function [7:0] digit;
        input [31:0] number;
        begin case(number)
'''+''.join(f"            {n}:digit={gid(str(n))};\n" for n in range(10))+f"            default:digit={gid(' ')};\n"+'''        endcase end
    endfunction
    function [7:0] note_glyph;
        input [3:0] note;
        begin case(note)
'''+''.join(f"            {n}:note_glyph={gid(c)};\n" for n,c in enumerate('CCDDEFFGGAAB'))+f"            default:note_glyph={gid(' ')};\n"+'''        endcase end
    endfunction
    function sharp;
        input [3:0] note;
        begin sharp=(note==1 || note==3 || note==6 || note==8 || note==10);end
    endfunction
    function [7:0] dynamic_glyph;
        input [8:0] cell_index;input [7:0] base;
        begin dynamic_glyph=base;case(cell_index)
'''+ '\n'.join(case_lines)+'''
        endcase end
    endfunction
'''
    font=ImageFont.truetype(str(font_path), 16)
    depth=1
    while depth<len(chars)*16:depth*=2
    words=[0]*depth
    for n,char in enumerate(chars):
        im=Image.new('1',(16,16));draw=ImageDraw.Draw(im)
        box=font.getbbox(char);w=font.getlength(char)
        draw.text((int((16-w)//2),-box[1]),char,font=font,fill=1)
        for y in range(16):words[n*16+y]=sum(int(im.getpixel((x,y)))<<(15-x) for x in range(16))
    outputs={
        'display_font.hex':''.join(f'{v:04x}\n' for v in words),
        'display_text.hex':''.join(f'{ids[c]:02x}\n' for rows in screens for row in rows for c in row),
        'display_values.vh':values,
        'display_font_config.vh':f'localparam FONT_DEPTH={depth};\n',
        'display_sine.hex':''.join(f'{round(127*math.sin(math.tau*n/256))&255:02x}\n' for n in range(256)),
    }
    for name,text in outputs.items():(ROOT/'rtl'/name).write_text(text,encoding='ascii',newline='\n')
    manifest=dict(glyph_count=len(chars),font_bits=depth*16,text_bytes=1024,
        glyphs=''.join(chars),sources={n:hashlib.sha256(t.encode('ascii')).hexdigest() for n,t in outputs.items()})
    (ROOT/'build').mkdir(exist_ok=True)
    (ROOT/'build'/'display-assets.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({k:manifest[k] for k in ('glyph_count','font_bits','text_bytes')}))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--font', type=Path, required=True, help='Path to the CJK font file')
    generate(parser.parse_args().font)
