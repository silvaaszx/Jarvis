#!/usr/bin/env python3
"""
Jarvis Sound Trigger — Fase 4
Detecta palmas duplas e assobio para acionar o Jarvis sem falar.

Uso:
    desktop/wake-word/.venv/bin/python3 jarvis_sound_trigger.py

Requisitos:
    pip install pyaudio numpy scipy

Sem librosa — usa scipy.signal (mais leve, já vem com numpy).
"""

import signal
import subprocess
import sys
import time
import threading
import numpy as np

try:
    import pyaudio
except ImportError:
    print("pyaudio não encontrado. Execute: pip install pyaudio")
    sys.exit(1)

try:
    from scipy.signal import butter, sosfilt
except ImportError:
    print("scipy não encontrado. Execute: pip install scipy")
    sys.exit(1)

# ─── Config ───────────────────────────────────────────────────────────────────

SAMPLE_RATE   = 16000
CHUNK_SIZE    = 512          # ~32ms por chunk
CHANNELS      = 1

# Detecção de palmas (clap)
CLAP_THRESHOLD    = 0.18     # energia RMS mínima para contar como palma
CLAP_FREQ_LOW     = 1500     # Hz — banda de energia da palma
CLAP_FREQ_HIGH    = 5000
CLAP_MIN_INTERVAL = 0.08     # seg mínimo entre duas palmas
CLAP_MAX_INTERVAL = 0.65     # seg máximo entre palmas duplas
CLAP_COOLDOWN     = 2.5      # seg para ignorar após trigger

# Detecção de assobio (whistle)
WHISTLE_THRESHOLD = 0.06     # energia RMS mínima
WHISTLE_FREQ_LOW  = 1200     # Hz — banda do assobio humano
WHISTLE_FREQ_HIGH = 3500
WHISTLE_MIN_DURATION = 0.25  # seg mínimo para contar como assobio
WHISTLE_COOLDOWN  = 2.5

# ─── Filtros passa-banda ──────────────────────────────────────────────────────

def bandpass_energy(audio: np.ndarray, low: int, high: int) -> float:
    """Retorna energia RMS do áudio na banda [low, high] Hz."""
    nyq = SAMPLE_RATE / 2.0
    sos = butter(4, [low / nyq, high / nyq], btype='band', output='sos')
    filtered = sosfilt(sos, audio.astype(np.float32))
    return float(np.sqrt(np.mean(filtered ** 2)))

# ─── Ações ────────────────────────────────────────────────────────────────────

def trigger_clap():
    """Palmas duplas → ativa o Jarvis (mesma lógica do wake word)."""
    print(f"\n👏 Palmas duplas detectadas — ativando Jarvis")
    bundle_ids = ["com.omi.desktop-dev", "com.omi.computer-macos", "com.omi.Jarvis"]
    for bid in bundle_ids:
        r = subprocess.run(
            ["osascript", "-e", f'tell application id "{bid}" to activate'],
            capture_output=True, text=True
        )
        if r.returncode == 0:
            break
    subprocess.run(
        ["osascript", "-e",
         'display notification "Palmas detectadas" with title "JARVIS" '
         'subtitle "Pronto para ouvir" sound name "Tink"'],
        capture_output=True
    )

def trigger_whistle():
    """Assobio → próxima música no Spotify."""
    print(f"\n🎵 Assobio detectado — próxima música")
    subprocess.run(
        ["osascript", "-e", 'tell application "Spotify" to next track'],
        capture_output=True
    )
    subprocess.run(
        ["osascript", "-e",
         'display notification "Próxima música" with title "JARVIS" sound name "Pop"'],
        capture_output=True
    )

# ─── Estado dos detectores ────────────────────────────────────────────────────

class ClapDetector:
    def __init__(self):
        self.last_clap_time = 0.0
        self.pending_clap = False
        self.last_trigger = 0.0

    def feed(self, audio: np.ndarray):
        now = time.time()
        if (now - self.last_trigger) < CLAP_COOLDOWN:
            return

        energy = bandpass_energy(audio, CLAP_FREQ_LOW, CLAP_FREQ_HIGH)
        if energy < CLAP_THRESHOLD:
            return  # silêncio relativo

        dt = now - self.last_clap_time

        if self.pending_clap and dt <= CLAP_MAX_INTERVAL:
            # Segunda palma dentro da janela → palmas duplas!
            self.pending_clap = False
            self.last_trigger = now
            threading.Thread(target=trigger_clap, daemon=True).start()
        elif dt > CLAP_MIN_INTERVAL:
            # Primeira palma — aguarda segunda
            self.pending_clap = True
            self.last_clap_time = now


class WhistleDetector:
    def __init__(self):
        self.whistle_start = 0.0
        self.in_whistle = False
        self.last_trigger = 0.0

    def feed(self, audio: np.ndarray):
        now = time.time()
        if (now - self.last_trigger) < WHISTLE_COOLDOWN:
            return

        energy = bandpass_energy(audio, WHISTLE_FREQ_LOW, WHISTLE_FREQ_HIGH)

        if energy >= WHISTLE_THRESHOLD:
            if not self.in_whistle:
                self.in_whistle = True
                self.whistle_start = now
            elif (now - self.whistle_start) >= WHISTLE_MIN_DURATION:
                # Assobio sustentado suficiente → trigger
                self.last_trigger = now
                self.in_whistle = False
                threading.Thread(target=trigger_whistle, daemon=True).start()
        else:
            self.in_whistle = False

# ─── Main loop ────────────────────────────────────────────────────────────────

def run():
    print("Jarvis Sound Trigger iniciando...")
    print(f"  Palmas duplas → ativa Jarvis")
    print(f"  Assobio        → próxima música")
    print("Pressione Ctrl+C para parar.\n")

    pa = pyaudio.PyAudio()
    stream = pa.open(
        rate=SAMPLE_RATE,
        channels=CHANNELS,
        format=pyaudio.paInt16,
        input=True,
        frames_per_buffer=CHUNK_SIZE,
    )

    clap = ClapDetector()
    whistle = WhistleDetector()

    _stop = threading.Event()

    def _shutdown(signum, frame):
        print(f"\nJarvis Sound Trigger: sinal {signum} recebido, encerrando...")
        _stop.set()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    try:
        while not _stop.is_set():
            raw = stream.read(CHUNK_SIZE, exception_on_overflow=False)
            audio = np.frombuffer(raw, dtype=np.int16) / 32768.0  # normalizar -1..1
            clap.feed(audio)
            whistle.feed(audio)

    except KeyboardInterrupt:
        print("\nJarvis Sound Trigger encerrado.")
    finally:
        stream.stop_stream()
        stream.close()
        pa.terminate()


if __name__ == "__main__":
    run()
