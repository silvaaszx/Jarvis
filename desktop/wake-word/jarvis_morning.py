#!/usr/bin/env python3
"""
Jarvis Morning Briefing — Fase 5
Roda diariamente às 8h via launchd. Fala o resumo do dia.

Sem dependências externas além de pyaudio (já no venv).
Usa wttr.in para clima (free, sem auth).
Usa AppleScript para agenda do dia.
Fala via 'say' (macOS) — sem consumir RAM com TTS pesado.

Resource Safety:
- Log máximo: 200 linhas (rotaciona automaticamente)
- Sem retry loops — falha silenciosamente
- Sem arquivos temporários acumulados
"""

import json
import os
import subprocess
import sys
import urllib.request
from datetime import datetime

# ─── Config ───────────────────────────────────────────────────────────────────
LOG_FILE     = "/tmp/jarvis-morning.log"
LOG_MAX_LINES = 200
CITY         = "Brasilia"          # cidade para previsão
SAY_VOICE    = "Luciana"           # voz PT-BR nativa do macOS


# ─── Log com rotação ──────────────────────────────────────────────────────────
def _log(msg: str):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{timestamp}] {msg}\n"
    print(line, end="", flush=True)  # stdout → /tmp/jarvis-morning.log via plist

    # Rotacionar log se exceder limite (Resource Safety)
    try:
        if os.path.exists(LOG_FILE):
            with open(LOG_FILE, "r", encoding="utf-8", errors="ignore") as f:
                lines = f.readlines()
            if len(lines) >= LOG_MAX_LINES:
                with open(LOG_FILE, "w", encoding="utf-8") as f:
                    f.writelines(lines[-(LOG_MAX_LINES // 2):])
    except Exception:
        pass


# ─── Clima ────────────────────────────────────────────────────────────────────
def get_weather() -> str:
    try:
        url = f"https://wttr.in/{CITY}?format=j1"
        req = urllib.request.Request(url, headers={"User-Agent": "Jarvis/1.0"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode())
        current = data["current_condition"][0]
        temp_c  = current["temp_C"]
        desc    = current["weatherDesc"][0]["value"]
        feels   = current["FeelsLikeC"]
        # Tradução simples das condições mais comuns
        translations = {
            "Sunny": "ensolarado", "Clear": "céu limpo",
            "Partly cloudy": "parcialmente nublado", "Cloudy": "nublado",
            "Overcast": "encoberto", "Mist": "névoa",
            "Light rain": "chuva leve", "Moderate rain": "chuva moderada",
            "Heavy rain": "chuva forte", "Thundery outbreaks": "trovoadas",
            "Blowing snow": "neve com vento", "Light snow": "neve leve",
            "Fog": "neblina",
        }
        desc_pt = translations.get(desc, desc)
        return f"{temp_c}°C, {desc_pt}, sensação de {feels}°C"
    except Exception as e:
        _log(f"clima: erro {e}")
        return "clima indisponível"


# ─── Agenda (Apple Calendar via AppleScript) ──────────────────────────────────
def get_calendar_events() -> list[str]:
    script = '''
    set today to current date
    set startOfDay to today - (time of today)
    set endOfDay to startOfDay + (23 * hours) + (59 * minutes)
    set eventList to {}
    tell application "Calendar"
        repeat with cal in calendars
            set events_ to (every event of cal whose start date ≥ startOfDay and start date ≤ endOfDay)
            repeat with ev in events_
                set evTime to time string of (start date of ev)
                set evName to summary of ev
                set end of eventList to (evTime & " — " & evName)
            end repeat
        end repeat
    end tell
    set output to ""
    repeat with item_ in eventList
        set output to output & item_ & linefeed
    end repeat
    return output
    '''
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0 and result.stdout.strip():
            return [line.strip() for line in result.stdout.strip().splitlines() if line.strip()]
        return []
    except Exception as e:
        _log(f"calendar: erro {e}")
        return []


# ─── Falar ────────────────────────────────────────────────────────────────────
def speak(text: str):
    """Fala via macOS 'say' com voz PT-BR. Sem API key, sem RAM extra."""
    try:
        subprocess.run(
            ["say", "-v", SAY_VOICE, text],
            timeout=60, check=False
        )
    except Exception as e:
        _log(f"say: erro {e}")


def notify(title: str, body: str):
    script = f'display notification "{body}" with title "{title}" sound name "Glass"'
    subprocess.run(["osascript", "-e", script], capture_output=True)


# ─── Briefing ─────────────────────────────────────────────────────────────────
def build_briefing(weather: str, events: list[str]) -> str:
    now   = datetime.now()
    hora  = now.strftime("%H:%M")
    dia   = now.strftime("%A, %d de %B").lower()

    lines = [f"Bom dia, Sr. Matheus. São {hora} de {dia}."]
    lines.append(f"O clima em Brasília está {weather}.")

    if events:
        lines.append(f"Você tem {len(events)} compromisso{'s' if len(events) > 1 else ''} hoje.")
        for ev in events[:5]:   # máximo 5 eventos falados
            lines.append(ev)
    else:
        lines.append("Agenda livre hoje. Bom dia para focar no que importa.")

    return " ".join(lines)


# ─── Main ─────────────────────────────────────────────────────────────────────
def main():
    _log("Jarvis Morning Briefing iniciando")

    weather = get_weather()
    _log(f"Clima: {weather}")

    events = get_calendar_events()
    _log(f"Eventos: {len(events)}")

    briefing = build_briefing(weather, events)
    _log(f"Briefing: {briefing}")

    notify("JARVIS — Bom dia", f"Clima: {weather} | {len(events)} evento(s)")
    speak(briefing)

    _log("Concluído")


if __name__ == "__main__":
    main()
