# backend/database/supabase_conversations.py
from datetime import datetime, timezone
from typing import Optional, List
from utils.supabase_client import get_supabase
import logging

logger = logging.getLogger(__name__)


async def save_conversation(
    user_id: str,
    transcript: str,
    summary: Optional[str] = None,
    started_at: Optional[datetime] = None,
    finished_at: Optional[datetime] = None,
) -> Optional[str]:
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


async def get_conversations(user_id: str, limit: int = 20) -> List[dict]:
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
