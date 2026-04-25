#!/bin/bash
# jarvis-clean.sh — Limpeza inteligente do projeto Jarvis
# Remove SOMENTE compilados (mantém artifacts SDK de 3.4GB)
# Uso: ./jarvis-clean.sh [--xcode] [--logs] [--all]

set -e

JARVIS_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$JARVIS_ROOT/desktop/Desktop/.build"
LOG_MAX_MB=50  # Rotacionar logs maiores que isso

# ─── Verificação de espaço disponível ─────────────────────────────────────────
AVAIL_GB=$(df -g "$JARVIS_ROOT" | awk 'NR==2{print $4}')
if [ "$AVAIL_GB" -lt 5 ]; then
    echo "⚠️  ATENÇÃO: Menos de 5GB disponível ($AVAIL_GB GB). Executando limpeza agressiva..."
    FORCE_ALL=1
fi

echo "=== Jarvis Clean ===================================="
echo "Root: $JARVIS_ROOT"
echo "Espaço disponível: ${AVAIL_GB}GB"
echo "====================================================="

# ─── Compilados Swift (mantém artifacts) ─────────────────────────────────────
clean_build() {
    echo ""
    echo "▶ Limpando compilados Swift..."
    local freed=0

    for dir in debug arm64-apple-macosx repositories checkouts; do
        local path="$BUILD_DIR/$dir"
        if [ -d "$path" ]; then
            local size_mb=$(du -sm "$path" 2>/dev/null | awk '{print $1}')
            rm -rf "$path"
            echo "  ✓ Removido .build/$dir (${size_mb}MB)"
            freed=$((freed + size_mb))
        fi
    done

    echo "  Liberado: ~${freed}MB (artifacts SDK mantidos em .build/artifacts/)"
}

# ─── Logs /tmp ────────────────────────────────────────────────────────────────
clean_logs() {
    echo ""
    echo "▶ Limpando logs /tmp..."

    for log in /tmp/jarvis*.log /tmp/omi*.log; do
        [ -f "$log" ] || continue
        local size_mb=$(du -sm "$log" 2>/dev/null | awk '{print $1}')
        if [ "$size_mb" -gt "$LOG_MAX_MB" ]; then
            # Rotacionar: guarda só as últimas 1000 linhas
            tail -1000 "$log" > "${log}.tmp" && mv "${log}.tmp" "$log"
            echo "  ✓ Rotacionado $log (era ${size_mb}MB → truncado)"
        else
            echo "  · $log: ${size_mb}MB (OK)"
        fi
    done

    # Remover logs antigos do wake word se > 7 dias
    find /tmp -name "jarvis-*.log" -mtime +7 -delete 2>/dev/null && echo "  ✓ Logs wake word > 7 dias removidos"
}

# ─── Xcode DerivedData (agressivo, somente se --xcode ou --all) ──────────────
clean_xcode() {
    local derived="$HOME/Library/Developer/Xcode/DerivedData"
    if [ -d "$derived" ]; then
        local size=$(du -sh "$derived" 2>/dev/null | awk '{print $1}')
        echo ""
        echo "▶ Limpando Xcode DerivedData ($size)..."
        rm -rf "$derived"
        echo "  ✓ DerivedData removido ($size liberados)"
    fi
}

# ─── Rewind videos > 7 dias ──────────────────────────────────────────────────
clean_rewind() {
    local rewind_dir="$HOME/Library/Application Support/com.memoryvault.MemoryVault"
    if [ -d "$rewind_dir" ]; then
        local count=$(find "$rewind_dir" -name "*.mp4" -mtime +7 2>/dev/null | wc -l | tr -d ' ')
        if [ "$count" -gt 0 ]; then
            local size=$(find "$rewind_dir" -name "*.mp4" -mtime +7 -exec du -ch {} + 2>/dev/null | tail -1 | awk '{print $1}')
            find "$rewind_dir" -name "*.mp4" -mtime +7 -delete 2>/dev/null
            echo "  ✓ $count Rewind videos > 7 dias removidos (~$size)"
        fi
    fi
}

# ─── Parse argumentos ─────────────────────────────────────────────────────────
DO_XCODE=0
DO_LOGS=1
DO_BUILD=1

for arg in "$@"; do
    case "$arg" in
        --xcode) DO_XCODE=1 ;;
        --logs)  DO_LOGS=1; DO_BUILD=0 ;;
        --all)   DO_XCODE=1; DO_LOGS=1; DO_BUILD=1 ;;
        --help)
            echo "Uso: $0 [--xcode] [--logs] [--all]"
            echo "  (sem flags) : remove compilados + rota logs"
            echo "  --xcode     : também limpa Xcode DerivedData (30-60GB)"
            echo "  --logs      : limpa logs apenas"
            echo "  --all       : tudo acima"
            exit 0 ;;
    esac
done

[ "$FORCE_ALL" = "1" ] && { DO_XCODE=1; DO_LOGS=1; DO_BUILD=1; }

[ "$DO_BUILD" = "1" ] && clean_build
[ "$DO_LOGS"  = "1" ] && clean_logs
[ "$DO_XCODE" = "1" ] && clean_xcode
clean_rewind  # sempre verifica Rewind

echo ""
AVAIL_AFTER=$(df -g "$JARVIS_ROOT" | awk 'NR==2{print $4}')
echo "====================================================="
echo "✅ Limpeza concluída. Espaço: ${AVAIL_GB}GB → ${AVAIL_AFTER}GB"
echo "====================================================="
