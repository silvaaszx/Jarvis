import base64
import json
import uuid
from datetime import datetime, timezone
from typing import AsyncGenerator, Literal

from fastapi import APIRouter, Depends
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from utils.llm.gemini_client import jarvis_chat, jarvis_chat_stream
from utils.other import endpoints as auth

router = APIRouter()


class JarvisHistoryTurn(BaseModel):
    role: Literal['user', 'model']
    parts: list[str] = Field(default_factory=list, max_length=50)


class JarvisChatRequest(BaseModel):
    message: str = Field(..., min_length=1, max_length=10000)
    history: list[JarvisHistoryTurn] = Field(default_factory=list, max_length=100)


class JarvisChatResponse(BaseModel):
    response: str


class V2MessageRequest(BaseModel):
    text: str = Field(..., min_length=1, max_length=10000)
    file_ids: list[str] = Field(default_factory=list)


async def _v2_stream(text: str) -> AsyncGenerator[str, None]:
    full_text = ''
    async for chunk in jarvis_chat_stream(message=text):
        full_text += chunk
        safe = chunk.replace('\n', '__CRLF__')
        yield f'data: {safe}\n'

    message_id = str(uuid.uuid4())
    done_payload = {
        'id': message_id,
        'created_at': datetime.now(timezone.utc).isoformat(),
        'text': full_text,
        'sender': 'ai',
        'type': 'text',
        'plugin_id': None,
        'from_integration': False,
        'files': [],
        'files_id': [],
        'memories': [],
        'ask_for_nps': False,
    }
    encoded = base64.b64encode(json.dumps(done_payload).encode()).decode()
    yield f'done: {encoded}\n'


@router.post('/v2/messages', tags=['jarvis'])
async def send_message_stream(
    data: V2MessageRequest,
    uid: str = Depends(auth.get_current_user_uid),
):
    _ = uid
    return StreamingResponse(_v2_stream(data.text), media_type='text/plain')


@router.post('/v1/jarvis/chat', tags=['jarvis'], response_model=JarvisChatResponse)
async def send_jarvis_message(
    data: JarvisChatRequest,
    uid: str = Depends(auth.get_current_user_uid),
):
    _ = uid  # auth required; uid reserved for conversation persistence in next phase
    history = [turn.model_dump() for turn in data.history]
    response = await jarvis_chat(message=data.message, history=history)
    return JarvisChatResponse(response=response)
