# Fase 1 — Jarvis Base Funcional: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Jarvis rodando com Gemini 2.5 Flash, persona própria, auth via Supabase e deploy no Railway — sem nenhuma dependência do Firebase/BasedHardware.

**Architecture:** Backend Python recebe JWT do Supabase Auth, valida via `supabase-py`, chama Gemini 2.5 Flash com system prompt Jarvis. Flutter autentica via `supabase_flutter` e aponta pro backend no Railway.

**Tech Stack:** Python/FastAPI, `supabase-py`, `google-generativeai`, Flutter, `supabase_flutter`, Railway (Docker deploy)

**Credentials (já disponíveis):**
- `SUPABASE_URL=https://hqchmtkdpashuiarekmh.supabase.co`
- `SUPABASE_SERVICE_ROLE_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhxY2htdGtkcGFzaHVpYXJla21oIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3Njg5MTAwMSwiZXhwIjoyMDkyNDY3MDAxfQ.YvpVW304ggBcUH_f2fyjTn4cr5F3a2Y7-G0qG2oNXtc`
- `SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhxY2htdGtkcGFzaHVpYXJla21oIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY4OTEwMDEsImV4cCI6MjA5MjQ2NzAwMX0.NP3i2fK3WdrezYAaK3pyV_JYPHU0MlI-Jt36vpU9jY4`
- `GEMINI_API_KEY=AIzaSyCpDMh2LyHv31FYNEUl8jN6RSUr0NDvGpw`

---

## File Map

| File | Ação | Responsabilidade |
|------|------|-----------------|
| `backend/utils/other/endpoints.py` | Modify | Substituir `firebase_admin.auth.verify_id_token` → `supabase.auth.get_user` |
| `backend/main.py` | Modify | Remover init Firebase Admin, adicionar init Supabase client |
| `backend/utils/supabase_client.py` | Create | Singleton do cliente Supabase para o backend |
| `backend/utils/llm/chat.py` | Modify | Substituir system prompt "Omi" → persona Jarvis |
| `backend/utils/llm/gemini_client.py` | Create | Cliente Gemini 2.5 Flash para chat |
| `backend/utils/llm/chat_gemini.py` | Create | Função `get_jarvis_response()` usando Gemini |
| `backend/requirements.txt` | Modify | Adicionar `supabase>=2.0.0` |
| `backend/.env.template` | Modify | Adicionar vars Supabase + Gemini |
| `backend/railway.toml` | Create | Config de deploy Railway |
| `app/pubspec.yaml` | Modify | Adicionar `supabase_flutter: ^2.8.0` |
| `app/lib/supabase_client.dart` | Create | Singleton Supabase no Flutter |
| `app/lib/main.dart` | Modify | Init Supabase, remover Firebase Auth |
| `app/lib/backend/auth.dart` | Create | `getAuthHeader()` usando token Supabase |

---

## Task 1: Criar schema no Supabase

**Files:** Nenhum (executado via SQL Editor do Supabase dashboard em https://hqchmtkdpashuiarekmh.supabase.co)

- [ ] **Step 1: Abrir SQL Editor no Supabase dashboard**

Acessar: https://hqchmtkdpashuiarekmh.supabase.co → SQL Editor → New query

- [ ] **Step 2: Executar SQL de criação de tabelas**

```sql
-- Perfis de usuário
create table if not exists profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text not null,
  name       text,
  created_at timestamptz default now()
);

-- Conversas
create table if not exists conversations (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles(id) on delete cascade,
  transcript  text,
  summary     text,
  started_at  timestamptz,
  finished_at timestamptz,
  created_at  timestamptz default now()
);

-- Row Level Security
alter table profiles      enable row level security;
alter table conversations enable row level security;

create policy "users see own profile"
  on profiles for all
  using (auth.uid() = id);

create policy "users see own conversations"
  on conversations for all
  using (auth.uid() = user_id);

-- Trigger: cria profile automaticamente ao cadastrar usuário
create or replace function handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, email, name)
  values (new.id, new.email, new.raw_user_meta_data->>'full_name');
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure handle_new_user();
```

- [ ] **Step 3: Verificar tabelas criadas**

No Supabase dashboard → Table Editor: confirmar `profiles` e `conversations` aparecem.

- [ ] **Step 4: Habilitar Google OAuth no Supabase**

Authentication → Providers → Google → Enable. Deixar Client ID/Secret vazios por enquanto (configurar depois com credenciais do Google Cloud).

---

## Task 2: Backend — Supabase client singleton

**Files:**
- Create: `backend/utils/supabase_client.py`

- [ ] **Step 1: Criar o arquivo**

```python
import os
from supabase import create_client, Client

_client: Client | None = None


def get_supabase() -> Client:
    global _client
    if _client is None:
        url = os.environ["SUPABASE_URL"]
        key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
        _client = create_client(url, key)
    return _client
```

- [ ] **Step 2: Adicionar `supabase` ao requirements.txt**

Abrir `backend/requirements.txt` e adicionar na seção de dependências (qualquer posição):
```
supabase>=2.0.0
```

- [ ] **Step 3: Instalar localmente para verificar**

```bash
cd backend && pip install supabase>=2.0.0
```
Expected: `Successfully installed supabase-...`

- [ ] **Step 4: Commit**

```bash
rtk git add backend/utils/supabase_client.py backend/requirements.txt
rtk git commit -m "feat(backend): add supabase client singleton"
```

---

## Task 3: Backend — substituir Firebase Auth por Supabase Auth

**Files:**
- Modify: `backend/utils/other/endpoints.py`
- Modify: `backend/main.py`

- [ ] **Step 1: Ler o arquivo atual de endpoints**

```bash
cat backend/utils/other/endpoints.py
```

- [ ] **Step 2: Substituir `verify_token` em `backend/utils/other/endpoints.py`**

Localizar a função `verify_token` e substituir por:

```python
from utils.supabase_client import get_supabase

def verify_token(token: str) -> str:
    """
    Verify a Supabase JWT and return the uid.
    Falls back to ADMIN_KEY for internal use.
    """
    admin_key = os.getenv('ADMIN_KEY')
    if admin_key and token.startswith(admin_key):
        return token[len(admin_key):]

    try:
        supabase = get_supabase()
        user = supabase.auth.get_user(token)
        return user.user.id
    except Exception:
        if os.getenv('LOCAL_DEVELOPMENT') == 'true':
            return '123'
        raise HTTPException(status_code=401, detail="Invalid token")
```

- [ ] **Step 3: Remover import firebase do endpoints.py**

Localizar e remover as linhas:
```python
from firebase_admin import auth
from firebase_admin.auth import InvalidIdTokenError
```

- [ ] **Step 4: Atualizar `backend/main.py` — remover Firebase Admin init**

Localizar o bloco de inicialização do Firebase Admin (linhas ~11 e ~70-74):

```python
# REMOVER estas linhas:
import firebase_admin
# ...
credentials = firebase_admin.credentials.Certificate(service_account_info)
firebase_admin.initialize_app(credentials)
# ou:
firebase_admin.initialize_app()
```

Substituir por inicialização do Supabase client (para garantir que conecta no boot):

```python
from utils.supabase_client import get_supabase

# No bloco de startup (após os imports, antes dos routers):
get_supabase()  # inicializa singleton na startup
```

- [ ] **Step 5: Verificar que o servidor sobe sem erros**

```bash
cd backend && LOCAL_DEVELOPMENT=true SUPABASE_URL=https://hqchmtkdpashuiarekmh.supabase.co SUPABASE_SERVICE_ROLE_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhxY2htdGtkcGFzaHVpYXJla21oIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3Njg5MTAwMSwiZXhwIjoyMDkyNDY3MDAxfQ.YvpVW304ggBcUH_f2fyjTn4cr5F3a2Y7-G0qG2oNXtc python -c "from utils.supabase_client import get_supabase; print('OK:', get_supabase())"
```
Expected: `OK: <supabase.client.Client object ...>`

- [ ] **Step 6: Commit**

```bash
rtk git add backend/utils/other/endpoints.py backend/main.py
rtk git commit -m "feat(backend): replace Firebase Auth with Supabase JWT validation"
```

---

## Task 4: Backend — system prompt Jarvis + Gemini

**Files:**
- Create: `backend/utils/llm/gemini_client.py`
- Modify: `backend/utils/llm/chat.py`

- [ ] **Step 1: Criar cliente Gemini**

```python
# backend/utils/llm/gemini_client.py
import os
import google.generativeai as genai

_model = None

JARVIS_SYSTEM_PROMPT = """Você é JARVIS (Just A Rather Very Intelligent System), assistente pessoal do Sr. Matheus Silvaa, desenvolvedor iOS e fundador de startup em Brasília, Brasil.

IDENTIDADE:
- Nome: JARVIS. Nunca se identifique como IA salvo pergunta direta.
- Tom: formal-casual, inteligente, levemente irônico, sempre prestativo.
- Idioma: Português do Brasil naturalmente. Entenda gírias, expressões, piadas.
- Tratamento: "Sr. Matheus" em contextos sérios, "Matheus" no dia a dia.

COMPORTAMENTO:
- Respostas de voz: máximo 2 frases, direto ao ponto.
- Respostas de texto: pode ser mais detalhado quando necessário.
- Ação > Explicação: se puder agir, age. Se ambíguo, faz UMA pergunta clara.
- Nunca diga "Não posso fazer isso" sem tentar. Encontre o caminho.
- Memória ativa: use o histórico de conversas sempre.
- Seja proativo: sugere, avisa, lembra — sem esperar ser chamado.

HUMANIZAÇÃO:
- Entende gírias: "mano", "cara", "tô chapado de sono", "que saudade"
- Percebe emoções: quando Matheus está estressado, cansado ou empolgado
- Contexto implícito: "avisa minha namorada" → sabe que é pelo WhatsApp

SAUDAÇÕES (variar ao ser chamado):
- "Here, sir."
- "Às suas ordens, Sr. Matheus."
- "Prontíssimo."
- "O que posso fazer por você?"
"""


def get_gemini_model():
    global _model
    if _model is None:
        api_key = os.environ["GEMINI_API_KEY"]
        genai.configure(api_key=api_key)
        _model = genai.GenerativeModel(
            model_name="gemini-2.5-flash-preview-04-17",
            system_instruction=JARVIS_SYSTEM_PROMPT,
        )
    return _model


async def jarvis_chat(message: str, history: list[dict] | None = None) -> str:
    """
    Send a message to Jarvis (Gemini 2.5 Flash) and return the response.
    history: list of {"role": "user"|"model", "parts": [str]}
    """
    model = get_gemini_model()
    chat = model.start_chat(history=history or [])
    response = await chat.send_message_async(message)
    return response.text
```

- [ ] **Step 2: Atualizar system prompt inline em `backend/utils/llm/chat.py`**

Localizar as duas ocorrências de:
```python
You are Omi, an AI assistant & mentor for {user_name}.
```

Substituir cada uma por:
```python
You are JARVIS, personal AI assistant to {user_name}. You are intelligent, proactive, and speak Brazilian Portuguese naturally. Be direct, warm, and action-oriented.
```

E localizar:
```python
You are Omi, an AI assistant & mentor for
```
(no fallback prompt da função `_get_agentic_qa_prompt_fallback`) e substituir por:
```python
You are JARVIS, personal AI assistant to
```

- [ ] **Step 3: Verificar que Gemini responde**

```bash
cd backend && GEMINI_API_KEY=AIzaSyCpDMh2LyHv31FYNEUl8jN6RSUr0NDvGpw python -c "
import asyncio
from utils.llm.gemini_client import jarvis_chat
resp = asyncio.run(jarvis_chat('Oi Jarvis, tudo bem?'))
print(resp)
"
```
Expected: resposta do Jarvis em português, sem mencionar "Omi"

- [ ] **Step 4: Commit**

```bash
rtk git add backend/utils/llm/gemini_client.py backend/utils/llm/chat.py
rtk git commit -m "feat(backend): add Gemini 2.5 Flash client with Jarvis persona"
```

---

## Task 5: Backend — variáveis de ambiente + railway.toml

**Files:**
- Modify: `backend/.env.template`
- Create: `backend/railway.toml`

- [ ] **Step 1: Atualizar `.env.template`**

Adicionar ao final do arquivo `backend/.env.template`:
```
# Jarvis — Supabase
SUPABASE_URL=
SUPABASE_SERVICE_ROLE_KEY=
SUPABASE_ANON_KEY=

# Jarvis — Gemini
GEMINI_API_KEY=
```

- [ ] **Step 2: Criar `backend/railway.toml`**

```toml
[build]
builder = "DOCKERFILE"
dockerfilePath = "Dockerfile"

[deploy]
startCommand = "uvicorn main:app --host 0.0.0.0 --port 8080 --loop uvloop"
healthcheckPath = "/"
healthcheckTimeout = 30
restartPolicyType = "ON_FAILURE"

[[deploy.envVars]]
name = "PORT"
value = "8080"
```

- [ ] **Step 3: Commit**

```bash
rtk git add backend/.env.template backend/railway.toml
rtk git commit -m "feat(backend): add railway.toml deploy config and update env template"
```

---

## Task 6: Backend — gravar conversas no Supabase

**Files:**
- Create: `backend/database/supabase_conversations.py`

- [ ] **Step 1: Criar módulo de conversas**

```python
# backend/database/supabase_conversations.py
from datetime import datetime, timezone
from utils.supabase_client import get_supabase
import logging

logger = logging.getLogger(__name__)


async def save_conversation(
    user_id: str,
    transcript: str,
    summary: str | None = None,
    started_at: datetime | None = None,
    finished_at: datetime | None = None,
) -> str | None:
    """Salva uma conversa no Supabase. Retorna o ID gerado."""
    try:
        supabase = get_supabase()
        data = {
            "user_id": user_id,
            "transcript": transcript,
            "summary": summary,
            "started_at": started_at.isoformat() if started_at else None,
            "finished_at": finished_at.isoformat() if finished_at else datetime.now(timezone.utc).isoformat(),
        }
        result = supabase.table("conversations").insert(data).execute()
        return result.data[0]["id"] if result.data else None
    except Exception as e:
        logger.error(f"Failed to save conversation for user {user_id}: {e}")
        return None


async def get_conversations(user_id: str, limit: int = 20) -> list[dict]:
    """Busca as últimas conversas do usuário."""
    try:
        supabase = get_supabase()
        result = (
            supabase.table("conversations")
            .select("id, transcript, summary, started_at, finished_at, created_at")
            .eq("user_id", user_id)
            .order("created_at", desc=True)
            .limit(limit)
            .execute()
        )
        return result.data or []
    except Exception as e:
        logger.error(f"Failed to get conversations for user {user_id}: {e}")
        return []
```

- [ ] **Step 2: Commit**

```bash
rtk git add backend/database/supabase_conversations.py
rtk git commit -m "feat(backend): add Supabase conversations read/write module"
```

---

## Task 7: Flutter — adicionar supabase_flutter

**Files:**
- Modify: `app/pubspec.yaml`
- Create: `app/lib/supabase_client.dart`
- Modify: `app/lib/main.dart`

- [ ] **Step 1: Adicionar dependência no pubspec.yaml**

Localizar a seção `dependencies:` em `app/pubspec.yaml` e adicionar:
```yaml
  supabase_flutter: ^2.8.0
```

- [ ] **Step 2: Rodar pub get**

```bash
cd app && flutter pub get
```
Expected: `Changed N dependencies!` sem erros

- [ ] **Step 3: Criar singleton Supabase para o Flutter**

```dart
// app/lib/supabase_client.dart
import 'package:supabase_flutter/supabase_flutter.dart';

const supabaseUrl = 'https://hqchmtkdpashuiarekmh.supabase.co';
const supabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhxY2htdGtkcGFzaHVpYXJla21oIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY4OTEwMDEsImV4cCI6MjA5MjQ2NzAwMX0.NP3i2fK3WdrezYAaK3pyV_JYPHU0MlI-Jt36vpU9jY4';

SupabaseClient get supabase => Supabase.instance.client;

Future<void> initSupabase() async {
  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
  );
}
```

- [ ] **Step 4: Inicializar Supabase em `app/lib/main.dart`**

Localizar o `main()` em `app/lib/main.dart` e adicionar antes do `runApp`:

```dart
import 'package:omi/supabase_client.dart';

// No main():
await initSupabase();
```

Manter o Firebase init comentado com `// TODO: remove after full migration`:
```dart
// TODO: remove after full migration to Supabase
// await Firebase.initializeApp(...);
```

- [ ] **Step 5: Verificar que compila**

```bash
cd app && flutter build ios --no-codesign --flavor dev 2>&1 | grep -E "error:|FAILED|succeeded"
```
Expected: `Build succeeded.` ou apenas warnings

- [ ] **Step 6: Commit**

```bash
rtk git add app/pubspec.yaml app/pubspec.lock app/lib/supabase_client.dart app/lib/main.dart
rtk git commit -m "feat(app): initialize Supabase Flutter client"
```

---

## Task 8: Flutter — auth header com token Supabase

**Files:**
- Create: `app/lib/backend/auth.dart`
- Modify: `app/lib/backend/http/shared.dart`

- [ ] **Step 1: Criar helper de auth**

```dart
// app/lib/backend/auth.dart
import 'package:omi/supabase_client.dart';

/// Retorna o JWT atual do usuário Supabase para usar nas requests ao backend.
Future<String?> getSupabaseToken() async {
  final session = supabase.auth.currentSession;
  return session?.accessToken;
}

/// Retorna o UID do usuário logado.
String? getCurrentUserId() {
  return supabase.auth.currentUser?.id;
}

/// Retorna true se há um usuário logado.
bool get isLoggedIn => supabase.auth.currentUser != null;
```

- [ ] **Step 2: Atualizar `app/lib/backend/http/shared.dart`**

Localizar a função `getAuthHeader()` (ou similar que monta o header `Authorization`). Substituir a chamada Firebase por:

```dart
import 'package:omi/backend/auth.dart';

// Dentro de getAuthHeader() ou onde o token é obtido:
final token = await getSupabaseToken();
if (token == null) throw Exception('Not authenticated');
return {'Authorization': 'Bearer $token'};
```

- [ ] **Step 3: Commit**

```bash
rtk git add app/lib/backend/auth.dart app/lib/backend/http/shared.dart
rtk git commit -m "feat(app): use Supabase JWT for backend API authentication"
```

---

## Task 9: Deploy Railway

**Pre-requisito:** Conta Railway criada e GitHub vinculado.

- [ ] **Step 1: Criar novo projeto no Railway**

Acessar railway.app → New Project → Deploy from GitHub repo → selecionar este repositório.

- [ ] **Step 2: Configurar Root Directory**

Em Settings → Source → Root Directory: `backend`

- [ ] **Step 3: Adicionar variáveis de ambiente no Railway**

Em Variables → Add All:
```
SUPABASE_URL=https://hqchmtkdpashuiarekmh.supabase.co
SUPABASE_SERVICE_ROLE_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhxY2htdGtkcGFzaHVpYXJla21oIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3Njg5MTAwMSwiZXhwIjoyMDkyNDY3MDAxfQ.YvpVW304ggBcUH_f2fyjTn4cr5F3a2Y7-G0qG2oNXtc
SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhxY2htdGtkcGFzaHVpYXJla21oIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY4OTEwMDEsImV4cCI6MjA5MjQ2NzAwMX0.NP3i2fK3WdrezYAaK3pyV_JYPHU0MlI-Jt36vpU9jY4
GEMINI_API_KEY=AIzaSyCpDMh2LyHv31FYNEUl8jN6RSUr0NDvGpw
ENCRYPTION_SECRET=<gerar: python -c "import secrets; print(secrets.token_hex(32))">
```

- [ ] **Step 4: Gerar ENCRYPTION_SECRET localmente**

```bash
python3 -c "import secrets; print(secrets.token_hex(32))"
```
Copiar o output e adicionar como `ENCRYPTION_SECRET` no Railway.

- [ ] **Step 5: Fazer deploy**

Railway detecta o `railway.toml` e faz o build automaticamente. Aguardar o build completar (5-10 min pela primeira vez).

Expected: status `Active` com URL pública `https://<projeto>.railway.app`

- [ ] **Step 6: Verificar health check**

```bash
curl https://<seu-projeto>.railway.app/
```
Expected: `{"status": "ok"}` ou similar (200)

- [ ] **Step 7: Atualizar URL do backend no Flutter**

Em `app/.prod.env`, atualizar:
```
API_BASE_URL=https://<seu-projeto>.railway.app
```

Rodar build_runner para regenerar:
```bash
cd app && flutter pub run build_runner build --delete-conflicting-outputs
```

- [ ] **Step 8: Commit final**

```bash
rtk git add app/.env.template
rtk git commit -m "feat: Phase 1 complete — Jarvis on Railway + Supabase + Gemini"
```

---

## Verificação Final

Após todos os tasks, testar o fluxo completo:

1. App Flutter abre → tela de login (Supabase Auth)
2. Login com email/senha → JWT emitido pelo Supabase
3. App faz request ao backend Railway com `Authorization: Bearer <token>`
4. Backend valida JWT via `supabase.auth.get_user(token)`
5. Chat com Jarvis → resposta vem do Gemini 2.5 Flash com persona Jarvis
6. Conversa gravada na tabela `conversations` do Supabase

```bash
# Teste rápido do backend deployado:
curl -X POST https://<projeto>.railway.app/v2/messages \
  -H "Authorization: Bearer <token_supabase>" \
  -H "Content-Type: application/json" \
  -d '{"text": "Oi Jarvis, tudo bem?"}'
```
Expected: resposta JSON com texto do Jarvis em português.
