#!/usr/bin/env python3
"""Whisper inference server for Voice Capture Bot.

Communicates via line-delimited JSON over stdin/stdout (Erlang Port protocol).

Commands (stdin, one JSON object per line):
  {"command": "transcribe", "audio_path": "/path/to/file.wav"}
  {"command": "transcribe_pcm", "data": "<base64>", "sample_rate": 16000}
  {"command": "ping"}

Responses (stdout, one JSON object per line):
  {"type": "ready", "model": "..."}
  {"type": "result", "text": "...", "language": "en", "confidence": 0.95, "segments": [...], "duration_ms": 3200}
  {"type": "error", "message": "...", "code": "..."}
  {"type": "pong"}
"""

import json
import sys
import base64
import struct
import io
import tempfile
import os

MODEL_NAME = os.environ.get("WHISPER_MODEL", "medium.en")
_model = None


def load_model():
    global _model
    from faster_whisper import WhisperModel
    _model = WhisperModel(MODEL_NAME, device="cpu", compute_type="auto")
    return MODEL_NAME


def decode_wav(audio_path):
    """Read a PCM WAV into the float32 mono array faster-whisper wants.

    Handed a path, faster-whisper decodes through PyAV, and PyAV 19 dropped the
    `metadata_errors` argument its `decode_audio` still passes — so every file
    transcription raised `TypeError` before a single sample was read. A numpy array
    skips that path entirely: `wave` is stdlib, and the only conversion is to mono
    16 kHz, which is all Whisper accepts anyway.
    """
    import wave
    import numpy as np

    with wave.open(audio_path, "rb") as wav:
        channels = wav.getnchannels()
        width = wav.getsampwidth()
        rate = wav.getframerate()
        frames = wav.readframes(wav.getnframes())

    if width != 2:
        raise ValueError(f"expected 16-bit PCM, got {width * 8}-bit")

    samples = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0

    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)

    if rate != 16000:
        # Linear resample: correct for a probe, and the device records 16 kHz.
        n = int(round(len(samples) * 16000 / rate))
        if n > 0:
            xp = np.linspace(0.0, len(samples) - 1, num=len(samples))
            x = np.linspace(0.0, len(samples) - 1, num=n)
            samples = np.interp(x, xp, samples).astype(np.float32)

    return samples


def transcribe_file(audio_path):
    """Transcribe a WAV file on disk."""
    result = _model.transcribe(
        decode_wav(audio_path),
        language="en",
        word_timestamps=True,
    )
    return format_result(result, audio_path=audio_path)


def transcribe_pcm(pcm_data, sample_rate):
    """Transcribe raw PCM s16le mono audio data.

    The array goes straight to the model — no temp WAV, no PyAV, no soundfile.
    """
    import numpy as np

    # Decode base64 if string, otherwise assume bytes
    if isinstance(pcm_data, str):
        raw_bytes = base64.b64decode(pcm_data)
    else:
        raw_bytes = pcm_data

    samples = np.frombuffer(raw_bytes, dtype=np.int16).astype(np.float32) / 32768.0

    result = _model.transcribe(
        samples,
        language="en",
        word_timestamps=True,
    )
    return format_result(result, audio_path=None)


def segment_confidence(seg):
    """A segment's confidence, from whichever field this faster-whisper exposes.

    `Segment.confidence` existed in one version and not another; `avg_logprob` has
    been there throughout, and `exp(avg_logprob)` is the per-segment probability it
    stands for. Missing both is 0.0 — a confidence this code does not know is not a
    confidence of 1.0.
    """
    import math

    if hasattr(seg, "confidence"):
        return seg.confidence

    logprob = getattr(seg, "avg_logprob", None)
    if logprob is None:
        return 0.0

    return max(0.0, min(1.0, math.exp(logprob)))


def format_result(result, audio_path=None):
    """Format faster_whisper result into our response schema."""
    # result is a tuple of (transcript_text, info_dict) from faster-whisper
    text = ""
    language = "en"

    segments = []
    if isinstance(result, tuple):
        # Faster-whisper returns generator and info
        transcript_segments, info = result
        # Materialise once: faster-whisper hands back a generator, and reading it for
        # the text above leaves nothing for the segment loop — which is how `confidence`
        # sat at 0.0 and `duration_ms` at 0 for every real transcription.
        transcript_segments = list(transcript_segments)
        text = " ".join(seg.text for seg in transcript_segments).strip()
        language = info.language

        for seg in transcript_segments:
            segments.append({
                "start_ms": int(seg.start * 1000),
                "end_ms": int(seg.end * 1000),
                "text": seg.text.strip(),
                "confidence": segment_confidence(seg),
            })
    else:
        # Fallback for unexpected format
        text = result.get("text", "").strip()
        language = result.get("language", "en")
        for seg in result.get("segments", []):
            segments.append({
                "start_ms": int(seg.get("start", 0) * 1000),
                "end_ms": int(seg.get("end", 0) * 1000),
                "text": seg.get("text", "").strip(),
                "confidence": seg.get("confidence", 0.0),
            })

    # Estimate duration from segments
    duration_ms = 0
    if segments:
        duration_ms = segments[-1]["end_ms"]

    # Average confidence across segments
    avg_confidence = 0.0
    if segments:
        avg_confidence = sum(s["confidence"] for s in segments) / len(segments)

    return {
        "type": "result",
        "text": text,
        "language": language,
        "confidence": round(avg_confidence, 4),
        "duration_ms": duration_ms,
        "segments": segments,
    }


def handle_command(cmd):
    """Process a single command dict and return response dict."""
    command = cmd.get("command")

    if command == "ping":
        return {"type": "pong"}

    elif command == "transcribe":
        audio_path = cmd.get("audio_path")
        if not audio_path:
            return {"type": "error", "message": "Missing audio_path", "code": "missing_param"}
        try:
            return transcribe_file(audio_path)
        except Exception as e:
            return {"type": "error", "message": str(e), "code": "transcription_failed"}

    elif command == "transcribe_pcm":
        data = cmd.get("data")
        sample_rate = cmd.get("sample_rate", 16000)
        if not data:
            return {"type": "error", "message": "Missing data", "code": "missing_param"}
        try:
            return transcribe_pcm(data, sample_rate)
        except Exception as e:
            return {"type": "error", "message": str(e), "code": "transcription_failed"}

    else:
        return {"type": "error", "message": f"Unknown command: {command}", "code": "unknown_command"}


def main():
    # Load model at startup
    model = load_model()
    # Signal ready
    ready_msg = json.dumps({"type": "ready", "model": model})
    sys.stdout.write(ready_msg + "\n")
    sys.stdout.flush()

    # Process commands line by line
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            cmd = json.loads(line)
            response = handle_command(cmd)
        except json.JSONDecodeError as e:
            response = {"type": "error", "message": f"Invalid JSON: {e}", "code": "parse_error"}
        except Exception as e:
            response = {"type": "error", "message": str(e), "code": "unexpected_error"}

        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()