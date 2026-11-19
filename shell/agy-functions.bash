#!/usr/bin/env bash
# ==============================================================================
# Funções de Integração do Antigravity CLI com Gemini Tier Proxy
# ==============================================================================

# Alterna o modo de fallback em tempo de execução sem reiniciar o systemd
agy-fallback() {
  local toggle="${HOME}/.local/share/gemini-tier-proxy/auto-fallback"
  mkdir -p "$(dirname "$toggle")"
  case "${1:-}" in
    on|true|1)
      echo "true" > "$toggle"
      echo "Auto-fallback: ATIVADO (true)"
      ;;
    off|false|0)
      echo "false" > "$toggle"
      echo "Auto-fallback: DESATIVADO (false)"
      ;;
    status|"")
      local current="true"
      [ -f "$toggle" ] && current=$(cat "$toggle")
      echo "Auto-fallback atual: $current"
      ;;
    *)
      echo "Uso: agy-fallback [on|off|status]"
      return 1
      ;;
  esac
}

# Inicia o agy roteando via proxy local FLEX (porta 8787)
# Suporta flag --no-fallback (ou --strict / -nf) para desligar o fallback nesta sessão
agy-flex() {
  if [ -z "${GEMINI_API_KEY:-}" ]; then
    echo "Erro: GEMINI_API_KEY não está definida no ambiente." >&2
    return 1
  fi

  local toggle="${HOME}/.local/share/gemini-tier-proxy/auto-fallback"
  local prev_state="true"
  [ -f "$toggle" ] && prev_state=$(cat "$toggle")

  local filtered_args=()
  local custom_fallback=""

  for arg in "$@"; do
    case "$arg" in
      --no-fallback|--strict|-nf)
        custom_fallback="false"
        ;;
      --fallback|-f)
        custom_fallback="true"
        ;;
      *)
        filtered_args+=("$arg")
        ;;
    esac
  done

  if [ -n "$custom_fallback" ]; then
    echo "$custom_fallback" > "$toggle"
    trap 'systemctl --user stop gemini-tier-proxy-flex.service 2>/dev/null; echo "'"$prev_state"'" > "'"$toggle"'"' RETURN
  else
    trap 'systemctl --user stop gemini-tier-proxy-flex.service 2>/dev/null' RETURN
  fi

  if ! systemctl --user is-active --quiet gemini-tier-proxy-flex.service; then
    systemctl --user start gemini-tier-proxy-flex.service
    sleep 0.3
  fi

  GOOGLE_GEMINI_BASE_URL="http://127.0.0.1:8787" \
  AGY_MODE=api \
  agy --settings '{"modelProvider":"gemini","statusLine":{"command":"/home/'"$USER"'/.gemini/antigravity-cli/statusline.sh --api","stack_with_default":true}}' "${filtered_args[@]}"
}

# Inicia o agy roteando via proxy local PRIORITY (porta 8788)
agy-priority() {
  if [ -z "${GEMINI_API_KEY:-}" ]; then
    echo "Erro: GEMINI_API_KEY não está definida no ambiente." >&2
    return 1
  fi

  trap 'systemctl --user stop gemini-tier-proxy-priority.service 2>/dev/null' RETURN
  if ! systemctl --user is-active --quiet gemini-tier-proxy-priority.service; then
    systemctl --user start gemini-tier-proxy-priority.service
    sleep 0.3
  fi

  GOOGLE_GEMINI_BASE_URL="http://127.0.0.1:8788" \
  AGY_MODE=api \
  agy --settings '{"modelProvider":"gemini","statusLine":{"command":"/home/'"$USER"'/.gemini/antigravity-cli/statusline.sh --api","stack_with_default":true}}' "$@"
}

# Inicia o agy direto na cota STANDARD oficial sem proxy
agy-standard() {
  if [ -z "${GEMINI_API_KEY:-}" ]; then
    echo "Erro: GEMINI_API_KEY não está definida no ambiente." >&2
    return 1
  fi

  env -u GOOGLE_GEMINI_BASE_URL \
  AGY_MODE=api \
  agy --settings '{"modelProvider":"gemini","statusLine":{"command":"/home/'"$USER"'/.gemini/antigravity-cli/statusline.sh --api","stack_with_default":true}}' "$@"
}
