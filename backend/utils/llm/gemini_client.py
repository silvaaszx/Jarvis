# backend/utils/llm/gemini_client.py
import os
from typing import Optional
from google import genai
from google.genai import types

_client = None

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

GEMINI_MODEL = "gemini-2.5-flash"


def get_gemini_client() -> genai.Client:
    global _client
    if _client is None:
        api_key = os.environ["GEMINI_API_KEY"]
        _client = genai.Client(api_key=api_key)
    return _client


async def jarvis_chat_stream(message: str, history: Optional[list] = None):
    """Stream Jarvis response token-by-token. Yields text chunks."""
    client = get_gemini_client()
    contents = []
    for turn in history or []:
        role = turn.get("role", "user")
        parts = turn.get("parts", [])
        text = parts[0] if parts else ""
        contents.append(types.Content(role=role, parts=[types.Part(text=text)]))
    contents.append(types.Content(role="user", parts=[types.Part(text=message)]))

    async for chunk in await client.aio.models.generate_content_stream(
        model=GEMINI_MODEL,
        contents=contents,
        config=types.GenerateContentConfig(system_instruction=JARVIS_SYSTEM_PROMPT),
    ):
        if chunk.text:
            yield chunk.text


async def jarvis_chat(message: str, history: Optional[list] = None) -> str:
    """
    Send a message to Jarvis (Gemini 2.5 Flash) and return the response.
    history: list of {"role": "user"|"model", "parts": [str]}
    """
    client = get_gemini_client()

    contents = []
    for turn in history or []:
        role = turn.get("role", "user")
        parts = turn.get("parts", [])
        text = parts[0] if parts else ""
        contents.append(types.Content(role=role, parts=[types.Part(text=text)]))
    contents.append(types.Content(role="user", parts=[types.Part(text=message)]))

    response = await client.aio.models.generate_content(
        model=GEMINI_MODEL,
        contents=contents,
        config=types.GenerateContentConfig(system_instruction=JARVIS_SYSTEM_PROMPT),
    )
    return response.text
