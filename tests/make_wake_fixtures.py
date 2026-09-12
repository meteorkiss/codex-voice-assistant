"""Generate self-authored test audio via the approved Microsoft TTS service."""
import argparse
import asyncio
import json
from pathlib import Path
import shutil
import subprocess
import edge_tts

ROOT = Path(__file__).resolve().parents[1]

async def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--phrase', default='你好，声伴')
    args=parser.parse_args()
    destination=ROOT/'tests'/'fixtures'/'wake'
    scratch=ROOT/'work'/'tests'/'wake'/'synthesis'
    destination.mkdir(parents=True,exist_ok=True)
    scratch.mkdir(parents=True,exist_ok=True)
    ffmpeg=shutil.which('ffmpeg')
    if not ffmpeg: raise RuntimeError('ffmpeg was not found')
    cases=[
        ('positive-taiwan-chen',args.phrase,'zh-TW-HsiaoChenNeural',True),
        ('positive-taiwan-yu',args.phrase,'zh-TW-HsiaoYuNeural',True),
        ('positive-mainland',args.phrase,'zh-CN-XiaoxiaoNeural',True),
        ('negative-normal','请帮我把今天的工作整理一下，先看看文件里面有什么内容。','zh-TW-HsiaoChenNeural',False),
        ('negative-close-boss','你好，老板。','zh-TW-HsiaoChenNeural',False),
        ('negative-close-how','你好，怎么办。','zh-TW-HsiaoChenNeural',False),
        ('negative-half','你好。','zh-TW-HsiaoChenNeural',False),
        ('negative-name','声伴。','zh-TW-HsiaoChenNeural',False),
        ('negative-ack','在。请告诉我，你想了解什么。','zh-TW-HsiaoChenNeural',False),
    ]
    semaphore=asyncio.Semaphore(3)
    async def create(case):
        name,text,voice,expected=case
        async with semaphore:
            mp3=scratch/(name+'.mp3')
            await edge_tts.Communicate(text,voice,rate='-3%',connect_timeout=15,receive_timeout=30).save(str(mp3))
            subprocess.run([ffmpeg,'-y','-hide_banner','-loglevel','error','-i',str(mp3),'-ac','1','-ar','16000','-c:a','pcm_s16le',str(destination/(name+'.wav'))],check=True)
            print(name,flush=True)
    await asyncio.gather(*(create(case) for case in cases))
    subprocess.run([ffmpeg,'-y','-hide_banner','-loglevel','error','-f','lavfi','-i','anoisesrc=d=5:c=pink:a=0.08:r=16000','-ac','1','-c:a','pcm_s16le',str(destination/'negative-noise.wav')],check=True)
    subprocess.run([ffmpeg,'-y','-hide_banner','-loglevel','error','-f','lavfi','-i','anullsrc=r=16000:cl=mono','-t','4','-c:a','pcm_s16le',str(destination/'negative-silence.wav')],check=True)
    manifest={'phrase':args.phrase,'cases':[{'name':n,'text':t,'voice':v,'expected':e} for n,t,v,e in cases] + [
        {'name':'negative-noise','text':'generated pink noise','expected':False},
        {'name':'negative-silence','text':'generated silence','expected':False},
    ]}
    (destination/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')

asyncio.run(main())
