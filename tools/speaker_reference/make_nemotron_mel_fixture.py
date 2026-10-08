"""Generate a Nemotron 3 mel parity fixture following the reference feature extractor
(transformers NemotronAsrStreamingFeatureExtractor, processor_config.json of
nvidia/Nemotron-3-Diarization @ a435e98): pre-emphasis 0.97, torch.stft(n_fft=512,
win_length=400, hann periodic=False, center=True, pad_mode="constant"), power,
librosa Slaney mel (128 bins, 0-8 kHz), log(x + 2**-24); final centered frame dropped.

    uv run --no-project --with torch --with librosa --with numpy python tools/speaker_reference/make_nemotron_mel_fixture.py OUT.json
"""
import json
import math
import sys

import librosa
import numpy as np
import torch


def signal(count: int) -> np.ndarray:
    state = 777
    values = []
    for index in range(count):
        state = (1103515245 * state + 12345) % (1 << 31)
        noise = state / float(1 << 31) - 0.5
        t = index / 16000.0
        values.append(0.25 * math.sin(2 * math.pi * 220 * t) + 0.08 * math.sin(2 * math.pi * 2900 * t) + 0.03 * noise)
    return np.asarray(values, dtype=np.float32)


def main() -> None:
    audio = signal(16000 + 517)
    x = torch.from_numpy(audio)[None, :]
    x = torch.cat([x[:, :1], x[:, 1:] - 0.97 * x[:, :-1]], dim=1)
    window = torch.hann_window(400, periodic=False)
    stft = torch.stft(x, 512, hop_length=160, win_length=400, window=window,
                      return_complex=True, pad_mode="constant", center=True)
    power = torch.view_as_real(stft).pow(2).sum(-1)
    filters = torch.from_numpy(librosa.filters.mel(sr=16000, n_fft=512, n_mels=128, fmin=0.0,
                                                   fmax=8000, norm="slaney")).float()
    mel = torch.log(filters @ power + 2 ** -24)[0].T  # [frames, 128]
    valid = len(audio) // 160
    mel = mel[:valid]
    json.dump({"audio": audio.tolist(), "frames": valid, "features": mel.flatten().tolist()}, open(sys.argv[1], "w"))


if __name__ == "__main__":
    main()
