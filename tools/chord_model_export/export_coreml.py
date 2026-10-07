"""Convert the Jiang et al. 2019 chord network (music-x-lab, MIT) to `ChordNet.mlpackage`, and
export its decoder's chord vocabulary to `ChordNetVocabulary.json`.

The app recognises chords with this network (Eric, 2026-10-07): on the guitar stems of 22 charted
songs it found 0.80 of the charts' chord changes with 92 % of chords in the chart's set, against
0.74 and 77 % for template matching (docs/research/chord-recognition-and-guitar-separation-2026-10.md).
One network of the published five-model ensemble scores the same as the ensemble, so only `s0` ships.
Python runs only here; the app runs the package through Core ML.

The architecture is restated below from the repo's `chordnet_ismir_naive.py` (CNNFeatureExtractor +
ChordNet.forward) so conversion needs only torch, not the repo's training dependencies.

Input:  `cqt`, shape (1, T, 252): CQT magnitudes, 36 bins per octave from C1 (bins 18..<270 of the
        repo's 288-bin CQT from F#0), hop 512 at 22,050 Hz. T is flexible: the network's instance
        normalisation and its bidirectional LSTM span the whole song, so a song is one evaluation.
Output: six softmax heads per frame — triad 73, bass 13, seventh 4, ninth 4, eleventh 3,
        thirteenth 3.

    python export_coreml.py <repo> <out_dir> <check_cqt.npy>

<repo> is a checkout of https://github.com/music-x-lab/ISMIR2019-Large-Vocabulary-Chord-Recognition;
<check_cqt.npy> is a (T, 288) CQT of any song from the repo's own extractor, for the parity check.
Needs torch and coremltools with its native libraries (not Python 3.14).
"""

import json
import os
import sys

import numpy as np

for _name, _type in (("float", float), ("int", int), ("complex", complex), ("object", object)):
    setattr(np, _name, _type)  # the repo's decoder predates NumPy 2

import coremltools as ct
import torch
import torch.nn as nn
import torch.nn.functional as F

MODEL = "joint_chord_net_ismir_naive_v1.0_reweight(0.0,10.0)_s0.best"
SPEC_DIM = 252
FIRST_BIN = 18  # SHIFT_HIGH * SHIFT_STEP in the repo
SPLITS = [73, 13, 4, 4, 3, 3]
NAMES = ["triad", "bass", "seventh", "ninth", "eleventh", "thirteenth"]


class CNNFeatureExtractor(nn.Module):
    def __init__(self):
        super().__init__()
        c1, c2, c3, c4 = 16, 32, 64, 80
        self.conv1a = nn.Conv2d(1, c1, 3, padding=(1, 1))
        self.conv1b = nn.Conv2d(c1, c1, 3, padding=(1, 1))
        self.conv1c = nn.Conv2d(c1, c1, 3, padding=(1, 1))
        self.conv2a = nn.Conv2d(c1, c2, 3, padding=(1, 1))
        self.conv2b = nn.Conv2d(c2, c2, 3, padding=(1, 1))
        self.conv2c = nn.Conv2d(c2, c2, 3, padding=(1, 1))
        self.conv3a = nn.Conv2d(c2, c3, 3, padding=(1, 1))
        self.conv3b = nn.Conv2d(c3, c3, 3, padding=(1, 1))
        self.conv4a = nn.Conv2d(c3, c4, 3, padding=(1, 0))
        self.conv4b = nn.Conv2d(c4, c4, 3, padding=(1, 0))
        self.output_size = 3 * c4

    @staticmethod
    def block(conv, x):
        # nn.InstanceNorm2d with the repo's defaults: no affine weights, no running statistics.
        return F.selu(F.instance_norm(conv(x)))

    def forward(self, x):
        batch, length = x.shape[0], x.shape[1]
        x = x.view(batch, 1, length, SPEC_DIM)
        for conv in (self.conv1a, self.conv1b, self.conv1c):
            x = self.block(conv, x)
        x = F.max_pool2d(x, (1, 3))
        for conv in (self.conv2a, self.conv2b, self.conv2c):
            x = self.block(conv, x)
        x = F.max_pool2d(x, (1, 3))
        for conv in (self.conv3a, self.conv3b):
            x = self.block(conv, x)
        x = F.max_pool2d(x, (1, 4))
        for conv in (self.conv4a, self.conv4b):
            x = self.block(conv, x)
        return x.transpose(1, 2).contiguous().view(batch, length, self.output_size)


class ChordNet(nn.Module):
    def __init__(self):
        super().__init__()
        self.audio_feature_block = CNNFeatureExtractor()
        self.condition_linear = nn.Linear(270, 128)  # unused at inference; kept to load weights
        self.lstm1 = nn.LSTM(240, 96, num_layers=1, bidirectional=True, batch_first=True)
        self.final_fc1 = nn.Linear(192, sum(SPLITS))

    def forward(self, cqt):
        length = cqt.shape[1]
        x = self.audio_feature_block(cqt)
        x = self.lstm1(x)[0]
        x = self.final_fc1(x).reshape(length, sum(SPLITS))
        return tuple(F.softmax(part, dim=1) for part in torch.split(x, SPLITS, dim=1))


def main(repo, out_dir, check_cqt):
    state = torch.load(
        os.path.join(repo, "cache_data", f"{MODEL}.sdict"), map_location="cpu",
        weights_only=False)["net"]
    model = ChordNet()
    model.load_state_dict(state)
    model.eval()

    example = torch.rand(1, 1000, SPEC_DIM)
    with torch.no_grad():
        traced = torch.jit.trace(model, example, check_trace=False)
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(
                name="cqt", shape=(1, ct.RangeDim(lower_bound=16, upper_bound=40000), SPEC_DIM),
                dtype=np.float32)
        ],
        outputs=[ct.TensorType(name=n) for n in NAMES],
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = (
        "Jiang et al. 2019 large-vocabulary chord network (s0), music-x-lab, MIT.")
    os.makedirs(out_dir, exist_ok=True)
    mlmodel.save(os.path.join(out_dir, "ChordNet.mlpackage"))

    # The decoder's vocabulary: every chord it can name, with its (triad, bass, 7, 9, 11, 13)
    # indices, so the Swift decoder scores exactly the same candidates.
    sys.path.insert(0, repo)
    cwd = os.getcwd()
    os.chdir(repo)
    from extractors.xhmm_ismir import XHMMDecoder

    decoder = XHMMDecoder(template_file="data/submission_chord_list.txt")
    os.chdir(cwd)
    vocabulary = [
        {"name": name, "array": [int(x) for x in array]}
        for array, name in decoder.known_chord_array
    ]
    with open(os.path.join(out_dir, "ChordNetVocabulary.json"), "w") as handle:
        json.dump(
            {"changePenalty": decoder.diff_trans_penalty, "chords": vocabulary}, handle, indent=0)

    # Parity on a real song's features: Core ML against PyTorch.
    cqt = np.load(check_cqt).astype(np.float32)[:, FIRST_BIN:FIRST_BIN + SPEC_DIM]
    window = torch.tensor(cqt).unsqueeze(0)
    with torch.no_grad():
        reference = [r.numpy() for r in model(window)]
    got = mlmodel.predict({"cqt": window.numpy()})
    for name, ref in zip(NAMES, reference):
        new = np.asarray(got[name]).reshape(ref.shape)
        agree = np.mean(np.argmax(new, 1) == np.argmax(ref, 1))
        print(f"{name}: max |diff| {np.abs(new - ref).max():.5f}, argmax agreement {agree:.4f}")


if __name__ == "__main__":
    main(*sys.argv[1:4])
