# Gmail + Google Calendar Integration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expor Gmail (ler + enviar) e Google Calendar (ler + criar/atualizar/deletar) como endpoints REST no backend e cabeá-los no desktop Swift.

**Architecture:** Backend adiciona 4 endpoints em `/v1/tools/gmail` e `/v1/tools/calendar-google`, reutilizando `gmail_tools.py` e `calendar_tools.py` já existentes. Desktop Swift adiciona métodos no `APIClient` e cases no `executeBackendTool`. Settings ganha botão "Conectar Google" para autorizar OAuth sem precisar do app mobile.

**Tech Stack:** FastAPI (Python), Swift, Gmail API v1, Google Calendar API v3, OAuth2 via `/v1/integrations/google_calendar/oauth-url`

---

## Arquivos modificados

| Arquivo | Ação |
|---------|------|
| `backend/utils/retrieval/tools/gmail_tools.py` | Adicionar `send_gmail_message()` e `send_gmail_message_tool()` |
| `backend/routers/tools.py` | Adicionar 4 endpoints + 3 request models |
| `Desktop/Desktop/Sources/APIClient.swift` | Adicionar 4 métodos de tool |
| `Desktop/Desktop/Sources/Providers/ChatToolExecutor.swift` | Adicionar 4 cases em `executeBackendTool` + 4 cases no switch principal |
| `Desktop/Desktop/Sources/MainWindow/Pages/SettingsPage.swift` | Adicionar botão "Conectar Google" |

---

## Task 1: Adicionar `send_gmail_message` ao gmail_tools.py

**Files:**
- Modify: `backend/utils/retrieval/tools/gmail_tools.py`

- [ ] **Step 1: Adicionar imports necessários no topo do arquivo** (base64 e email já usados inline — mover para topo)

No início do arquivo, após os imports existentes:
```python
import base64
import email.mime.text
import email.mime.multipart
```

- [ ] **Step 2: Adicionar função `send_gmail_message` após `parse_gmail_message`**

```python
def send_gmail_message(
    access_token: str,
    to: str,
    subject: str,
    body: str,
    reply_to_message_id: Optional[str] = None,
    thread_id: Optional[str] = None,
) -> dict:
    """
    Send or reply to an email via Gmail API.

    Args:
        access_token: Google access token
        to: Recipient email address
        subject: Email subject
        body: Plain text body
        reply_to_message_id: Message-ID header value to reply to (optional)
        thread_id: Gmail thread ID for reply threading (optional)

    Returns:
        Sent message dict with id and threadId
    """
    msg = email.mime.text.MIMEText(body, 'plain', 'utf-8')
    msg['To'] = to
    msg['Subject'] = subject
    if reply_to_message_id:
        msg['In-Reply-To'] = reply_to_message_id
        msg['References'] = reply_to_message_id

    raw = base64.urlsafe_b64encode(msg.as_bytes()).decode('utf-8')
    payload: dict = {'raw': raw}
    if thread_id:
        payload['threadId'] = thread_id

    return google_api_request(
        'POST',
        'https://www.googleapis.com/gmail/v1/users/me/messages/send',
        access_token,
        body=payload,
    )
```

- [ ] **Step 3: Commit**

```bash
cd /Users/matheussilva/Documents/Developer2026/Jarvis/Jarvis
rtk git add backend/utils/retrieval/tools/gmail_tools.py
git commit -m "feat(gmail): adiciona send_gmail_message para envio/reply via API"
```

---

## Task 2: Adicionar endpoints no tools.py

**Files:**
- Modify: `backend/routers/tools.py`

- [ ] **Step 1: Adicionar imports no topo de tools.py**

Após os imports existentes:
```python
import asyncio
from utils.retrieval.tools.gmail_tools import get_gmail_messages, parse_gmail_message, send_gmail_message
from utils.retrieval.tools.calendar_tools import (
    get_google_calendar_events,
    create_google_calendar_event,
    update_google_calendar_event,
    delete_google_calendar_event,
)
from utils.retrieval.tools.google_utils import refresh_google_token
import database.users as users_db
```

- [ ] **Step 2: Adicionar 3 novos request models após os existentes**

```python
class GmailReadRequest(BaseModel):
    query: Optional[str] = Field(default=None, description="Filtro Gmail ex: 'from:joao is:unread'")
    max_results: int = Field(default=10, ge=1, le=50)
    label: Optional[str] = Field(default=None, description="INBOX, SENT, DRAFT, UNREAD")


class GmailSendRequest(BaseModel):
    to: str = Field(description="Email do destinatário")
    subject: str = Field(description="Assunto do email")
    body: str = Field(description="Corpo em texto simples")
    reply_to_message_id: Optional[str] = Field(default=None, description="Message-ID para reply")
    thread_id: Optional[str] = Field(default=None, description="Thread ID Gmail para reply")


class CalendarActionRequest(BaseModel):
    action: str = Field(description="'create', 'update', ou 'delete'")
    event_id: Optional[str] = Field(default=None, description="ID do evento (para update/delete)")
    title: Optional[str] = Field(default=None, description="Título do evento (create/update)")
    start: Optional[str] = Field(default=None, description="ISO datetime início (create/update)")
    end: Optional[str] = Field(default=None, description="ISO datetime fim (create/update)")
    description: Optional[str] = Field(default=None)
    attendees: Optional[list] = Field(default=None, description="Lista de emails dos participantes")
    location: Optional[str] = Field(default=None)
```

- [ ] **Step 3: Adicionar helper `_get_google_token` antes dos endpoints**

```python
async def _get_google_token(uid: str) -> tuple[Optional[str], Optional[dict], Optional[str]]:
    """Retorna (access_token, integration, error_message)."""
    integration = users_db.get_integration(uid, 'google_calendar')
    if not integration:
        return None, None, "Google não conectado. Conecte sua conta Google em Configurações."
    access_token = integration.get('access_token')
    if not access_token:
        return None, None, "Token Google não encontrado. Reconecte sua conta Google."
    return access_token, integration, None
```

- [ ] **Step 4: Adicionar os 4 endpoints no final do arquivo**

```python
# --------------- gmail endpoints ---------------


@router.post("/v1/tools/gmail/read", response_model=ToolResponse)
async def gmail_read(
    body: GmailReadRequest,
    uid: str = Depends(get_current_user_uid),
):
    access_token, integration, err = await _get_google_token(uid)
    if err:
        return _ok("gmail_read", err)
    try:
        query = body.query
        label_ids = None
        if body.label:
            label_upper = body.label.upper()
            if label_upper == 'UNREAD':
                query = f"{query} is:unread" if query else "is:unread"
            else:
                label_ids = [label_upper]
        messages = get_gmail_messages(access_token, query=query, max_results=body.max_results, label_ids=label_ids)
        if not messages:
            return _ok("gmail_read", "Nenhum email encontrado.")
        result = f"Emails encontrados ({len(messages)}):\n\n"
        for i, msg in enumerate(messages, 1):
            parsed = parse_gmail_message(msg)
            result += f"{i}. {parsed['subject']}\n   De: {parsed['from']}\n   Para: {parsed['to']}\n   Data: {parsed['date']}\n   ID: {parsed['id']}\n   ThreadID: {parsed['threadId']}\n   Preview: {parsed['snippet'][:150]}\n\n"
        return _ok("gmail_read", result.strip())
    except Exception as e:
        logger.error("gmail_read error: %s", e)
        return _ok("gmail_read", f"Erro ao ler Gmail: {str(e)}")


@router.post("/v1/tools/gmail/send", response_model=ToolResponse)
async def gmail_send(
    body: GmailSendRequest,
    uid: str = Depends(with_rate_limit(get_current_user_uid, "tools:mutate")),
):
    access_token, integration, err = await _get_google_token(uid)
    if err:
        return _ok("gmail_send", err)
    try:
        result = send_gmail_message(
            access_token=access_token,
            to=body.to,
            subject=body.subject,
            body=body.body,
            reply_to_message_id=body.reply_to_message_id,
            thread_id=body.thread_id,
        )
        msg_id = result.get('id', 'desconhecido')
        action = "Resposta enviada" if body.reply_to_message_id else "Email enviado"
        return _ok("gmail_send", f"{action} com sucesso para {body.to}. ID: {msg_id}")
    except Exception as e:
        logger.error("gmail_send error: %s", e)
        return _ok("gmail_send", f"Erro ao enviar email: {str(e)}")


# --------------- google calendar endpoints ---------------


@router.get("/v1/tools/calendar-google", response_model=ToolResponse)
async def calendar_google_read(
    start_date: Optional[str] = Query(default=None),
    end_date: Optional[str] = Query(default=None),
    limit: int = Query(default=10, ge=1, le=50),
    query: Optional[str] = Query(default=None),
    uid: str = Depends(get_current_user_uid),
):
    access_token, integration, err = await _get_google_token(uid)
    if err:
        return _ok("calendar_google_read", err)
    try:
        events = await get_google_calendar_events(
            access_token=access_token,
            time_min=start_date,
            time_max=end_date,
            max_results=limit,
            query=query,
        )
        if not events:
            return _ok("calendar_google_read", "Nenhum evento encontrado.")
        result = f"Eventos do Google Calendar ({len(events)}):\n\n"
        for i, ev in enumerate(events, 1):
            start = ev.get('start', {}).get('dateTime') or ev.get('start', {}).get('date', '')
            end_t = ev.get('end', {}).get('dateTime') or ev.get('end', {}).get('date', '')
            result += f"{i}. {ev.get('summary', '(sem título)')}\n   ID: {ev.get('id')}\n   Início: {start}\n   Fim: {end_t}\n   Local: {ev.get('location', '')}\n\n"
        return _ok("calendar_google_read", result.strip())
    except Exception as e:
        logger.error("calendar_google_read error: %s", e)
        return _ok("calendar_google_read", f"Erro ao ler Calendar: {str(e)}")


@router.post("/v1/tools/calendar-google", response_model=ToolResponse)
async def calendar_google_action(
    body: CalendarActionRequest,
    uid: str = Depends(with_rate_limit(get_current_user_uid, "tools:mutate")),
):
    access_token, integration, err = await _get_google_token(uid)
    if err:
        return _ok("calendar_google_action", err)
    try:
        if body.action == 'create':
            event = await create_google_calendar_event(
                access_token=access_token,
                title=body.title or '',
                start=body.start or '',
                end=body.end or '',
                description=body.description,
                attendees=body.attendees or [],
                location=body.location,
            )
            return _ok("calendar_google_action", f"Evento criado: '{event.get('summary')}' em {body.start}. ID: {event.get('id')}")
        elif body.action == 'update':
            if not body.event_id:
                return _ok("calendar_google_action", "Erro: event_id obrigatório para update.")
            event = await update_google_calendar_event(
                access_token=access_token,
                event_id=body.event_id,
                title=body.title,
                start=body.start,
                end=body.end,
                description=body.description,
                attendees=body.attendees,
                location=body.location,
            )
            return _ok("calendar_google_action", f"Evento atualizado: '{event.get('summary')}'. ID: {event.get('id')}")
        elif body.action == 'delete':
            if not body.event_id:
                return _ok("calendar_google_action", "Erro: event_id obrigatório para delete.")
            await delete_google_calendar_event(access_token=access_token, event_id=body.event_id)
            return _ok("calendar_google_action", f"Evento {body.event_id} deletado com sucesso.")
        else:
            return _ok("calendar_google_action", f"Erro: action deve ser 'create', 'update' ou 'delete'. Recebido: {body.action}")
    except Exception as e:
        logger.error("calendar_google_action error: %s", e)
        return _ok("calendar_google_action", f"Erro no Calendar: {str(e)}")
```

- [ ] **Step 5: Commit**

```bash
rtk git add backend/routers/tools.py
git commit -m "feat(tools): adiciona endpoints Gmail e Google Calendar REST"
```

---

## Task 3: Adicionar métodos no APIClient.swift

**Files:**
- Modify: `Desktop/Desktop/Sources/APIClient.swift` (localizar a seção de tool methods — buscar `toolGetConversations`)

- [ ] **Step 1: Localizar onde ficam os tool methods e adicionar os 4 novos**

Buscar `func toolGetConversations` no APIClient.swift e adicionar após o último tool method existente:

```swift
// MARK: - Gmail Tools

func toolGmailRead(query: String?, maxResults: Int = 10, label: String?) async throws -> ToolResponse {
    var body: [String: Any] = ["max_results": maxResults]
    if let q = query { body["query"] = q }
    if let l = label { body["label"] = l }
    return try await postTool("/v1/tools/gmail/read", body: body)
}

func toolGmailSend(to: String, subject: String, body: String, replyToMessageId: String? = nil, threadId: String? = nil) async throws -> ToolResponse {
    var payload: [String: Any] = ["to": to, "subject": subject, "body": body]
    if let r = replyToMessageId { payload["reply_to_message_id"] = r }
    if let t = threadId { payload["thread_id"] = t }
    return try await postTool("/v1/tools/gmail/send", body: payload)
}

// MARK: - Google Calendar Tools

func toolCalendarGoogleRead(startDate: String? = nil, endDate: String? = nil, limit: Int = 10, query: String? = nil) async throws -> ToolResponse {
    var params: [String: String] = ["limit": "\(limit)"]
    if let s = startDate { params["start_date"] = s }
    if let e = endDate { params["end_date"] = e }
    if let q = query { params["query"] = q }
    return try await getTool("/v1/tools/calendar-google", params: params)
}

func toolCalendarGoogleAction(action: String, eventId: String? = nil, title: String? = nil, start: String? = nil, end: String? = nil, description: String? = nil, attendees: [String]? = nil, location: String? = nil) async throws -> ToolResponse {
    var body: [String: Any] = ["action": action]
    if let id = eventId { body["event_id"] = id }
    if let t = title { body["title"] = t }
    if let s = start { body["start"] = s }
    if let e = end { body["end"] = e }
    if let d = description { body["description"] = d }
    if let a = attendees { body["attendees"] = a }
    if let l = location { body["location"] = l }
    return try await postTool("/v1/tools/calendar-google", body: body)
}
```

- [ ] **Step 2: Verificar se `getTool` e `postTool` helpers existem — senão, adicionar**

Buscar `func postTool` no APIClient.swift. Se não existir, adicionar antes dos métodos acima:

```swift
private func getTool(_ path: String, params: [String: String] = [:]) async throws -> ToolResponse {
    var urlComponents = URLComponents(string: (apiURL ?? "") + path)!
    urlComponents.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
    var request = URLRequest(url: urlComponents.url!)
    request.httpMethod = "GET"
    request.setValue("Bearer \(authToken ?? "")", forHTTPHeaderField: "Authorization")
    let (data, _) = try await URLSession.shared.data(for: request)
    return try JSONDecoder().decode(ToolResponse.self, from: data)
}

private func postTool(_ path: String, body: [String: Any]) async throws -> ToolResponse {
    var request = URLRequest(url: URL(string: (apiURL ?? "") + path)!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(authToken ?? "")", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, _) = try await URLSession.shared.data(for: request)
    return try JSONDecoder().decode(ToolResponse.self, from: data)
}
```

> **Nota:** Se `APIClient` já tem uma forma de fazer GET/POST autenticado (ex: `performRequest`, `authenticatedRequest`), use essa em vez de criar os helpers acima. Buscar `func toolGetConversations` para ver o padrão real e replicar.

- [ ] **Step 3: Adicionar struct `ToolResponse` se não existir**

Buscar `struct ToolResponse` no APIClient.swift. Se não existir:

```swift
struct ToolResponse: Codable {
    let toolName: String
    let resultText: String
    let isError: Bool

    enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case resultText = "result_text"
        case isError = "is_error"
    }
}
```

- [ ] **Step 4: Commit**

```bash
rtk git add "Desktop/Desktop/Sources/APIClient.swift"
git commit -m "feat(desktop): adiciona métodos Gmail e Google Calendar no APIClient"
```

---

## Task 4: Adicionar cases no ChatToolExecutor.swift

**Files:**
- Modify: `Desktop/Desktop/Sources/Providers/ChatToolExecutor.swift`

- [ ] **Step 1: Adicionar 4 cases no switch principal (`execute` method)**

Após a linha `case "focus_mode":` e antes de `// Backend RAG tools`:

```swift
    // Google integrations — via backend Railway
    case "gmail_read":
      return await executeBackendTool(toolCall)

    case "gmail_send":
      return await executeBackendTool(toolCall)

    case "google_calendar_read":
      return await executeBackendTool(toolCall)

    case "google_calendar_action":
      return await executeBackendTool(toolCall)
```

- [ ] **Step 2: Adicionar 4 cases no `executeBackendTool` switch**

Dentro do switch em `executeBackendTool`, após o último `case "update_action_item"`:

```swift
      case "gmail_read":
        let resp = try await api.toolGmailRead(
          query: args["query"] as? String,
          maxResults: args["max_results"] as? Int ?? 10,
          label: args["label"] as? String
        )
        return resp.resultText

      case "gmail_send":
        guard let to = args["to"] as? String, !to.isEmpty else { return "Error: 'to' obrigatório" }
        guard let subject = args["subject"] as? String else { return "Error: 'subject' obrigatório" }
        guard let body = args["body"] as? String else { return "Error: 'body' obrigatório" }
        let resp = try await api.toolGmailSend(
          to: to,
          subject: subject,
          body: body,
          replyToMessageId: args["reply_to_message_id"] as? String,
          threadId: args["thread_id"] as? String
        )
        return resp.resultText

      case "google_calendar_read":
        let resp = try await api.toolCalendarGoogleRead(
          startDate: validatedStartDate,
          endDate: validatedEndDate,
          limit: args["limit"] as? Int ?? 10,
          query: args["query"] as? String
        )
        return resp.resultText

      case "google_calendar_action":
        guard let action = args["action"] as? String else { return "Error: 'action' obrigatório (create/update/delete)" }
        let resp = try await api.toolCalendarGoogleAction(
          action: action,
          eventId: args["event_id"] as? String,
          title: args["title"] as? String,
          start: args["start"] as? String,
          end: args["end"] as? String,
          description: args["description"] as? String,
          attendees: args["attendees"] as? [String],
          location: args["location"] as? String
        )
        return resp.resultText
```

- [ ] **Step 3: Commit**

```bash
rtk git add "Desktop/Desktop/Sources/Providers/ChatToolExecutor.swift"
git commit -m "feat(desktop): cabeia Gmail e Google Calendar no ChatToolExecutor"
```

---

## Task 5: Botão "Conectar Google" no SettingsPage.swift

**Files:**
- Modify: `Desktop/Desktop/Sources/MainWindow/Pages/SettingsPage.swift`

- [ ] **Step 1: Localizar a seção de integrações/serviços no SettingsPage**

Buscar `CalendarReaderService` ou `"google_calendar"` no SettingsPage.swift. Identificar onde ficam controles de integração de terceiros.

- [ ] **Step 2: Adicionar botão na seção de integrações**

Adicionar perto da seção de Calendar no Settings:

```swift
// Google Calendar + Gmail
VStack(alignment: .leading, spacing: 8) {
    HStack {
        Image("google_calendar_logo")
            .resizable()
            .frame(width: 20, height: 20)
        Text("Google Calendar + Gmail")
            .font(.headline)
        Spacer()
        Button(action: connectGoogle) {
            Text(isGoogleConnected ? "Reconectar" : "Conectar")
                .font(.subheadline)
        }
        .buttonStyle(.bordered)
    }
    Text(isGoogleConnected
        ? "Conectado — Jarvis pode ler/enviar emails e gerenciar eventos"
        : "Conecte para permitir que Jarvis acesse Gmail e Google Calendar")
        .font(.caption)
        .foregroundColor(.secondary)
}
.padding(.vertical, 4)
```

- [ ] **Step 3: Adicionar estado e função `connectGoogle`**

Na view ou view model correspondente, adicionar:

```swift
@State private var isGoogleConnected: Bool = false

private func connectGoogle() {
    Task {
        do {
            // Busca OAuth URL do backend
            let url = URL(string: AppState.backendURL + "/v1/integrations/google_calendar/oauth-url")!
            var req = URLRequest(url: url)
            req.setValue("Bearer \(AppState.shared.authToken ?? "")", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let oauthURL = json["url"] as? String,
               let targetURL = URL(string: oauthURL) {
                NSWorkspace.shared.open(targetURL)
            }
        } catch {
            log("connectGoogle error: \(error)")
        }
    }
}

private func checkGoogleConnection() {
    Task {
        // Checa se integration google_calendar existe via backend
        isGoogleConnected = await AppState.shared.hasIntegration("google_calendar")
    }
}
```

- [ ] **Step 4: Verificar padrão real no SettingsPage antes de implementar**

> ⚠️ SettingsPage.swift tem +7000 linhas. Antes de inserir, buscar como outros serviços similares (ex: Spotify, Todoist) são renderizados no Settings e seguir o mesmo padrão de UI e state management.

- [ ] **Step 5: Commit**

```bash
rtk git add "Desktop/Desktop/Sources/MainWindow/Pages/SettingsPage.swift"
git commit -m "feat(desktop): botão Conectar Google no Settings para Gmail + Calendar"
```

---

## Task 6: Deploy Railway e teste ponta a ponta

- [ ] **Step 1: Push e redeploy no Railway**

```bash
git push
# No painel Railway: redeploy do serviço jarvis-production
# OU via CLI: railway up
```

- [ ] **Step 2: Verificar endpoints no Railway**

```bash
# Substitua <TOKEN> pelo Firebase ID token do usuário
curl -H "Authorization: Bearer <TOKEN>" \
  https://jarvis-production-fa35.up.railway.app/v1/tools/gmail/read \
  -X POST -H "Content-Type: application/json" \
  -d '{"max_results": 3}'
# Esperado: {"tool_name":"gmail_read","result_text":"Google não conectado...","is_error":false}
# (antes de conectar OAuth)
```

- [ ] **Step 3: Conectar Google OAuth**

No app desktop → Settings → clicar "Conectar Google" → autorizar no browser → voltar ao app

- [ ] **Step 4: Teste funcional**

```bash
# Após conectar OAuth:
curl -H "Authorization: Bearer <TOKEN>" \
  https://jarvis-production-fa35.up.railway.app/v1/tools/gmail/read \
  -X POST -H "Content-Type: application/json" \
  -d '{"max_results": 3, "query": "is:unread"}'
# Esperado: lista de emails reais do usuário
```

- [ ] **Step 5: Rebuild e testar no app desktop**

```bash
cd /Users/matheussilva/Documents/Developer2026/Jarvis/Jarvis/desktop
OMI_APP_NAME="omi-gmail-test" ./run.sh --yolo
```

Perguntar ao Jarvis: "Quais emails não lidos tenho?" — deve retornar emails reais.

---

## Self-Review

**Spec coverage:**
- ✅ Gmail leitura/pesquisa: Task 1 + Task 2 (endpoint) + Task 3 (APIClient) + Task 4 (executor)
- ✅ Gmail envio/reply: Task 1 (`send_gmail_message`) + Task 2 + Task 3 + Task 4
- ✅ Google Calendar leitura: Task 2 + Task 3 + Task 4
- ✅ Google Calendar CRUD: Task 2 + Task 3 + Task 4
- ✅ Botão "Conectar Google" no desktop Settings: Task 5
- ✅ Deploy e teste: Task 6

**Dependência crítica:** O `google_api_request` em `gmail_tools.py` é `async` (usa `httpx` via `get_auth_client`), mas o endpoint `gmail_read` o chama diretamente. Os endpoints do Task 2 são `async def`, então está correto. Para `gmail_send`, a função `send_gmail_message` usa `google_api_request` que é async — marcar `send_gmail_message` como `async` também.

> ⚠️ **Correção no Task 1:** A função `send_gmail_message` deve ser `async def` e usar `await google_api_request(...)` pois `google_api_request` é async.
