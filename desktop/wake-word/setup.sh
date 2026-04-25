#!/bin/bash
# Instala dependências do serviço de wake word do Jarvis
set -e

echo "=== Jarvis Wake Word — Setup ==="

# PortAudio (necessário para pyaudio)
if ! brew list portaudio &>/dev/null; then
    echo "Installing portaudio via brew..."
    brew install portaudio
fi

# Python deps
echo "Installing Python dependencies..."
pip3 install openwakeword pyaudio numpy --break-system-packages 2>/dev/null \
  || pip3 install openwakeword pyaudio numpy

# Download modelo hey_jarvis antecipadamente
echo "Pre-downloading hey_jarvis model..."
python3 - <<'PYEOF'
from openwakeword.model import Model
m = Model(wakeword_models=["hey_jarvis"], inference_framework="onnx")
print("Model ready:", list(m.models.keys()))
PYEOF

echo ""
echo "✅ Setup complete!"
echo "Run the service with:  python3 jarvis_wake_word.py"
echo ""
echo "To run on startup, add to launchd or run in a terminal."
