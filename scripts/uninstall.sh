#!/usr/bin/env bash
set -euo pipefail

echo "=========================================================="
echo "Desinstalação do Gemini Tier Proxy"
echo "=========================================================="

# 1. Parar e desativar serviços
systemctl --user stop gemini-tier-proxy-flex.service gemini-tier-proxy-priority.service 2>/dev/null || true
systemctl --user disable gemini-tier-proxy-flex.service gemini-tier-proxy-priority.service 2>/dev/null || true

# 2. Remover unidades systemd
rm -f "${HOME}/.config/systemd/user/gemini-tier-proxy-flex.service"
rm -f "${HOME}/.config/systemd/user/gemini-tier-proxy-priority.service"
systemctl --user daemon-reload
echo "✓ Serviços systemd removidos."

# 3. Remover diretório de instalação
rm -rf "${HOME}/.local/share/gemini-tier-proxy"
echo "✓ Arquivos locais removidos."

# 4. Limpar shell rc
SHELL_RC="${HOME}/.bashrc"
if [ "${SHELL##*/}" = "zsh" ] && [ -f "${HOME}/.zshrc" ]; then
  SHELL_RC="${HOME}/.zshrc"
fi

START_MARKER="# >>> Gemini Tier Proxy Functions >>>"
END_MARKER="# <<< Gemini Tier Proxy Functions <<<"

if grep -q "$START_MARKER" "$SHELL_RC"; then
  sed -i "/$START_MARKER/,/$END_MARKER/d" "$SHELL_RC"
  echo "✓ Bloco de funções removido de $SHELL_RC."
fi

echo "=========================================================="
echo "Desinstalação concluída com sucesso."
echo "=========================================================="
