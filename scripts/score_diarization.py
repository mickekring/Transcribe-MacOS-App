#!/usr/bin/env python3
"""Score a diarization debug export against a ground-truth turn list.

Usage:
    python3 scripts/score_diarization.py <debug-export.json> <truth.txt>

Debug exports are written by the app when enabled:
    defaults write com.mickekring.transcribe.Transcribe diarizationDebugExport -bool true
They land in Application Support/com.mickekring.transcribe.Transcribe/DiarizationDebug/.

Truth format — one turn per line: "<start> <end> <speaker>", seconds and any
speaker label. Lines starting with # are ignored. Example:
    0.0   14.2  micke
    14.2  31.0  cecilia
    31.0  32.1  micke

Reports:
  - detected vs. true speaker count
  - attribution accuracy: fraction of ground-truth speech time assigned to
    the correct speaker, under the best possible label mapping (labels are
    arbitrary on both sides)
"""

import itertools
import json
import sys


def load_truth(path):
    turns = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 3:
                continue
            turns.append((float(parts[0]), float(parts[1]), parts[2]))
    return turns


def overlap(a_start, a_end, b_start, b_end):
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)

    export = json.load(open(sys.argv[1]))
    truth = load_truth(sys.argv[2])
    detected = [(t["start"], t["end"], t["speaker"]) for t in export["turns"]]

    true_speakers = sorted({t[2] for t in truth})
    detected_speakers = sorted({t[2] for t in detected})

    print(f"file: {export.get('file')}  source: {export.get('source')}")
    print(f"speakers — true: {len(true_speakers)}  detected: {len(detected_speakers)}")

    total_truth_time = sum(end - start for start, end, _ in truth)
    if not detected or total_truth_time == 0:
        print("nothing to score")
        sys.exit(0)

    # Overlap matrix: truth speaker x detected speaker -> overlapping seconds
    matrix = {ts: {ds: 0.0 for ds in detected_speakers} for ts in true_speakers}
    for t_start, t_end, t_spk in truth:
        for d_start, d_end, d_spk in detected:
            matrix[t_spk][d_spk] += overlap(t_start, t_end, d_start, d_end)

    # Best one-to-one mapping (brute force — speaker counts are small)
    best_correct = 0.0
    smaller, larger = (true_speakers, detected_speakers) if len(true_speakers) <= len(detected_speakers) else (detected_speakers, true_speakers)
    for perm in itertools.permutations(larger, len(smaller)):
        correct = 0.0
        for spk, mapped in zip(smaller, perm):
            ts, ds = (spk, mapped) if smaller is true_speakers else (mapped, spk)
            correct += matrix[ts][ds]
        best_correct = max(best_correct, correct)

    accuracy = best_correct / total_truth_time
    print(f"attribution accuracy: {accuracy:.1%} of {total_truth_time:.0f}s speech time")

    words = export.get("words", [])
    print(f"words with timings: {len(words)}")


if __name__ == "__main__":
    main()
