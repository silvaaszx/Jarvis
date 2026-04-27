#!/usr/bin/env python3
# Run with: desktop/wake-word/.venv/bin/python3 jarvis_wake_word.py
"""
Jarvis Wake Word Service
Detects "hey jarvis" offline via openWakeWord, then activates the Jarvis desktop app.

Usage:
    python3 jarvis_wake_word.py

Requirements:
    pip install openwakeword pyaudio numpy

On first run, openWakeWord downloads the "hey_jarvis" ONNX model (~30MB).
"""

import signal
import subprocess
import sys
import time
import random
import threading
import numpy as np

try:
    import pyaudio
except ImportError:
    print("pyaudio not found. Run: pip install pyaudio")
    sys.exit(1)

try:
    from openwakeword.model import Model
except ImportError:
    print("openwakeword not found. Run: pip install openwakeword")
    sys.exit(1)

# ─── Config ───────────────────────────────────────────────────────────────────

WAKE_WORD_MODEL = "hey_jarvis"   # built-in openWakeWord model
THRESHOLD       = 0.5            # detection confidence threshold (0-1)
SAMPLE_RATE     = 16000
CHUNK_SIZE      = 1280           # 80ms at 16kHz (required by openWakeWord)
COOLDOWN_SECS   = 3              # ignore detections for N secs after trigger

# Jarvis greeting responses (chosen randomly on each wake)
GREETINGS = [
    "Here, sir.",
    "Às suas ordens, Sr. Matheus.",
    "Prontíssimo.",
    "O que posso fazer por você?",
    "Sir?",
    "Sim, Sr. Matheus.",
    "Presente.",
]

# ─── Activation ───────────────────────────────────────────────────────────────

def activate_jarvis():
    """Bring Jarvis app to foreground and show a greeting notification."""
    greeting = random.choice(GREETINGS)

    # 1. Bring Jarvis desktop app to front (try common bundle IDs)
    bundle_ids = [
        "com.omi.desktop-dev",
        "com.omi.computer-macos",
        "com.omi.Jarvis",
    ]
    for bid in bundle_ids:
        result = subprocess.run(
            ["osascript", "-e", f'tell application id "{bid}" to activate'],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            break

    # 2. Send macOS notification with greeting
    script = f'''
    display notification "{greeting}" with title "JARVIS" subtitle "Wake word detectada" sound name "Tink"
    '''
    subprocess.run(["osascript", "-e", script], capture_output=True)

    # 3. Also print to console
    print(f"\n🤖 JARVIS activated: \"{greeting}\"")


# ─── Main loop ────────────────────────────────────────────────────────────────

def run():
    print("Loading openWakeWord model (first run downloads ~30MB)...")
    model = Model(wakeword_models=[WAKE_WORD_MODEL], inference_framework="onnx")
    print(f"✅ Model loaded. Listening for \"{WAKE_WORD_MODEL}\" (threshold={THRESHOLD})...")
    print("Press Ctrl+C to stop.\n")

    pa = pyaudio.PyAudio()
    stream = pa.open(
        rate=SAMPLE_RATE,
        channels=1,
        format=pyaudio.paInt16,
        input=True,
        frames_per_buffer=CHUNK_SIZE,
    )

    _stop = threading.Event()

    def _shutdown(signum, frame):
        print(f"\nJarvis wake word: sinal {signum} recebido, encerrando...")
        _stop.set()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    last_trigger = 0.0

    try:
        while not _stop.is_set():
            raw = stream.read(CHUNK_SIZE, exception_on_overflow=False)
            audio = np.frombuffer(raw, dtype=np.int16)

            prediction = model.predict(audio)
            score = prediction.get(WAKE_WORD_MODEL, 0.0)

            now = time.time()
            if score >= THRESHOLD and (now - last_trigger) > COOLDOWN_SECS:
                last_trigger = now
                print(f"Wake word detected (score={score:.2f})")
                # Run activation in background so audio loop doesn't pause
                threading.Thread(target=activate_jarvis, daemon=True).start()

    except KeyboardInterrupt:
        print("\nStopping Jarvis wake word service.")
    finally:
        stream.stop_stream()
        stream.close()
        pa.terminate()


if __name__ == "__main__":
    run()
