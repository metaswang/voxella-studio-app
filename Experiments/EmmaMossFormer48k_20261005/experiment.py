"""Reproducible Emma audition experiment using the app's MLX MossFormer2 model.

Run prepare, run the CLI commands in run.sh, then run finish.
Raw model outputs remain float32. Auditions use 24-bit PCM and linear gain only.
"""
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys

import numpy as np

ROOT = Path(__file__).resolve().parent
AUDIO = ROOT / 'audio'
RATE = 48000


def read(path):
    result = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(path), '-ar', str(RATE),
                             '-ac', '1', '-f', 'f32le', '-'], check=True, capture_output=True)
    return np.frombuffer(result.stdout, dtype='<f4').copy()


def write(path, samples, codec='pcm_f32le'):
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'f32le', '-ar', str(RATE),
                    '-ac', '1', '-i', '-', '-c:a', codec, str(path)],
                   input=np.asarray(samples, dtype='<f4').tobytes(), check=True)


def meter(path):
    result = subprocess.run(['ffmpeg', '-hide_banner', '-i', str(path), '-af',
                             'loudnorm=I=-18:TP=-1.5:LRA=11:print_format=json',
                             '-f', 'null', '-'], capture_output=True, text=True, check=True)
    values = json.loads(result.stderr[result.stderr.rfind('{'):result.stderr.rfind('}') + 1])
    return {key: float(values['input_' + key]) for key in ['i', 'tp', 'lra', 'thresh']}


def high_pass(samples):
    # Same first-order 80 Hz filter as LinearLoudnessNormalizer.highPass.
    alpha = np.float32((1 / (2 * math.pi * 80)) / (1 / (2 * math.pi * 80) + 1 / RATE))
    output = np.zeros_like(samples)
    previous_input, previous_output = np.float32(0), np.float32(0)
    for index, sample in enumerate(samples):
        previous_output = alpha * (previous_output + sample - previous_input)
        output[index] = previous_output
        previous_input = sample
    return output


def padded(samples, count):
    assert np.isfinite(samples).all(), 'Non-finite inference output'
    return np.pad(samples[:count], (0, max(0, count - len(samples))))


def metrics(samples, source):
    a, b = samples.astype(np.float64), source.astype(np.float64)
    gain = np.dot(a, b) / np.dot(a, a)
    return {'sample_count': len(samples), 'duration_seconds': len(samples) / RATE,
            'finite_ratio': float(np.isfinite(samples).mean()),
            'sample_peak_dbfs': float(20 * np.log10(max(np.max(np.abs(a)), 1e-12))),
            'correlation_with_original': float(np.corrcoef(a, b)[0, 1]),
            'gain_matched_residual_rms_ratio': float(np.sqrt(np.mean((gain * a - b) ** 2) / np.mean(b ** 2)))}


def prepare():
    original = read(AUDIO / '02_original_resampled_48k.wav')
    write(AUDIO / '03_original_hpf80_48k.wav', high_pass(original))
    print('Prepared app-equivalent 80 Hz high-pass input', len(original))


def finish():
    original = read(AUDIO / '02_original_resampled_48k.wav')
    filtered = read(AUDIO / '03_original_hpf80_48k.wav')
    pure_raw = read(AUDIO / '01_mossformer_pure_raw_48k.wav')
    filtered_wet_raw = read(AUDIO / '04_mossformer_hpf_raw_48k.wav')
    pure = padded(pure_raw, len(original))
    filtered_wet = padded(filtered_wet_raw, len(original))
    variants = {
        'A_original_matched': original,
        'B_mossformer_pure': pure,
        'C_natural_45pct': np.float32(.55) * filtered + np.float32(.45) * filtered_wet,
        'D_clean_70pct': np.float32(.30) * filtered + np.float32(.70) * filtered_wet,
    }
    # Detect model delay before mixing; refuse if a meaningful delay appears.
    delays = range(-48, 49)
    x, y = filtered[480:-480:4], filtered_wet[480:-480:4]
    correlations = [float(np.dot(x, np.roll(y, d))) for d in delays]
    best_lag = list(delays)[int(np.argmax(correlations))] * 4
    assert abs(best_lag) <= 4, f'Model alignment requires review: {best_lag} samples'
    raw_paths, raw_meters = {}, {}
    for name, samples in variants.items():
        path = AUDIO / (name + '_raw.wav')
        write(path, samples)
        raw_paths[name] = path
        raw_meters[name] = meter(path)
    # One constant gain per file. Choose a shared attainable LUFS target so
    # none needs a limiter or compressor and all remain <= -1.5 dBTP.
    target = min([-18.0] + [m['i'] + (-1.6 - m['tp']) for m in raw_meters.values()])
    report = {
        'source_session_id': 'F8C8DAF5-9EC3-4243-BCA7-454763AC7884',
        'source_title': 'Emma and the Little Bird',
        'source_sample_rate': 24000, 'source_channels': 1,
        'model': 'starkdmi/MossFormer2-SE-fp16', 'sample_rate': RATE,
        'model_sha256': hashlib.sha256((ROOT / 'model-cache/mlx-audio/starkdmi_MossFormer2-SE-fp16/model.safetensors').read_bytes()).hexdigest(),
        'recipe': 'full context (<20 seconds), same MLXAudioSTS implementation as app',
        'postprocessing': 'app 80 Hz HPF for blended variants; constant BS.1770 loudness gain; 24-bit PCM; no compression/EQ boost/reverb',
        'target_lufs': target, 'peak_ceiling_dbtp': -1.5,
        'pure_raw_samples': len(pure_raw), 'filtered_wet_raw_samples': len(filtered_wet_raw),
        'source_48k_samples': len(original), 'measured_alignment_samples': best_lag,
        'tail_padding_samples': len(original) - len(pure_raw), 'variants': {},
        'limitations': 'No clean ground truth. Correlation/residual measure change, not perceptual quality. 48 kHz resampling does not restore missing bandwidth. Subjective premium sound needs human audition.',
    }
    outputs = []
    for name, samples in variants.items():
        gain_db = target - raw_meters[name]['i']
        path = AUDIO / (name + '_48k24bit.wav')
        write(path, samples * np.float32(10 ** (gain_db / 20)), 'pcm_s24le')
        final_meter = meter(path)
        assert final_meter['tp'] <= -1.5, final_meter
        assert abs(final_meter['i'] - target) <= .15, final_meter
        final_samples = read(path)
        assert len(final_samples) == len(original)
        report['variants'][name] = {**metrics(final_samples, original),
                                    'meter': final_meter, 'linear_gain_db': gain_db,
                                    'path': str(path)}
        outputs.append(final_samples)
    gap = np.zeros(int(.8 * RATE), dtype=np.float32)
    sequence = np.concatenate([piece for index, item in enumerate(outputs)
                               for piece in ([gap, item] if index else [item])])
    write(AUDIO / 'ABCD_comparison_48k24bit.wav', sequence, 'pcm_s24le')
    (ROOT / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    {'prepare': prepare, 'finish': finish}[sys.argv[1]]()
