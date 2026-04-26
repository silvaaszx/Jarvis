# backend/utils/llm/jarvis_memory.py
"""
Jarvis Memory — Fase 5
Persiste conversas e fatos no Firestore. Injeta contexto nas próximas respostas.

Resource Safety:
- Máximo _MAX_TURNS_IN_PROMPT turns no contexto (nunca carrega tudo na RAM)
- Máximo _MAX_FACTS_IN_PROMPT fatos no contexto
- Textos truncados em _MAX_TEXT_LEN antes de salvar
- Todos os erros são capturados — nunca derruba o chat
"""
import asyncio
import logging
from datetime import datetime, timezone

logger = logging.getLogger(__name__)

# ─── Limites de memória (Resource Safety) ─────────────────────────────────────
_MAX_TURNS_IN_PROMPT  = 20     # turns injetados no system prompt
_MAX_FACTS_IN_PROMPT  = 10     # fatos injetados no system prompt
_MAX_TURNS_PER_QUERY  = 30     # lidos do Firestore (filtramos para 20)
_MAX_TEXT_LEN         = 1500   # trunca texto antes de salvar
_MAX_FACT_LEN         = 400    # trunca fato antes de salvar

_SESSIONS_COL = "jarvis_sessions"
_FACTS_COL    = "jarvis_facts"


def _cut(text: str, max_len: int) -> str:
    return text[:max_len] if len(text) > max_len else text


# ─── Persistência de turns ────────────────────────────────────────────────────

async def save_turn(uid: str, session_id: str, user_msg: str, jarvis_msg: str) -> None:
    """Salva turno user+jarvis no Firestore. Falha silenciosamente."""
    try:
        from database._client import db
        loop = asyncio.get_event_loop()
        col = db.collection(_SESSIONS_COL).document(uid).collection(session_id)
        payload = {
            "user":   _cut(user_msg, _MAX_TEXT_LEN),
            "jarvis": _cut(jarvis_msg, _MAX_TEXT_LEN),
            "ts":     datetime.now(timezone.utc).isoformat(),
        }
        await loop.run_in_executor(None, lambda: col.add(payload))
    except Exception as e:
        logger.warning(f"jarvis_memory.save_turn failed (uid={uid[:8]}): {e}")


async def get_recent_turns(uid: str, session_id: str) -> list[dict]:
    """Retorna os últimos _MAX_TURNS_IN_PROMPT turns da sessão atual."""
    try:
        from database._client import db
        loop = asyncio.get_event_loop()
        col = db.collection(_SESSIONS_COL).document(uid).collection(session_id)
        docs = await loop.run_in_executor(
            None,
            lambda: list(
                col.order_by("ts", direction="DESCENDING")
                   .limit(_MAX_TURNS_PER_QUERY)
                   .stream()
            ),
        )
        turns = [d.to_dict() for d in docs]
        turns.reverse()  # ordem cronológica
        return turns[-_MAX_TURNS_IN_PROMPT:]
    except Exception as e:
        logger.warning(f"jarvis_memory.get_recent_turns failed (uid={uid[:8]}): {e}")
        return []


# ─── Fatos de longo prazo ─────────────────────────────────────────────────────

async def save_fact(uid: str, fact: str) -> None:
    """Salva um fato permanente sobre o Matheus."""
    try:
        from database._client import db
        loop = asyncio.get_event_loop()
        col = db.collection(_FACTS_COL).document(uid).collection("facts")
        await loop.run_in_executor(
            None,
            lambda: col.add({
                "fact": _cut(fact, _MAX_FACT_LEN),
                "ts":   datetime.now(timezone.utc).isoformat(),
            }),
        )
    except Exception as e:
        logger.warning(f"jarvis_memory.save_fact failed (uid={uid[:8]}): {e}")


async def get_facts(uid: str) -> list[str]:
    """Retorna os últimos _MAX_FACTS_IN_PROMPT fatos do usuário."""
    try:
        from database._client import db
        loop = asyncio.get_event_loop()
        col = db.collection(_FACTS_COL).document(uid).collection("facts")
        docs = await loop.run_in_executor(
            None,
            lambda: list(
                col.order_by("ts", direction="DESCENDING")
                   .limit(_MAX_FACTS_IN_PROMPT)
                   .stream()
            ),
        )
        return [d.to_dict().get("fact", "") for d in docs if d.to_dict().get("fact")]
    except Exception as e:
        logger.warning(f"jarvis_memory.get_facts failed (uid={uid[:8]}): {e}")
        return []


# ─── Extração de fatos (fire-and-forget) ─────────────────────────────────────

async def extract_and_save_facts(uid: str, user_msg: str, jarvis_msg: str) -> None:
    """
    Extrai fatos relevantes da conversa via Gemini e salva.
    Roda em background — nunca bloqueia a resposta ao usuário.
    """
    try:
        from utils.llm.gemini_client import get_gemini_client, GEMINI_MODEL
        from google.genai import types

        prompt = (
            "Analise esta troca e extraia ATÉ 2 fatos concretos e duradouros sobre "
            "o Matheus Silvaa (preferências, rotinas, relacionamentos, projetos). "
            "Responda SOMENTE com os fatos, um por linha, começando com '-'. "
            "Se não há nada relevante, responda 'nenhum'.\n\n"
            f"Matheus disse: {_cut(user_msg, 500)}\n"
            f"Jarvis respondeu: {_cut(jarvis_msg, 500)}"
        )
        client = get_gemini_client()
        response = await client.aio.models.generate_content(
            model=GEMINI_MODEL,
            contents=[types.Content(role="user", parts=[types.Part(text=prompt)])],
        )
        text = (response.text or "").strip()
        if text.lower().startswith("nenhum"):
            return
        for line in text.splitlines():
            line = line.lstrip("- ").strip()
            if line:
                await save_fact(uid, line)
    except Exception as e:
        logger.warning(f"jarvis_memory.extract_and_save_facts failed (uid={uid[:8]}): {e}")


# ─── Montagem do contexto ─────────────────────────────────────────────────────

def build_memory_context(turns: list[dict], facts: list[str]) -> str:
    """
    Monta bloco de texto para injetar no system prompt do Gemini.
    Nunca excede ~3000 chars (~750 tokens) para não inflar o contexto.
    """
    parts = []

    if facts:
        facts_text = "\n".join(f"- {f}" for f in facts[:_MAX_FACTS_IN_PROMPT])
        parts.append(f"O QUE JARVIS SABE SOBRE MATHEUS:\n{facts_text}")

    if turns:
        lines = []
        for t in turns[-_MAX_TURNS_IN_PROMPT:]:
            u = _cut(t.get("user", ""), 200)
            j = _cut(t.get("jarvis", ""), 200)
            if u:
                lines.append(f"Matheus: {u}")
            if j:
                lines.append(f"Jarvis: {j}")
        if lines:
            parts.append("HISTÓRICO DESTA SESSÃO:\n" + "\n".join(lines))

    return "\n\n".join(parts)
