import os
from dotenv import load_dotenv
from pathlib import Path

DEFAULT_ENV_PATH = Path(__file__).resolve().parent / ".env"
ENV_PATH = Path(
    os.path.expanduser(os.getenv("ARCHIVE_ENV_PATH", str(DEFAULT_ENV_PATH)))
).resolve()

# Load environment variables from the configured .env path if present.
load_dotenv(dotenv_path=ENV_PATH, override=False)

class Settings:
    # Environment configuration
    ENV_PATH: str = str(ENV_PATH)

    # Application settings
    APP_TITLE: str = "Archive"
    APP_DESCRIPTION: str = (
        "An application for managing local file organization and categorizations."
    )
    APP_VERSION: str = "1.0.0"

    # FastAPI server configuration
    HOST: str = os.getenv("HOST", "0.0.0.0")
    PORT: int = int(os.getenv("PORT", 8000))

    # LLM provider configuration
    LLM_PROVIDER: str = os.getenv("LLM_PROVIDER", "openai")
    LLM_MODEL: str = os.getenv("LLM_MODEL", "gpt-5.2")
    LLM_BASE_URL: str = os.getenv("LLM_BASE_URL", "")
    LLM_API_KEY: str = os.getenv("LLM_API_KEY", "")
    OPENAI_API_KEY: str = os.getenv("OPENAI_API_KEY", "")
    ANTHROPIC_API_KEY: str = os.getenv("ANTHROPIC_API_KEY", "")
    OPENAI_COMPATIBLE_API_KEY: str = os.getenv("OPENAI_COMPATIBLE_API_KEY", "")
    OPENAI_API_KEY_ENC: str = os.getenv("OPENAI_API_KEY_ENC", "")
    ANTHROPIC_API_KEY_ENC: str = os.getenv("ANTHROPIC_API_KEY_ENC", "")
    OPENAI_COMPATIBLE_API_KEY_ENC: str = os.getenv("OPENAI_COMPATIBLE_API_KEY_ENC", "")

    # Ollama configuration (used when provider is ollama)
    OLLAMA_BASE_URL: str = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
    OLLAMA_MODEL: str = os.getenv("OLLAMA_MODEL", "llama3.2")

    # AI Model
    AI_MODEL: str = "ollama"

    # File system configuration
    # Defaults: input = ~/Downloads, archive = ~/Desktop
    USER_HOME = os.path.expanduser("~")
    ARCHIVE_DIR: str = os.getenv("ARCHIVE_DIR", os.path.join(USER_HOME, "Desktop"))
    INPUT_DIR: str = os.getenv("INPUT_DIR", os.path.join(USER_HOME, "Downloads"))

    # Create directories if they don't exist
    Path(ARCHIVE_DIR).mkdir(parents=True, exist_ok=True)
    Path(INPUT_DIR).mkdir(parents=True, exist_ok=True)

    # ChromaDB configuration
    CHROMA_DB_DIR: str = os.getenv(
        "CHROMA_DB_DIR", os.path.join(ARCHIVE_DIR, ".chromadb")
    )
    Path(CHROMA_DB_DIR).mkdir(parents=True, exist_ok=True)

    # Move log storage
    MOVE_LOG_DB_PATH: str = os.path.expanduser(
        os.getenv(
            "MOVE_LOG_DB_PATH",
            os.path.join(USER_HOME, ".archive-plugin", "move_logs.db"),
        )
    )
    Path(os.path.dirname(MOVE_LOG_DB_PATH)).mkdir(parents=True, exist_ok=True)


settings = Settings()
