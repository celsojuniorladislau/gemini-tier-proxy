# Gemini Tier Proxy para Antigravity CLI (`agy`)

> Proxy HTTP reverso local para usar o **Antigravity CLI (`agy`)** com os modos de serviço **FLEX** e **PRIORITY** da Google Gemini API, contando com ciclo de vida sob demanda no `systemd --user`, mascaramento de chaves nos logs e auto-fallback inteligente.

---

## 🎯 Por que este projeto existe?

A Google Gemini API introduziu diferentes **Service Tiers** para inferência com modelos como `gemini-3.8-flash` e `gemini-4-hydrogen`:

| Tier | Preço | Latência | Comportamento |
|---|---|---|---|
| **`flex`** | **50% de desconto** | Variável (minutos a segundos) | Utiliza capacidade computacional ociosa (*sheddable compute*). Ideal para tarefas de agentes de IA, compilações e raciocínio profundo onde latência não é crítica. |
| **`standard`** | Preço padrão | Segundos | Fila de computação normal interativa. |
| **`priority`** | Premium (+75% a 100%) | Baixíssima (segundos) | Alta prioridade de agendamento em GPUs para produção crítica. |

O **Antigravity CLI (`agy`)** por padrão se conecta diretamente ao endpoint padrão da Google via OAuth ou API Key. Este proxy atua como uma ponte intermediária local através da variável `GOOGLE_GEMINI_BASE_URL`, interceptando as chamadas e injetando dinamicamente o parâmetro `serviceTier` correspondente sem você precisar reescrever o CLI.

---

## 📐 Arquitetura

```mermaid
flowchart TD
    subgraph Shell["Sessão do Usuário (Bash / Zsh)"]
        CMD{"Comando"}
        CMD -->|agy| OAUTH["agy puro (OAuth / Conta Google)"]
        CMD -->|agy-flex| W1["Wrapper agy-flex"]
        CMD -->|agy-priority| W2["Wrapper agy-priority"]
        CMD -->|agy-standard| W3["Wrapper agy-standard"]
    end

    subgraph Systemd["systemd --user (Ciclo Sob Demanda)"]
        W1 -->|Sobe e derruba ao sair| P1["gemini-tier-proxy-flex.service\n(Porta 8787)"]
        W2 -->|Sobe e derruba ao sair| P2["gemini-tier-proxy-priority.service\n(Porta 8788)"]
    end

    subgraph Proxy["Proxy Local (Bun / Node.js)"]
        P1 -->|Injeta serviceTier: 'flex'| UP["Encaminha para Upstream"]
        P1 -.->|Se 503 / 429: Auto-Fallback| FB["Fallback para Standard"]
        P2 -->|Injeta serviceTier: 'priority'| UP
    end

    subgraph Google["Google Gemini API (v1beta)"]
        UP -->|HTTPS 443| API["generativelanguage.googleapis.com"]
        FB -->|HTTPS 443| API
        OAUTH -->|Direto| API
        W3 -->|Direto (API Key)| API
    end
```

---

## ⚙️ Principais Funcionalidades

1. **Injeção Transparente de Tiers**:
   - Porta `8787` $\rightarrow$ Injeta `serviceTier: "flex"` (50% de desconto na API).
   - Porta `8788` $\rightarrow$ Injeta `serviceTier: "priority"`.
2. **Auto-Fallback Inteligente**:
   - Como a fila FLEX utiliza capacidade ociosa, em momentos de pico ela pode retornar `503 Service Unavailable` ou `429 Too Many Requests`.
   - Com o auto-fallback ativado (padrão), o proxy detecta o `503/429`, descarta a injeção do tier e repassa a requisição imediatamente como `STANDARD`, garantindo que o agente continue trabalhando sem travar sua sessão.
3. **Alternância Instantânea (Zero Restart)**:
   - Suporte à flag `--no-fallback` diretamente no comando `agy-flex`.
   - Utilitário `agy-fallback on/off/status` para testes rápidos sem precisar recarregar serviços `systemd`.
4. **Ciclo de Vida 100% Sob Demanda**:
   - Os serviços `systemd --user` não consomem memória quando você não está usando o CLI.
   - Ao executar `agy-flex` ou `agy-priority`, o proxy sobe em milissegundos. Ao sair do `agy` (`/exit`, `Ctrl+C` ou término de comando), o shell executa um `trap` e desliga o serviço imediatamente.
5. **Segurança e Mascaramento de Chaves**:
   - O proxy filtra os logs do `journalctl` substituindo qualquer ocorrência de `?key=...` por `key=***`, prevenindo vazamento acidental da sua `GEMINI_API_KEY`.
6. **Preservação do OAuth Padrão**:
   - O comando `agy` nativo continua usando a sua conta do Google via OAuth.
   - Os comandos com sufixo (`agy-flex`, `agy-priority`, `agy-standard`, `agy-api`) usam a chave `GEMINI_API_KEY` de forma isolada via CLI arguments.
7. **Suporte Nativo a Bun (Runtime Recomendado)**:
   - Suporte nativo ao **Bun** como engine de execução padrão, proporcionando inicialização ultrarrápida (~10-15ms) e menor consumo de RAM (~12-45MB vs ~60MB do Node.js).
   - Mantém fallback transparente para **Node.js** (>= 18) caso o Bun não esteja instalado na máquina.

---

## 🧠 Lições Técnicas & Gotchas Críticos (Para Humanos e Agentes de IA)

Caso você esteja replicando esta arquitetura em outro ambiente, atente-se a estes pontos fundamentais:

> [!WARNING]
> ### 1. Case Sensitivity do Protobuf da Gemini API (`serviceTier`)
> O schema protobuf `google.ai.generativelanguage.v1beta.ServiceTier` mapeado em JSON **exige valores em minúsculas**: `"flex"` e `"priority"`.
> Se você enviar em maiúsculas (`"FLEX"` ou `"PRIORITY"`), o validador do Google rejeitará com `HTTP 400 Bad Request`:
> `Invalid value at 'service_tier' (type.googleapis.com/google.ai.generativelanguage.v1beta.ServiceTier), "FLEX"`
> **Solução implementada:** O proxy sempre sanitiza com `.toLowerCase()`.

> [!NOTE]
> ### 2. Caminho Absoluto do Runtime (Bun / Node.js) no systemd
> O gerenciador de serviços do usuário (`systemd --user`) não herda o ambiente interativo nem variáveis de shell como NVM, asdf, fnm ou `~/.bun/bin`. Portanto, nas units do systemd, o `ExecStart` deve apontar para o binário absoluto do Bun (ex: `/home/user/.bun/bin/bun`) ou Node.js (ex: `/usr/bin/node`), o que o script `install.sh` detecta e configura automaticamente.

> [!TIP]
> ### 3. Timeouts no Modo FLEX
> Como a fila FLEX pode enfileirar requisições por vários minutos antes de liberar capacidade de GPU, o servidor HTTP precisa desativar os timeouts padrão:
> ```javascript
> server.requestTimeout = 0;
> server.headersTimeout = 0;
> ```
> E configurar o timeout da requisição upstream para 15 minutos (`900_000ms`).

---

## 🚀 Instalação Rápida (1 Comando)

### Pré-requisitos
- Linux (Ubuntu, Debian, Zorin OS, Fedora, etc.) com `systemd --user`.
- **Bun** (recomendado para inicialização ultrarrápida em ~10-15ms e menor consumo de RAM) ou **Node.js** >= 18.
- Antigravity CLI instalado (`agy`).
- Variável `GEMINI_API_KEY` configurada no seu perfil de shell (`~/.bashrc` ou `~/.zshrc`).

### Clonar e Instalar
```bash
git clone https://github.com/celsojuniorladislau/gemini-tier-proxy.git
cd gemini-tier-proxy
./scripts/install.sh
source ~/.bashrc
```

O script cuidará de:
1. Detectar o runtime disponível (priorizando Bun nativamente, com fallback transparente para Node.js >= 18).
2. Copiar o script para `~/.local/share/gemini-tier-proxy/`.
3. Gerar e recarregar os serviços `gemini-tier-proxy-flex.service` e `gemini-tier-proxy-priority.service` no `systemd --user`.
4. Injetar as funções de shell no `~/.bashrc` (ou `~/.zshrc`).

---

## 💻 Guia de Uso

### 1. Comandos Principais no Terminal

```bash
# 1. Modo FLEX (Padrão: 50% de desconto + auto-fallback para standard em picos)
agy-flex

# 2. Modo FLEX Estrito (Desativa o auto-fallback apenas para esta sessão)
agy-flex --no-fallback
# ou: agy-flex --strict

# 3. Modo PRIORITY (Alta prioridade e baixa latência)
agy-priority

# 4. Modo STANDARD com API Key (Direto no Google, cota padrão)
agy-standard

# 5. Modo Normal (Conta Google via login OAuth)
agy
```

---

### 2. Controle Rápido do Auto-Fallback

Você pode ligar ou desligar o auto-fallback sem reiniciar nenhum serviço:

```bash
# Desligar auto-fallback (fica FLEX puro)
agy-fallback off

# Ligar auto-fallback
agy-fallback on

# Ver status atual
agy-fallback status
```

---

### 3. Teste Manual com `curl`

Você pode testar diretamente o proxy local com uma chamada SSE:

```bash
# 1. Inicie o proxy temporariamente
systemctl --user start gemini-tier-proxy-flex.service

# 2. Envie uma requisição streaming
curl -i -N -X POST \
  "http://127.0.0.1:8787/v1beta/models/gemini-3.8-flash:streamGenerateContent?alt=sse&key=$GEMINI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"contents":[{"parts":[{"text":"Responda apenas: ok"}]}]}'

# 3. Pare o proxy
systemctl --user stop gemini-tier-proxy-flex.service
```

---

### 4. Monitoramento e Logs

Para acompanhar as requisições em tempo real e verificar o mascaramento da chave:

```bash
# Logs do Proxy FLEX
journalctl --user -u gemini-tier-proxy-flex.service -f

# Logs do Proxy PRIORITY
journalctl --user -u gemini-tier-proxy-priority.service -f
```

---

## 🗑️ Desinstalação

Se quiser remover completamente o proxy do seu sistema:
```bash
./scripts/uninstall.sh
source ~/.bashrc
```

---

## 📄 Licença

Distribuído sob a licença [MIT](LICENSE).
