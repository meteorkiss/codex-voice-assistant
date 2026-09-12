"""Local-only SenseVoiceSmall transcription. No network access is used here."""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import time
import wave


def write_json(path, payload):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.tmp')
    temp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding='utf-8')
    os.replace(temp, path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--model-dir', default=str(Path(__file__).resolve().parents[1] / 'runtime' / 'models' / 'sensevoice'))
    parser.add_argument('--threads', type=int, default=4)
    args = parser.parse_args()
    began = time.perf_counter()
    try:
        import numpy as np
        import sherpa_onnx

        model_dir = Path(args.model_dir)
        model = model_dir / 'model.int8.onnx'
        tokens = model_dir / 'tokens.txt'
        if not model.is_file() or not tokens.is_file():
            raise FileNotFoundError('本地语音模型尚未安装完整。')
        with wave.open(args.input, 'rb') as source:
            rate = source.getframerate()
            if source.getnchannels() != 1 or source.getsampwidth() != 2 or rate != 16000:
                raise ValueError('录音必须为 16kHz、单声道、16位 PCM WAV。')
            samples = np.frombuffer(source.readframes(source.getnframes()), dtype='<i2').astype(np.float32) / 32768.0
        duration = len(samples) / rate
        # An ASR model can hallucinate a short word on exact silence; reject inaudible input first.
        rms = float(np.sqrt(np.mean(samples ** 2))) if len(samples) else 0.0
        peak = float(np.max(np.abs(samples))) if len(samples) else 0.0
        if duration < 0.18 or not len(samples) or rms < 0.0001 or peak < 0.0004:
            write_json(args.output, {'ok': True, 'text': '', 'duration': duration, 'elapsed': time.perf_counter()-began, 'engine': 'SenseVoiceSmall 本机识别'})
            return 0
        vad_model = model_dir / 'silero_vad.onnx'
        if not vad_model.is_file():
            raise FileNotFoundError('本地人声检测模型缺失。')
        vad_config = sherpa_onnx.VadModelConfig()
        vad_config.silero_vad.model = str(vad_model)
        vad_config.silero_vad.threshold = 0.4
        vad_config.silero_vad.min_speech_duration = 0.12
        vad_config.silero_vad.min_silence_duration = 0.25
        vad_config.sample_rate = rate
        vad_config.num_threads = 1
        vad = sherpa_onnx.VoiceActivityDetector(vad_config, buffer_size_in_seconds=60)
        def contains_speech(audio):
            vad.reset()
            for start in range(0,len(audio),512):
                vad.accept_waveform(audio[start:start+512])
                if vad.is_speech_detected() or not vad.empty(): return True
            vad.flush()
            return not vad.empty()
        # Long recordings are split near low-energy boundaries to bound memory and latency.
        window = max(1, int(rate * 28))
        search = max(1, int(rate * 4))
        frame = max(1, int(rate * 0.02))
        chunks = []
        offset = 0
        while offset < len(samples):
            end = min(len(samples), offset + window)
            if end < len(samples):
                region_start = max(offset+rate*10, end-search)
                energies = [(float(np.mean(samples[p:p+frame] ** 2)),p+frame//2)
                            for p in range(region_start,end-frame,frame)]
                if energies:
                    end = min(energies)[1]
            audio = samples[offset:end]
            if contains_speech(audio): chunks.append(audio)
            offset = end
        if not chunks:
            write_json(args.output, {'ok': True, 'text': '', 'duration': duration, 'elapsed': round(time.perf_counter()-began,3), 'engine': 'SenseVoiceSmall 本机识别'})
            return 0
        recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=str(model), tokens=str(tokens), num_threads=max(1,min(8,args.threads)),
            provider='cpu', language='zh', use_itn=True, debug=False,
        )
        loaded = time.perf_counter()
        parts = []
        for audio in chunks:
            stream = recognizer.create_stream()
            stream.accept_waveform(rate, audio)
            recognizer.decode_stream(stream)
            text = re.sub(r'<\|[^|]*\|>', '', stream.result.text).strip()
            if text: parts.append(text)
        text = ''.join(parts).strip()
        write_json(args.output, {
            'ok': True, 'text': text, 'duration': round(duration,3),
            'elapsed': round(time.perf_counter()-began,3),
            'model_load_seconds': round(loaded-began,3),
            'engine': 'SenseVoiceSmall 本机识别', 'segments': parts,
        })
        return 0
    except Exception as exc:
        write_json(args.output, {'ok': False, 'text': '', 'error': str(exc), 'elapsed': round(time.perf_counter()-began,3)})
        return 1


if __name__ == '__main__':
    sys.exit(main())
