"""Local streaming keyword spotting. Input is in-memory PCM; audio is never saved."""
import argparse
import base64
import json
from pathlib import Path
import re
import sys
import wave

import numpy as np
from pypinyin import pinyin, Style
import sherpa_onnx


def keyword_tokens(phrase):
    phrase=''.join(c for c in phrase if c.isalnum())
    if not 2 <= len(phrase) <= 16 or re.search(r'[^\u3400-\u9fff]',phrase):
        raise ValueError('请使用2到16个汉字作为唤醒词。')
    initials=pinyin(phrase,style=Style.INITIALS,strict=False)
    finals=pinyin(phrase,style=Style.FINALS_TONE,strict=False)
    tokens=[v for pair in zip(initials,finals) for xs in pair for v in xs if v]
    return phrase,' '.join(tokens)+' @'+phrase


class Spotter:
    def __init__(self,model_dir,phrase,threshold=0.35):
        self.phrase,keywords=keyword_tokens(phrase)
        root=Path(model_dir)
        self.spotter=sherpa_onnx.KeywordSpotter(
            tokens=str(root/'tokens.txt'),
            encoder=str(root/'encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx'),
            decoder=str(root/'decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx'),
            joiner=str(root/'joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx'),
            keywords_file=str(root/'empty-keywords.txt'),num_threads=1,keywords_score=1.0,
            keywords_threshold=threshold,num_trailing_blanks=2,provider='cpu',
        )
        self.stream=self.spotter.create_stream(keywords)
        self.last_end_sample=0
    def accept(self,samples):
        self.stream.accept_waveform(16000,samples)
        while self.spotter.is_ready(self.stream):
            self.spotter.decode_stream(self.stream)
            result=self.spotter.get_result(self.stream)
            if result:
                stamps=self.spotter.timestamps(self.stream)
                # Timestamp denotes the final token, not the later decoder callback.
                # A short overlap is intentionally kept by the host to retain immediate follow-up speech.
                self.last_end_sample=max(0,int((max(stamps)+0.08)*16000)) if stamps else 0
                self.spotter.reset_stream(self.stream)
                if result == self.phrase: return result
        return ''


def emit(value):
    print(value,flush=True)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--model-dir',required=True)
    parser.add_argument('--phrase',required=True)
    parser.add_argument('--threshold',type=float,default=0.35)
    parser.add_argument('--input')
    args=parser.parse_args()
    spotter=Spotter(args.model_dir,args.phrase,args.threshold)
    if args.input:
        with wave.open(args.input,'rb') as wav:
            if wav.getframerate()!=16000 or wav.getnchannels()!=1 or wav.getsampwidth()!=2:
                raise ValueError('Expected 16kHz mono 16-bit PCM WAV')
            samples=np.frombuffer(wav.readframes(wav.getnframes()),dtype='<i2').astype(np.float32)/32768.0
        samples=np.concatenate((samples,np.zeros(16000,dtype=np.float32)))
        found=''
        for start in range(0,len(samples),640):
            found=spotter.accept(samples[start:start+640])
            if found: break
        print(json.dumps({'keyword':found,'activated':bool(found)},ensure_ascii=False))
        return
    emit('READY')
    processed_samples=0
    last_progress_samples=0
    for line in sys.stdin:
        line=line.strip()
        if line=='END':
            found=spotter.accept(np.zeros(16000,dtype=np.float32))
            if found: emit('WAKE\t'+base64.b64encode(found.encode('utf-8')).decode('ascii'))
            break
        if not line: continue
        pcm=base64.b64decode(line,validate=True)
        samples=np.frombuffer(pcm,dtype='<i2').astype(np.float32)/32768.0
        found=spotter.accept(samples)
        # Acknowledge only input that the model has actually consumed. This is
        # audio-time progress, never a timer heartbeat or synthetic END padding.
        processed_samples+=len(samples)
        if processed_samples and (last_progress_samples==0 or processed_samples-last_progress_samples>=8000 or found):
            emit('PROGRESS\t'+str(processed_samples))
            last_progress_samples=processed_samples
        if found:
            emit('END_SAMPLE\t'+str(spotter.last_end_sample))
            emit('WAKE\t'+base64.b64encode(found.encode('utf-8')).decode('ascii'))
            break


if __name__=='__main__':
    try:
        main()
    except Exception as exc:
        emit('ERROR\t'+base64.b64encode(str(exc).encode('utf-8')).decode('ascii'))
        sys.exit(1)
