#!/usr/bin/env bash
set -euo pipefail

echo "=========================================================="
echo "Instalação do Gemini Tier Proxy para Antigravity CLI (agy)"
echo "=========================================================="

# 1. Detecção do runtime (Bun preferencial com fallback para Node.js >= 18)
RUNTIME_BIN=""
RUNTIME_NAME=""

if command -v bun >/dev/null 2>&1; then
  RUNTIME_BIN=$(command -v bun)
  BUN_VERSION=$(bun --version)
  RUNTIME_NAME="Bun"
  echo "✓ Bun detectado (recomendado): $RUNTIME_BIN (v$BUN_VERSION)"
elif command -v node >/dev/null 2>&1; then
  NODE_VERSION=$(node -v | sed 's/v//')
  NODE_MAJOR=$(echo "$NODE_VERSION" | cut -d. -f1)
  if [ "$NODE_MAJOR" -lt 18 ]; then
    echo "Erro: Node.js >= 18 é obrigatório como fallback. Versão encontrada: v$NODE_VERSION" >&2
    exit 1
  fi
  RUNTIME_BIN=$(command -v node)
  RUNTIME_NAME="Node.js"
  echo "✓ Bun não encontrado. Fallback para Node.js: $RUNTIME_BIN (v$NODE_VERSION)"
else
  echo "Erro: Nenhum runtime compatível encontrado (instale Bun ou Node.js >= 18)." >&2
  exit 1
fi

# 2. Diretórios de destino
INSTALL_DIR="${HOME}/.local/share/gemini-tier-proxy"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
mkdir -p "$INSTALL_DIR" "$SYSTEMD_USER_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 3. Copiar script do proxy
cp "$SCRIPT_DIR/src/gemini-tier-proxy.mjs" "$INSTALL_DIR/gemini-tier-proxy.mjs"
chmod +x "$INSTALL_DIR/gemini-tier-proxy.mjs"
echo "true" > "$INSTALL_DIR/auto-fallback"
echo "✓ Script do proxy instalado em $INSTALL_DIR/gemini-tier-proxy.mjs"

# 4. Configurar unidades systemd user
PROXY_SCRIPT="$INSTALL_DIR/gemini-tier-proxy.mjs"

sed -e "s|{{BUN_BIN}}|$RUNTIME_BIN|g" \
    -e "s|{{NODE_BIN}}|$RUNTIME_BIN|g" \
    -e "s|{{RUNTIME_BIN}}|$RUNTIME_BIN|g" \
    -e "s|{{PROXY_PATH}}|$PROXY_SCRIPT|g" \
    "$SCRIPT_DIR/systemd/gemini-tier-proxy-flex.service.template" > "$SYSTEMD_USER_DIR/gemini-tier-proxy-flex.service"

sed -e "s|{{BUN_BIN}}|$RUNTIME_BIN|g" \
    -e "s|{{NODE_BIN}}|$RUNTIME_BIN|g" \
    -e "s|{{RUNTIME_BIN}}|$RUNTIME_BIN|g" \
    -e "s|{{PROXY_PATH}}|$PROXY_SCRIPT|g" \
    "$SCRIPT_DIR/systemd/gemini-tier-proxy-priority.service.template" > "$SYSTEMD_USER_DIR/gemini-tier-proxy-priority.service"

systemctl --user daemon-reload
echo "✓ Unidades systemd user configuradas e recarregadas."

# 5. Adicionar funções ao arquivo de perfil do shell
SHELL_RC="${HOME}/.bashrc"
if [ "${SHELL##*/}" = "zsh" ] && [ -f "${HOME}/.zshrc" ]; then
  SHELL_RC="${HOME}/.zshrc"
fi

START_MARKER="# >>> Gemini Tier Proxy Functions >>>"
END_MARKER="# <<< Gemini Tier Proxy Functions <<<"

if grep -q "$START_MARKER" "$SHELL_RC"; then
  echo "✓ Funções de shell já presentes em $SHELL_RC (bloco preservado)."
else
  echo "" >> "$SHELL_RC"
  echo "$START_MARKER" >> "$SHELL_RC"
  cat "$SCRIPT_DIR/shell/agy-functions.bash" >> "$SHELL_RC"
  echo "$END_MARKER" >> "$SHELL_RC"
  echo "✓ Funções adicionadas ao final de $SHELL_RC"
fi

echo ""
echo "=========================================================="
echo "Instalação concluída com sucesso!"
echo "Reinicie seu terminal ou execute: source $SHELL_RC"
echo "Comandos disponíveis: agy-flex, agy-priority, agy-standard, agy-fallback"
echo "=========================================================="
