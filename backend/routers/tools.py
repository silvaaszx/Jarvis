"""
Platform tools router — exposes backend tools as REST endpoints for any client.

Unlike /v1/agent/execute-tool (which wraps LangChain tools for VM agents),
these endpoints are direct REST with proper HTTP semantics, designed for
desktop, web, and mobile agent clients.

Endpoints:
- GET   /v1/tools/conversations          — list conversations
- POST  /v1/tools/conversations/search   — semantic search conversations
- GET   /v1/tools/memories               — list memories/facts
- POST  /v1/tools/memories/search        — semantic search memories
- GET   /v1/tools/action-items           — list action items
- POST  /v1/tools/action-items           — create action item
- PATCH /v1/tools/action-items/{id}      — update action item
"""

import logging
from datetime import datetime
from typing import Optional

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field

from utils.other.endpoints import get_current_user_uid, with_rate_limit
from utils.retrieval.tool_services.conversations import get_conversations_text, search_conversations_text
from utils.retrieval.tool_services.memories import get_memories_text, search_memories_text
from utils.retrieval.tool_services.action_items import (
    get_action_items_text,
    create_action_item_text,
    update_action_item_text,
)
from utils.retrieval.tools.gmail_tools import get_gmail_messages, parse_gmail_message, send_gmail_message
from utils.retrieval.tools.calendar_tools import (
    get_google_calendar_events,
    create_google_calendar_event,
    update_google_calendar_event,
    delete_google_calendar_event,
)
from utils.retrieval.tools.google_utils import refresh_google_token
import database.users as users_db

logger = logging.getLogger(__name__)

router = APIRouter()


# --------------- response envelope ---------------


class ToolResponse(BaseModel):
    tool_name: str
    result_text: str
    is_error: bool = False


def _ok(tool_name: str, text: str) -> dict:
    return {"tool_name": tool_name, "result_text": text, "is_error": text.startswith("Error")}


# --------------- request models ---------------


class SearchConversationsRequest(BaseModel):
    query: str = Field(description="Semantic search query")
    start_date: Optional[str] = Field(default=None, description="ISO date with timezone")
    end_date: Optional[str] = Field(default=None, description="ISO date with timezone")
    limit: int = Field(default=5, ge=1, le=20)
    include_transcript: bool = Field(default=True)


class SearchMemoriesRequest(BaseModel):
    query: str = Field(description="Semantic search query")
    limit: int = Field(default=5, ge=1, le=20)


class CreateActionItemRequest(BaseModel):
    description: str = Field(description="Action item description")
    due_at: Optional[str] = Field(default=None, description="ISO date with timezone")
    conversation_id: Optional[str] = Field(default=None, description="Source conversation ID")


class UpdateActionItemRequest(BaseModel):
    completed: Optional[bool] = Field(default=None)
    description: Optional[str] = Field(default=None)
    due_at: Optional[str] = Field(default=None, description="ISO date with timezone")


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


# --------------- conversation endpoints ---------------


@router.get("/v1/tools/conversations", response_model=ToolResponse)
def get_conversations(
    start_date: Optional[str] = Query(default=None, description="ISO date with timezone"),
    end_date: Optional[str] = Query(default=None, description="ISO date with timezone"),
    limit: int = Query(default=20, ge=1, le=5000),
    offset: int = Query(default=0, ge=0),
    include_transcript: bool = Query(default=True),
    uid: str = Depends(get_current_user_uid),
):
    result = get_conversations_text(
        uid=uid,
        start_date=start_date,
        end_date=end_date,
        limit=limit,
        offset=offset,
        include_transcript=include_transcript,
    )
    return _ok("get_conversations", result)


@router.post("/v1/tools/conversations/search", response_model=ToolResponse)
def search_conversations(
    body: SearchConversationsRequest,
    uid: str = Depends(with_rate_limit(get_current_user_uid, "tools:search")),
):
    result = search_conversations_text(
        uid=uid,
        query=body.query,
        start_date=body.start_date,
        end_date=body.end_date,
        limit=body.limit,
        include_transcript=body.include_transcript,
    )
    return _ok("search_conversations", result)


# --------------- memory endpoints ---------------


@router.get("/v1/tools/memories", response_model=ToolResponse)
def get_memories(
    limit: int = Query(default=50, ge=1, le=5000),
    offset: int = Query(default=0, ge=0),
    start_date: Optional[str] = Query(default=None, description="ISO date with timezone"),
    end_date: Optional[str] = Query(default=None, description="ISO date with timezone"),
    uid: str = Depends(get_current_user_uid),
):
    result = get_memories_text(
        uid=uid,
        limit=limit,
        offset=offset,
        start_date=start_date,
        end_date=end_date,
    )
    return _ok("get_memories", result)


@router.post("/v1/tools/memories/search", response_model=ToolResponse)
def search_memories(
    body: SearchMemoriesRequest,
    uid: str = Depends(with_rate_limit(get_current_user_uid, "tools:search")),
):
    result = search_memories_text(
        uid=uid,
        query=body.query,
        limit=body.limit,
    )
    return _ok("search_memories", result)


# --------------- action item endpoints ---------------


@router.get("/v1/tools/action-items", response_model=ToolResponse)
def get_action_items(
    limit: int = Query(default=50, ge=1, le=500),
    offset: int = Query(default=0, ge=0),
    completed: Optional[bool] = Query(default=None),
    conversation_id: Optional[str] = Query(default=None),
    start_date: Optional[str] = Query(default=None, description="ISO date with timezone"),
    end_date: Optional[str] = Query(default=None, description="ISO date with timezone"),
    due_start_date: Optional[str] = Query(default=None, description="ISO date with timezone"),
    due_end_date: Optional[str] = Query(default=None, description="ISO date with timezone"),
    uid: str = Depends(get_current_user_uid),
):
    result = get_action_items_text(
        uid=uid,
        limit=limit,
        offset=offset,
        completed=completed,
        conversation_id=conversation_id,
        start_date=start_date,
        end_date=end_date,
        due_start_date=due_start_date,
        due_end_date=due_end_date,
    )
    return _ok("get_action_items", result)


@router.post("/v1/tools/action-items", response_model=ToolResponse)
def create_action_item(
    body: CreateActionItemRequest,
    uid: str = Depends(with_rate_limit(get_current_user_uid, "tools:mutate")),
):
    result = create_action_item_text(
        uid=uid,
        description=body.description,
        due_at=body.due_at,
        conversation_id=body.conversation_id,
    )
    return _ok("create_action_item", result)


@router.patch("/v1/tools/action-items/{action_item_id}", response_model=ToolResponse)
def update_action_item(
    action_item_id: str,
    body: UpdateActionItemRequest,
    uid: str = Depends(with_rate_limit(get_current_user_uid, "tools:mutate")),
):
    result = update_action_item_text(
        uid=uid,
        action_item_id=action_item_id,
        completed=body.completed,
        description=body.description,
        due_at=body.due_at,
    )
    return _ok("update_action_item", result)


# --------------- google integration helper ---------------


async def _get_google_token(uid: str) -> tuple[Optional[str], Optional[dict], Optional[str]]:
    """Retorna (access_token, integration, error_message)."""
    integration = users_db.get_integration(uid, 'google_calendar')
    if not integration:
        return None, None, "Google não conectado. Conecte sua conta Google em Configurações."
    access_token = integration.get('access_token')
    if not access_token:
        return None, None, "Token Google não encontrado. Reconecte sua conta Google."
    return access_token, integration, None


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
            result += (
                f"{i}. {parsed['subject']}\n"
                f"   De: {parsed['from']}\n"
                f"   Para: {parsed['to']}\n"
                f"   Data: {parsed['date']}\n"
                f"   ID: {parsed['id']}\n"
                f"   ThreadID: {parsed['threadId']}\n"
                f"   Preview: {parsed['snippet'][:150]}\n\n"
            )
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
        result = await send_gmail_message(
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
        time_min = datetime.fromisoformat(start_date.replace('Z', '+00:00')) if start_date else None
        time_max = datetime.fromisoformat(end_date.replace('Z', '+00:00')) if end_date else None
        events = await get_google_calendar_events(
            access_token=access_token,
            time_min=time_min,
            time_max=time_max,
            max_results=limit,
            search_query=query,
        )
        if not events:
            return _ok("calendar_google_read", "Nenhum evento encontrado.")
        result = f"Eventos do Google Calendar ({len(events)}):\n\n"
        for i, ev in enumerate(events, 1):
            start = ev.get('start', {}).get('dateTime') or ev.get('start', {}).get('date', '')
            end_t = ev.get('end', {}).get('dateTime') or ev.get('end', {}).get('date', '')
            result += (
                f"{i}. {ev.get('summary', '(sem título)')}\n"
                f"   ID: {ev.get('id')}\n"
                f"   Início: {start}\n"
                f"   Fim: {end_t}\n"
                f"   Local: {ev.get('location', '')}\n\n"
            )
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
            if not body.title or not body.start or not body.end:
                return _ok("calendar_google_action", "Erro: title, start e end são obrigatórios para create.")
            start_dt = datetime.fromisoformat(body.start.replace('Z', '+00:00'))
            end_dt = datetime.fromisoformat(body.end.replace('Z', '+00:00'))
            event = await create_google_calendar_event(
                access_token=access_token,
                summary=body.title,
                start_time=start_dt,
                end_time=end_dt,
                description=body.description,
                location=body.location,
                attendees=body.attendees or [],
            )
            return _ok("calendar_google_action", f"Evento criado: '{event.get('summary')}' em {body.start}. ID: {event.get('id')}")
        elif body.action == 'update':
            if not body.event_id:
                return _ok("calendar_google_action", "Erro: event_id obrigatório para update.")
            start_dt = datetime.fromisoformat(body.start.replace('Z', '+00:00')) if body.start else None
            end_dt = datetime.fromisoformat(body.end.replace('Z', '+00:00')) if body.end else None
            event = await update_google_calendar_event(
                access_token=access_token,
                event_id=body.event_id,
                summary=body.title,
                start_time=start_dt,
                end_time=end_dt,
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
