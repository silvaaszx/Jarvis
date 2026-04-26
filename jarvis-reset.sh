#!/bin/bash
# jarvis-reset.sh — Reset completo para testar onboarding do zero
# Apaga UserDefaults, SQLite local e cache do app dev.
# Uso: ./jarvis-reset.sh

set -e

DEV_ID="com.omi.desktop-dev"
PROD_ID="com.omi.computer-macos"

echo "=== Jarvis Reset — Onboarding Fresh Start ==="

# Mata o app dev se estiver rodando
echo "▶ Encerrando Jarvis Dev..."
pkill -f "Omi Dev" 2>/dev/null || true
pkill -f "jarvis_wake_word.py" 2>/dev/null || true
pkill -f "jarvis_sound_trigger.py" 2>/dev/null || true
sleep 0.5

# Para os daemons launchd
launchctl stop com.jarvis.wakeword     2>/dev/null || true
launchctl stop com.jarvis.soundtrigger 2>/dev/null || true

# Apaga UserDefaults (onboarding, auth state, preferências)
echo "▶ Limpando UserDefaults..."
defaults delete "$DEV_ID" 2>/dev/null && echo "  ✓ $DEV_ID" || echo "  · $DEV_ID (já vazio)"

# Apaga banco SQLite local (conversas, memórias, dados do usuário)
echo "▶ Removendo banco de dados local..."
DB_DIR="$HOME/Library/Application Support/Omi"
if [ -d "$DB_DIR" ]; then
    rm -rf "$DB_DIR"
    echo "  ✓ $DB_DIR removido"
else
    echo "  · Banco não encontrado (OK)"
fi

# Apaga Keychain entries do app dev (tokens Firebase/auth)
echo "▶ Limpando Keychain..."
security delete-generic-password -s "$DEV_ID" 2>/dev/null && echo "  ✓ Keychain limpo" || echo "  · Keychain (nada encontrado)"

# Apaga caches
echo "▶ Removendo caches..."
for id in "$DEV_ID" "$PROD_ID"; do
    CACHE="$HOME/Library/Caches/$id"
    [ -d "$CACHE" ] && rm -rf "$CACHE" && echo "  ✓ Cache $id" || true
done

# Reset permissões TCC (Acessibilidade, Microfone, Calendário, etc.)
echo "▶ Resetando permissões TCC..."
tccutil reset All "$DEV_ID" 2>/dev/null && echo "  ✓ TCC reset" || echo "  · TCC (requer SIP desabilitado ou sudo)"

echo ""
echo "====================================================="
echo "✅ Reset concluído. Jarvis será aberto como novo usuário."
echo ""
echo "Próximo passo:"
echo "  cd desktop && ./run.sh"
echo "====================================================="
