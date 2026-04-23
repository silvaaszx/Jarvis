from typing import Literal

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from utils.llm.gemini_client import jarvis_chat
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


@router.post('/v1/jarvis/chat', tags=['jarvis'], response_model=JarvisChatResponse)
async def send_jarvis_message(
    data: JarvisChatRequest,
    uid: str = Depends(auth.get_current_user_uid),
):
    _ = uid  # auth required; uid reserved for conversation persistence in next phase
    history = [turn.model_dump() for turn in data.history]
    response = await jarvis_chat(message=data.message, history=history)
    return JarvisChatResponse(response=response)
