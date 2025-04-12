import os
from dotenv import load_dotenv
from pathlib import Path

# Load environment variables from a .env file if present
load_dotenv()


class Settings:
    # Application settings
    APP_TITLE: str = "Archive"
    APP_DESCRIPTION: str = (
        "An application for managing local file organization and categorizations."
    )
    APP_VERSION: str = "1.0.0"

    # FastAPI server configuration
    HOST: str = os.getenv("HOST", "0.0.0.0")
    PORT: int = int(os.getenv("PORT", 8000))

    # Ollama configuration
    OLLAMA_BASE_URL: str = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
    OLLAMA_MODEL: str = os.getenv("OLLAMA_MODEL", "llama3")

    # AI Model
    AI_MODEL: str = "ollama"  # Only using ollama for local LLM

    # File system configuration
    # Base directory for archive storage (defaults to Desktop/Archive)
    USER_HOME = os.path.expanduser("~")
    ARCHIVE_DIR: str = os.getenv(
        "ARCHIVE_DIR", os.path.join(USER_HOME, "Desktop", "Archive")
    )
    INPUT_DIR: str = os.getenv("INPUT_DIR", os.path.join(USER_HOME, "Desktop", "Input"))

    # Create directories if they don't exist
    Path(ARCHIVE_DIR).mkdir(parents=True, exist_ok=True)
    Path(INPUT_DIR).mkdir(parents=True, exist_ok=True)

    # ChromaDB configuration
    CHROMA_DB_DIR: str = os.getenv(
        "CHROMA_DB_DIR", os.path.join(ARCHIVE_DIR, ".chromadb")
    )
    Path(CHROMA_DB_DIR).mkdir(parents=True, exist_ok=True)


settings = Settings()
