cat >/tmp/installer-full.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/telegram-ai-bot"
SERVICE_NAME="telegram-ai-bot"
PY_BIN="$APP_DIR/.venv/bin/python"
RUN_USER="${SUDO_USER:-$(whoami)}"
NO_GIT="${1:-}"

sudo mkdir -p "$APP_DIR"
sudo chown -R "$RUN_USER:$RUN_USER" "$APP_DIR"

cd "$APP_DIR"
mkdir -p bot deploy scripts storage/generated

read -r -p "Enter TELEGRAM_BOT_TOKEN: " TELEGRAM_BOT_TOKEN
read -r -p "Enter GEMINI_API_KEY: " GEMINI_API_KEY
read -r -p "Enter allowed Telegram user ID [83862736]: " ALLOWED_USER_IDS
ALLOWED_USER_IDS="${ALLOWED_USER_IDS:-83862736}"

cat > requirements.txt << 'EOT'
python-telegram-bot==21.7
google-genai==1.30.0
python-dotenv==1.0.1
pypdf==5.0.1
python-docx==1.1.2
Pillow==10.4.0
EOT

cat > .env << EOT
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
ALLOWED_USER_IDS=$ALLOWED_USER_IDS
GEMINI_API_KEY=$GEMINI_API_KEY
GEMINI_FLASH_MODEL=gemini-2.5-flash
GEMINI_PRO_MODEL=gemini-2.5-pro
GEMINI_IMAGE_MODEL=gemini-2.5-flash-image-preview
MAX_TURNS=24
SUMMARIZE_AFTER_TURNS=18
MAX_SUMMARY_CHARS=4000
LOG_LEVEL=INFO
EOT

cat > bot/__init__.py << 'EOT'
# package marker
EOT

cat > bot/config.py << 'EOT'
import os
from dataclasses import dataclass
from dotenv import load_dotenv
load_dotenv()
def _int_set_from_csv(value: str) -> set[int]:
    out: set[int] = set()
    for p in (value or "").split(","):
        p = p.strip()
        if p: out.add(int(p))
    return out
@dataclass(frozen=True)
class Settings:
    telegram_bot_token: str
    allowed_user_ids: set[int]
    gemini_api_key: str
    gemini_flash_model: str
    gemini_pro_model: str
    gemini_image_model: str
    max_turns: int
    summarize_after_turns: int
    max_summary_chars: int
    log_level: str
settings = Settings(
    telegram_bot_token=os.getenv("TELEGRAM_BOT_TOKEN", ""),
    allowed_user_ids=_int_set_from_csv(os.getenv("ALLOWED_USER_IDS", "")),
    gemini_api_key=os.getenv("GEMINI_API_KEY", ""),
    gemini_flash_model=os.getenv("GEMINI_FLASH_MODEL", "gemini-2.5-flash"),
    gemini_pro_model=os.getenv("GEMINI_PRO_MODEL", "gemini-2.5-pro"),
    gemini_image_model=os.getenv("GEMINI_IMAGE_MODEL", "gemini-2.5-flash-image-preview"),
    max_turns=int(os.getenv("MAX_TURNS", "24")),
    summarize_after_turns=int(os.getenv("SUMMARIZE_AFTER_TURNS", "18")),
    max_summary_chars=int(os.getenv("MAX_SUMMARY_CHARS", "4000")),
    log_level=os.getenv("LOG_LEVEL", "INFO"),
)
if not settings.telegram_bot_token: raise RuntimeError("TELEGRAM_BOT_TOKEN is required")
if not settings.gemini_api_key: raise RuntimeError("GEMINI_API_KEY is required")
if not settings.allowed_user_ids: raise RuntimeError("ALLOWED_USER_IDS required")
EOT

cat > bot/storage.py << 'EOT'
import json
from pathlib import Path
from threading import RLock
from typing import Any
class JsonStore:
    def __init__(self, root: str = "storage") -> None:
        self.root = Path(root); self.root.mkdir(parents=True, exist_ok=True)
        self.state_file = self.root / "state.json"; self._lock = RLock()
        if not self.state_file.exists(): self._write({"chats": {}})
    def _read(self) -> dict[str, Any]:
        with self._lock: return json.loads(self.state_file.read_text(encoding="utf-8"))
    def _write(self, data: dict[str, Any]) -> None:
        with self._lock: self.state_file.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    def get_chat(self, chat_id: int) -> dict[str, Any]:
        data = self._read(); chats = data.setdefault("chats", {}); key = str(chat_id)
        if key not in chats:
            chats[key] = {"model_mode":"flash","summary":"","turns":[],"last_generated_image":None}; self._write(data)
        return chats[key]
    def save_chat(self, chat_id: int, chat_data: dict[str, Any]) -> None:
        data = self._read(); data.setdefault("chats", {})[str(chat_id)] = chat_data; self._write(data)
EOT

cat > bot/memory.py << 'EOT'
from typing import Any
class ConversationMemory:
    def __init__(self, max_turns: int, summarize_after_turns: int) -> None:
        self.max_turns=max_turns; self.summarize_after_turns=summarize_after_turns
    def append_turn(self, chat_data: dict[str, Any], role: str, content: str) -> None:
        turns=chat_data.setdefault("turns",[]); turns.append({"role":role,"content":content})
        if len(turns)>self.max_turns: del turns[0:len(turns)-self.max_turns]
    def should_summarize(self, chat_data: dict[str, Any]) -> bool:
        return len(chat_data.get("turns",[]))>=self.summarize_after_turns
    def reset(self, chat_data: dict[str, Any]) -> None:
        chat_data["summary"]=""; chat_data["turns"]=[]; chat_data["last_generated_image"]=None
    @staticmethod
    def build_prompt(chat_data: dict[str, Any], user_input: str) -> str:
        summary=chat_data.get("summary","").strip(); turns=chat_data.get("turns",[]); chunks=[]
        if summary: chunks.append(f"Conversation summary so far:\n{summary}")
        if turns:
            chunks.append("Recent turns:")
            for t in turns: chunks.append(f"- {t['role']}: {t['content']}")
        chunks.append(f"Current user input: {user_input}")
        return "\n".join(chunks)
EOT

cat > bot/gemini_service.py << 'EOT'
import base64
from google import genai
from google.genai import types
class GeminiService:
    def __init__(self, api_key, flash_model, pro_model, image_model, max_summary_chars):
        self.client=genai.Client(api_key=api_key); self.flash_model=flash_model; self.pro_model=pro_model
        self.image_model=image_model; self.max_summary_chars=max_summary_chars
    def _model_name(self, mode): return self.flash_model if mode=="flash" else self.pro_model
    def chat_text(self, mode, prompt):
        r=self.client.models.generate_content(model=self._model_name(mode), contents=prompt, config=types.GenerateContentConfig(temperature=0.7))
        return (r.text or "").strip() or "I could not generate a response."
    def summarize_turns(self, mode, existing_summary, turns):
        txt="\n".join([f"{t['role']}: {t['content']}" for t in turns])
        p=("Update and compress this conversation summary while preserving important user preferences, goals, facts, pending tasks, and constraints. Keep it concise and factual.\n\n"
           f"Existing summary:\n{existing_summary or '(none)'}\n\nNew turns:\n{txt}\n")
        return self.chat_text(mode,p)[:self.max_summary_chars]
    def chat_with_image(self, mode, user_text, image_bytes, mime_type):
        r=self.client.models.generate_content(model=self._model_name(mode), contents=[types.Part.from_text(text=user_text), types.Part.from_bytes(data=image_bytes,mime_type=mime_type)])
        return (r.text or "").strip() or "I processed the image but have no textual response."
    def extract_text_from_document(self, mode, filename, content):
        return self.chat_text(mode, f"You are given document text from file '{filename}'. Extract key points and provide a concise useful summary.\n\nDocument text:\n{content[:20000]}")
    def generate_image(self, user_prompt):
        r=self.client.models.generate_content(model=self.image_model, contents=user_prompt, config=types.GenerateContentConfig(response_modalities=["IMAGE","TEXT"]))
        image_data=None; mime="image/png"
        for c in (getattr(r,"candidates",None) or []):
            for p in (getattr(getattr(c,"content",None),"parts",None) or []):
                d=getattr(p,"inline_data",None)
                if d and getattr(d,"data",None): image_data=d.data; mime=getattr(d,"mime_type",None) or mime; break
            if image_data: break
        if image_data is None: raise RuntimeError("No image returned by Gemini.")
        return (base64.b64decode(image_data) if isinstance(image_data,str) else image_data), mime
EOT

cat > bot/documents.py << 'EOT'
from io import BytesIO
from docx import Document
from pypdf import PdfReader
def extract_pdf_text(data: bytes) -> str:
    r=PdfReader(BytesIO(data)); return "\n".join([(p.extract_text() or "") for p in r.pages]).strip()
def extract_txt_text(data: bytes) -> str:
    return data.decode("utf-8", errors="ignore").strip()
def extract_docx_text(data: bytes) -> str:
    d=Document(BytesIO(data)); return "\n".join([p.text for p in d.paragraphs]).strip()
EOT

cat > bot/ui.py << 'EOT'
from telegram import InlineKeyboardButton, InlineKeyboardMarkup
def main_keyboard(current_mode: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("✅ Flash" if current_mode=="flash" else "Flash", callback_data="mode:flash"),
         InlineKeyboardButton("✅ Pro" if current_mode=="pro" else "Pro", callback_data="mode:pro")],
        [InlineKeyboardButton("🆕 New Chat", callback_data="new_chat")],
        [InlineKeyboardButton("⬇️ Download Original", callback_data="download_original")]
    ])
EOT

cat > bot/main.py << 'EOT'
import logging
from pathlib import Path
from telegram import Update
from telegram.constants import ChatAction
from telegram.ext import Application, CallbackQueryHandler, CommandHandler, ContextTypes, MessageHandler, filters
from bot.config import settings
from bot.documents import extract_docx_text, extract_pdf_text, extract_txt_text
from bot.gemini_service import GeminiService
from bot.memory import ConversationMemory
from bot.storage import JsonStore
from bot.ui import main_keyboard
logging.basicConfig(level=getattr(logging, settings.log_level.upper(), logging.INFO))
store=JsonStore("storage")
memory=ConversationMemory(settings.max_turns, settings.summarize_after_turns)
gemini=GeminiService(settings.gemini_api_key, settings.gemini_flash_model, settings.gemini_pro_model, settings.gemini_image_model, settings.max_summary_chars)
GEN_DIR=Path("storage/generated"); GEN_DIR.mkdir(parents=True, exist_ok=True)
def allowed(update): return bool(update.effective_user and update.effective_user.id in settings.allowed_user_ids)
async def reject(update):
    if allowed(update): return False
    if update.effective_message: await update.effective_message.reply_text("Unauthorized.")
    return True
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if await reject(update): return
    chat=store.get_chat(update.effective_chat.id)
    await update.message.reply_text("Welcome. Send text/image/PDF/TXT/DOCX.", reply_markup=main_keyboard(chat.get("model_mode","flash")))
async def cb(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if await reject(update): return
    q=update.callback_query; await q.answer()
    chat_id=update.effective_chat.id; chat=store.get_chat(chat_id)
    if q.data=="mode:flash": chat["model_mode"]="flash"; store.save_chat(chat_id,chat); await q.edit_message_reply_markup(reply_markup=main_keyboard("flash")); return
    if q.data=="mode:pro": chat["model_mode"]="pro"; store.save_chat(chat_id,chat); await q.edit_message_reply_markup(reply_markup=main_keyboard("pro")); return
    if q.data=="new_chat": memory.reset(chat); store.save_chat(chat_id,chat); await q.message.reply_text("Chat memory reset.", reply_markup=main_keyboard(chat.get("model_mode","flash"))); return
    if q.data=="download_original":
        p=chat.get("last_generated_image")
        if not p or not Path(p).exists(): await q.message.reply_text("No generated image available yet."); return
        await q.message.reply_document(document=Path(p).open("rb"), filename=Path(p).name)
async def maybe_sum(chat):
    if not memory.should_summarize(chat): return
    chat["summary"]=gemini.summarize_turns(chat.get("model_mode","flash"), chat.get("summary",""), chat.get("turns",[]))
    chat["turns"]=chat.get("turns",[])[-6:]
async def on_text(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if await reject(update): return
    msg=update.effective_message; chat_id=update.effective_chat.id; chat=store.get_chat(chat_id); mode=chat.get("model_mode","flash")
    txt=(msg.text or "").strip(); low=txt.lower()
    await context.bot.send_chat_action(chat_id=chat_id, action=ChatAction.TYPING)
    if low.startswith("/image ") or low.startswith("draw ") or low.startswith("generate image"):
        prompt=txt.split(" ",1)[1] if " " in txt else txt
        b,m=gemini.generate_image(prompt); ext=".png" if "png" in m else ".jpg"; p=GEN_DIR/f"gen_{chat_id}_{update.update_id}{ext}"; p.write_bytes(b)
        chat["last_generated_image"]=str(p); store.save_chat(chat_id,chat); await msg.reply_photo(photo=p.open("rb"), caption="Generated image.", reply_markup=main_keyboard(mode)); return
    memory.append_turn(chat,"user",txt); await maybe_sum(chat)
    ans=gemini.chat_text(mode, memory.build_prompt(chat,txt))
    memory.append_turn(chat,"assistant",ans); store.save_chat(chat_id,chat)
    await msg.reply_text(ans, reply_markup=main_keyboard(mode))
async def on_photo(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if await reject(update): return
    msg=update.effective_message; chat_id=update.effective_chat.id; chat=store.get_chat(chat_id); mode=chat.get("model_mode","flash")
    f=await context.bot.get_file(msg.photo[-1].file_id); b=bytes(await f.download_as_bytearray()); caption=msg.caption or "Describe this image."
    ans=gemini.chat_with_image(mode, caption, b, "image/jpeg")
    memory.append_turn(chat,"user",f"[Image] {caption}"); memory.append_turn(chat,"assistant",ans); await maybe_sum(chat); store.save_chat(chat_id,chat)
    await msg.reply_text(ans, reply_markup=main_keyboard(mode))
async def on_doc(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if await reject(update): return
    msg=update.effective_message; chat_id=update.effective_chat.id; chat=store.get_chat(chat_id); mode=chat.get("model_mode","flash")
    d=msg.document; name=(d.file_name or "").lower(); f=await context.bot.get_file(d.file_id); data=bytes(await f.download_as_bytearray())
    if name.endswith(".pdf"): text=extract_pdf_text(data)
    elif name.endswith(".txt"): text=extract_txt_text(data)
    elif name.endswith(".docx"): text=extract_docx_text(data)
    else: await msg.reply_text("Unsupported file type. Send PDF, TXT, or DOCX."); return
    if not text.strip(): await msg.reply_text("Could not extract text."); return
    s=gemini.extract_text_from_document(mode, d.file_name or "document", text)
    memory.append_turn(chat,"user",f"[Document:{d.file_name}] uploaded"); memory.append_turn(chat,"assistant",s); await maybe_sum(chat); store.save_chat(chat_id,chat)
    await msg.reply_text(f"Document processed:\n\n{s}", reply_markup=main_keyboard(mode))
def main():
    app=Application.builder().token(settings.telegram_bot_token).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CallbackQueryHandler(cb))
    app.add_handler(MessageHandler(filters.PHOTO, on_photo))
    app.add_handler(MessageHandler(filters.Document.ALL, on_doc))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, on_text))
    app.run_polling(close_loop=False)
if __name__=="__main__": main()
EOT

sudo apt update
sudo apt install -y python3 python3-venv python3-pip
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

cat >/tmp/${SERVICE_NAME}.service <<EOT
[Unit]
Description=Telegram AI Bot (Gemini)
After=network.target
[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$APP_DIR
Environment=PYTHONUNBUFFERED=1
ExecStart=$PY_BIN -m bot.main
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOT

sudo cp /tmp/${SERVICE_NAME}.service /etc/systemd/system/${SERVICE_NAME}.service
sudo systemctl daemon-reload
sudo systemctl enable ${SERVICE_NAME}
sudo systemctl restart ${SERVICE_NAME}

echo "DONE"
echo "Status: sudo systemctl status ${SERVICE_NAME}"
echo "Logs:   journalctl -u ${SERVICE_NAME} -f"
EOF

bash /tmp/installer-full.sh
