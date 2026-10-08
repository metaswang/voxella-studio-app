"""Generate a Kaldi FBank parity fixture with the official torchaudio implementation.

Mirrors pyannote.audio WeSpeaker `compute_fbank`: int16 scaling, kaldi.fbank with
80 bins, 25/10 ms, Hamming, dither 0, snip_edges, no energy, then mean normalization.

    uv run --with torch --with torchaudio --with numpy python tools/speaker_reference/make_fbank_fixture.py OUT.json
"""
import json
import math
import sys

import numpy as np
import torch
import torchaudio.compliance.kaldi as kaldi


def signal(count: int) -> np.ndarray:
    state = 12345
    values = []
    for index in range(count):
        state = (1103515245 * state + 12345) % (1 << 31)
        noise = state / float(1 << 31) - 0.5
        t = index / 16000.0
        voiced = 0.3 * math.sin(2 * math.pi * 180 * t) + 0.1 * math.sin(2 * math.pi * 1250 * t)
        values.append(voiced * (0.6 + 0.4 * math.sin(2 * math.pi * 3 * t)) + 0.02 * noise + 0.01)
    return np.asarray(values, dtype=np.float32)


def main() -> None:
    audio = signal(8000 + 123)
    waveform = torch.from_numpy(audio)[None, :] * (1 << 15)
    features = kaldi.fbank(
        waveform, num_mel_bins=80, frame_length=25.0, frame_shift=10.0,
        round_to_power_of_two=True, snip_edges=True, dither=0.0,
        sample_frequency=16000, window_type="hamming", use_energy=False,
    )
    features = features - features.mean(dim=0, keepdim=True)
    json.dump({
        "audio": audio.tolist(),
        "frames": int(features.shape[0]),
        "features": features.flatten().tolist(),
    }, open(sys.argv[1], "w"))


if __name__ == "__main__":
    main()
