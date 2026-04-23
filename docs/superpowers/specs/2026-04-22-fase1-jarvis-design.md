# Fase 1 — Jarvis Base Funcional: Design Spec

**Data:** 2026-04-22
**Meta:** "Hey Jarvis, como vai?" funcionando, sem limites, com identidade própria.
**Abordagem:** Supabase mínimo → Gemini → System Prompt Jarvis → Deploy Railway

---

## 1. Supabase — Schema Mínimo

Apenas o necessário para Phase 1. Expansão (memórias, tasks, etc.) vem na Fase 1.5.

### Tabelas

```sql
-- Perfis de usuário (espelha Supabase Auth)
create table profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text not null,
  name        text,
  created_at  timestamptz default now()
);

-- Conversas gravadas pelo backend
create table conversations (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references profiles(id) on delete cascade,
  transcript   text,
  summary      text,
  started_at   timestamptz,
  finished_at  timestamptz,
  created_at   timestamptz default now()
);

-- RLS: usuários só veem seus próprios dados
alter table profiles     enable row level security;
alter table conversations enable row level security;

create policy "own profile"      on profiles      for all using (auth.uid() = id);
create policy "own conversations" on conversations for all using (auth.uid() = user_id);
```

### Auth

- **Supabase Auth** nativo: email/password + Google OAuth
- JWT emitido pelo Supabase, validado pelo backend Python via `SUPABASE_JWT_SECRET`
- Flutter usa `supabase_flutter` (substitui `firebase_auth` + `cloud_firestore`)

---

## 2. Backend Python — Mudanças

### 2.1 Gemini como modelo principal

- Modelo: `gemini-2.5-flash` para chat de voz (< 500ms)
- Variável: `GEMINI_API_KEY`
- Package já presente: `google-generativeai>=0.8.0`
- Substituir no path de chat principal (`utils/llm/chat.py`)

### 2.2 System Prompt — Persona Jarvis

Inline no código (sem depender do LangSmith do Omi):

```
Você é JARVIS (Just A Rather Very Intelligent System), assistente pessoal do
Sr. Matheus Silvaa, desenvolvedor iOS e fundador de startup em Brasília, Brasil.

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
```

### 2.3 Supabase no Backend

- Package: `supabase` (Python SDK)
- Variáveis: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`
- Usar `service_role` no backend (bypass RLS para operações server-side)
- Operações Phase 1: gravar/ler conversas por user_id

### 2.4 Variáveis de ambiente necessárias (`.env`)

```
GEMINI_API_KEY=...
SUPABASE_URL=...
SUPABASE_SERVICE_ROLE_KEY=...
SUPABASE_JWT_SECRET=...
DEEPGRAM_API_KEY=...          # já existia
ENCRYPTION_SECRET=...          # já existia
```

---

## 3. Flutter App — Mudanças

### 3.1 Dependências

Adicionar ao `pubspec.yaml`:
```yaml
supabase_flutter: ^2.x
```

Remover (ou comentar por ora):
```yaml
# firebase_core, firebase_auth, cloud_firestore, firebase_crashlytics, firebase_messaging
```

### 3.2 Auth Flow

- `Supabase.initialize(url, anonKey)` no `main.dart`
- `supabase.auth.signInWithPassword()` / `signInWithOAuth(OAuthProvider.google)`
- Session persistida automaticamente pelo SDK
- Token JWT enviado como `Authorization: Bearer <token>` nas requests ao backend

### 3.3 Conversas

- Ler: `supabase.from('conversations').select().eq('user_id', uid).order('created_at')`
- Gravar: feito pelo backend (usa service_role), app só lê

---

## 4. Deploy — Railway

- Serviço: Docker deploy direto do `backend/Dockerfile` existente
- Variáveis de ambiente configuradas no painel Railway
- Health check: `GET /` → 200
- Porta: 8080 (já configurada no Dockerfile)
- `railway.toml` na raiz do `backend/`:

```toml
[build]
builder = "DOCKERFILE"
dockerfilePath = "backend/Dockerfile"

[deploy]
startCommand = "uvicorn main:app --host 0.0.0.0 --port 8080 --loop uvloop"
healthcheckPath = "/"
healthcheckTimeout = 30
restartPolicyType = "ON_FAILURE"
```

---

## 5. O que NÃO muda na Fase 1

- FCM (notificações push) — substituído na Fase 1.5
- Crashlytics — substituído por Sentry na Fase 1.5
- Toda a lógica de memórias, tasks, apps, plugins — mantida na Fase 1.5
- Deepgram (STT) — continua igual
- Hardware BLE (dispositivo Omi) — continua igual

---

## 6. Resultado Esperado

Ao final da Fase 1:
1. App Flutter abre, login via Supabase Auth funciona
2. Chat com Jarvis funciona (modelo Gemini 2.5 Flash, persona correta)
3. Conversas gravadas no Supabase PostgreSQL
4. Backend rodando no Railway com URL pública
5. Zero dependência do Firebase / BasedHardware
