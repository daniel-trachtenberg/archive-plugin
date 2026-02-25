from fastapi import (
    APIRouter,
    File,
    UploadFile,
    HTTPException,
    Query,
)
import services.filesystem_service as filesystem
import services.chroma_service as chroma
import services.credentials_service as credentials
import services.move_log_service as move_logs
import utils
import os
from config import settings
from pathlib import Path
from pydantic import BaseModel

router = APIRouter()

DOCUMENT_EXTENSIONS = (
    ".pdf",
    ".txt",
    ".md",
    ".rtf",
    ".doc",
    ".docx",
    ".ppt",
    ".pptx",
    ".xls",
    ".xlsx",
    ".csv",
)

IMAGE_EXTENSIONS = (
    ".jpeg",
    ".jpg",
    ".png",
    ".gif",
    ".webp",
    ".heic",
    ".heif",
)


# New model for directory configuration
class DirectoryConfig(BaseModel):
    input_dir: str
    archive_dir: str


class LLMConfig(BaseModel):
    provider: str
    model: str
    base_url: str = ""
    api_key: str = ""


class LLMConfigResponse(BaseModel):
    provider: str
    model: str
    base_url: str = ""
    api_key_masked: str = ""


class LLMAPIKeyConfig(BaseModel):
    provider: str
    api_key: str


class LLMAPIKeyResponse(BaseModel):
    provider: str
    api_key_masked: str = ""


class MoveLogEntry(BaseModel):
    id: int
    created_at: str
    source_path: str
    destination_path: str
    item_type: str
    trigger: str
    status: str
    note: str = ""


class MoveLogResponse(BaseModel):
    timeframe_hours: int
    total: int
    logs: list[MoveLogEntry]


def _mask_api_key(value: str) -> str:
    if not value:
        return ""
    if len(value) <= 7:
        return f"{value[0]}..."
    return f"{value[:3]}...{value[-4:]}"


def _get_provider_api_key(provider: str) -> str:
    try:
        return credentials.get_provider_api_key(provider, settings)
    except RuntimeError as exc:
        raise HTTPException(status_code=500, detail=str(exc))


def _set_provider_api_key(provider: str, value: str) -> None:
    try:
        credentials.set_provider_api_key(provider, value, settings)
    except RuntimeError as exc:
        raise HTTPException(status_code=500, detail=str(exc))


def _sync_active_api_key(provider: str) -> None:
    settings.LLM_API_KEY = _get_provider_api_key(provider)


def _is_hidden_path(path: str) -> bool:
    normalized = Path(path)
    for part in normalized.parts:
        if not part or part in (os.sep, "."):
            continue
        if part.startswith("."):
            return True
    return False


@router.post("/upload")
async def upload_file(file: UploadFile = File(...)):
    """
    Manually upload a file to be processed and archived.
    """
    content = await file.read()
    filename_lower = file.filename.lower()
    path = None
    if filename_lower.endswith(DOCUMENT_EXTENSIONS):
        path = await utils.process_document(
            filename=file.filename,
            content=content,
            source_path=f"manual-upload:{file.filename}",
        )
    elif filename_lower.endswith(IMAGE_EXTENSIONS):
        path = await utils.process_image(
            filename=file.filename,
            content=content,
            source_path=f"manual-upload:{file.filename}",
        )
    else:
        raise HTTPException(
            status_code=400,
            detail="The provided filetype is not supported. Please upload a file with a supported extension.",
        )

    if path:
        print(f"File manually uploaded and moved to: {path}")
        return {"message": "File processed successfully", "path": path}
    else:
        raise HTTPException(status_code=500, detail="Failed to process the file.")


@router.get("/query")
async def query(
    query_text: str = Query(),
    n_results: int = Query(5),
):
    """
    Query the vector database for files matching the query text.
    Returns file paths that can be opened directly from the Archive folder.
    """
    if not query_text:
        raise HTTPException(status_code=400, detail="Query text must be provided.")

    results = chroma.query_collection(query_text=query_text, n_results=n_results)

    formatted_results = (
        results["ids"][0] if results["ids"] and results["ids"][0] else []
    )

    # Convert to full filesystem paths for easy access and drop stale entries.
    full_paths = []
    seen = set()
    for relative_path in formatted_results:
        if _is_hidden_path(relative_path):
            continue

        absolute_path = os.path.join(settings.ARCHIVE_DIR, relative_path)
        if _is_hidden_path(absolute_path):
            continue

        if absolute_path in seen:
            continue
        if os.path.exists(absolute_path):
            full_paths.append(absolute_path)
            seen.add(absolute_path)

    return {"results": full_paths}


@router.get("/stats")
async def get_stats():
    """
    Get basic statistics about the archive.
    """
    try:
        structure = filesystem.get_directory_structure()

        # Count files and directories
        def count_items(node):
            if node["type"] == "file":
                return 1, 0

            files = 0
            dirs = 1  # Count this directory

            for child in node["children"].values():
                child_files, child_dirs = count_items(child)
                files += child_files
                dirs += child_dirs

            return files, dirs

        total_files, total_dirs = count_items(structure)

        return {
            "total_files": total_files,
            "total_directories": total_dirs,
            "input_directory": settings.INPUT_DIR,
            "archive_directory": settings.ARCHIVE_DIR,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to get stats: {str(e)}")


@router.get("/directories", response_model=DirectoryConfig)
async def get_directories():
    """
    Get the current input and archive directories.
    """
    return {"input_dir": settings.INPUT_DIR, "archive_dir": settings.ARCHIVE_DIR}


# Helper function to update .env file
def update_env_values(values: dict):
    """Update selected keys in the backend .env file."""
    env_path = os.path.expanduser(
        getattr(settings, "ENV_PATH", "")
        or os.path.join(os.path.dirname(__file__), ".env")
    )
    env_dir = os.path.dirname(env_path)
    if env_dir:
        Path(env_dir).mkdir(parents=True, exist_ok=True)

    if not os.path.exists(env_path):
        with open(env_path, "w") as f:
            for key, value in values.items():
                f.write(f"{key}={value}\n")
        return

    with open(env_path, "r") as f:
        lines = f.readlines()

    new_lines = []
    found_keys = set()

    for line in lines:
        stripped = line.strip()
        replaced = False
        for key, value in values.items():
            if stripped.startswith(f"{key}="):
                new_lines.append(f"{key}={value}\n")
                found_keys.add(key)
                replaced = True
                break
        if not replaced:
            new_lines.append(line)

    for key, value in values.items():
        if key not in found_keys:
            new_lines.append(f"{key}={value}\n")

    with open(env_path, "w") as f:
        f.writelines(new_lines)


@router.put("/directories", response_model=DirectoryConfig)
async def update_directories(config: DirectoryConfig):
    """
    Update the input and archive directories.
    """
    try:
        # Validate if paths exist or can be created
        input_path = Path(config.input_dir)
        archive_path = Path(config.archive_dir)

        # Create directories if they don't exist
        input_path.mkdir(parents=True, exist_ok=True)
        archive_path.mkdir(parents=True, exist_ok=True)

        # Update settings
        settings.INPUT_DIR = str(input_path)
        settings.ARCHIVE_DIR = str(archive_path)

        # Also update ChromaDB directory which is based on archive directory
        settings.CHROMA_DB_DIR = os.path.join(settings.ARCHIVE_DIR, ".chromadb")
        Path(settings.CHROMA_DB_DIR).mkdir(parents=True, exist_ok=True)

        # Save settings to .env file for persistence
        update_env_values(
            {
                "ARCHIVE_DIR": str(archive_path),
                "INPUT_DIR": str(input_path),
            }
        )

        # Import the restart function here to avoid circular imports
        from main import restart_file_watcher

        # Restart the file watcher with new directory settings
        restart_file_watcher()

        return {"input_dir": settings.INPUT_DIR, "archive_dir": settings.ARCHIVE_DIR}
    except Exception as e:
        raise HTTPException(
            status_code=500, detail=f"Failed to update directories: {str(e)}"
        )


@router.get("/llm-settings", response_model=LLMConfigResponse)
async def get_llm_settings():
    """
    Get active LLM provider settings (API key returned masked).
    """
    try:
        if credentials.migrate_plaintext_keys(settings):
            update_env_values({**credentials.provider_api_env_values(settings)})
    except RuntimeError as exc:
        raise HTTPException(status_code=500, detail=str(exc))

    provider = (settings.LLM_PROVIDER or "openai").lower()
    model = settings.LLM_MODEL or "gpt-5.2"
    base_url = settings.LLM_BASE_URL or ""

    if provider == "ollama":
        base_url = settings.OLLAMA_BASE_URL or "http://localhost:11434"
        model = settings.OLLAMA_MODEL or "llama3.2"
    elif provider == "openai":
        base_url = base_url or "https://api.openai.com/v1"
        model = settings.LLM_MODEL or "gpt-5.2"
    elif provider == "anthropic":
        base_url = base_url or "https://api.anthropic.com"
        model = settings.LLM_MODEL or "claude-sonnet-4-6"
    elif provider == "openai_compatible":
        base_url = base_url or "http://localhost:1234/v1"
        model = settings.LLM_MODEL or "gpt-5.2"

    api_key_masked = _mask_api_key(_get_provider_api_key(provider))

    return {
        "provider": provider,
        "model": model,
        "base_url": base_url,
        "api_key_masked": api_key_masked,
    }


@router.put("/llm-settings", response_model=LLMConfigResponse)
async def update_llm_settings(config: LLMConfig):
    """
    Update LLM provider settings and persist to .env.
    """
    try:
        provider = (config.provider or "openai").strip().lower()
        if provider not in {"ollama", "openai", "anthropic", "openai_compatible"}:
            raise HTTPException(status_code=400, detail="Unsupported provider.")

        model = (config.model or "").strip()
        if not model:
            raise HTTPException(status_code=400, detail="Model is required.")

        base_url = (config.base_url or "").strip()
        api_key = (config.api_key or "").strip()

        if provider == "ollama":
            if not base_url:
                base_url = "http://localhost:11434"
            settings.OLLAMA_BASE_URL = base_url
            settings.OLLAMA_MODEL = model
        elif provider == "openai":
            if not base_url:
                base_url = "https://api.openai.com/v1"
        elif provider == "anthropic":
            if not base_url:
                base_url = "https://api.anthropic.com"
        elif provider == "openai_compatible":
            if not base_url:
                base_url = "http://localhost:1234/v1"

        settings.LLM_PROVIDER = provider
        settings.LLM_MODEL = model
        settings.LLM_BASE_URL = base_url

        # Optional inline key update (used by older clients)
        if provider != "ollama" and api_key:
            _set_provider_api_key(provider, api_key)

        _sync_active_api_key(provider)

        update_env_values(
            {
                "LLM_PROVIDER": provider,
                "LLM_MODEL": model,
                "LLM_BASE_URL": base_url,
                **credentials.provider_api_env_values(settings),
                "OLLAMA_BASE_URL": settings.OLLAMA_BASE_URL,
                "OLLAMA_MODEL": settings.OLLAMA_MODEL,
            }
        )

        return {
            "provider": provider,
            "model": model,
            "base_url": base_url,
            "api_key_masked": _mask_api_key(_get_provider_api_key(provider)),
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(
            status_code=500, detail=f"Failed to update LLM settings: {str(e)}"
        )


@router.get("/llm-api-key", response_model=LLMAPIKeyResponse)
async def get_llm_api_key(provider: str = Query()):
    try:
        if credentials.migrate_plaintext_keys(settings):
            update_env_values({**credentials.provider_api_env_values(settings)})
    except RuntimeError as exc:
        raise HTTPException(status_code=500, detail=str(exc))

    provider = (provider or "").strip().lower()
    if provider not in {"openai", "anthropic", "openai_compatible"}:
        raise HTTPException(status_code=400, detail="Unsupported provider.")
    return {
        "provider": provider,
        "api_key_masked": _mask_api_key(_get_provider_api_key(provider)),
    }


@router.put("/llm-api-key", response_model=LLMAPIKeyResponse)
async def add_or_update_llm_api_key(config: LLMAPIKeyConfig):
    provider = (config.provider or "").strip().lower()
    if provider not in {"openai", "anthropic", "openai_compatible"}:
        raise HTTPException(status_code=400, detail="Unsupported provider.")

    api_key = (config.api_key or "").strip()
    if not api_key:
        raise HTTPException(status_code=400, detail="API key is required.")

    _set_provider_api_key(provider, api_key)
    if settings.LLM_PROVIDER == provider:
        _sync_active_api_key(provider)

    update_env_values(
        {
            **credentials.provider_api_env_values(settings),
        }
    )

    return {"provider": provider, "api_key_masked": _mask_api_key(api_key)}


@router.delete("/llm-api-key", response_model=LLMAPIKeyResponse)
async def delete_llm_api_key(provider: str = Query()):
    provider = (provider or "").strip().lower()
    if provider not in {"openai", "anthropic", "openai_compatible"}:
        raise HTTPException(status_code=400, detail="Unsupported provider.")

    _set_provider_api_key(provider, "")
    if settings.LLM_PROVIDER == provider:
        _sync_active_api_key(provider)

    update_env_values(
        {
            **credentials.provider_api_env_values(settings),
        }
    )

    return {"provider": provider, "api_key_masked": ""}


@router.get("/move-logs", response_model=MoveLogResponse)
async def get_move_logs(
    hours: int = Query(24, ge=1, le=24 * 365),
    limit: int = Query(200, ge=1, le=1000),
):
    """
    Return recent plugin move logs for debugging.
    """
    try:
        logs = move_logs.list_move_logs(hours=hours, limit=limit)
        return {"timeframe_hours": hours, "total": len(logs), "logs": logs}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to fetch move logs: {str(e)}")


@router.post("/reconcile")
async def reconcile():
    """
    Manually trigger reconciliation between filesystem and ChromaDB.
    """
    try:
        print("\n=================================================")
        print("          MANUAL RECONCILIATION TRIGGERED        ")
        print("=================================================")

        result = await utils.reconcile_filesystem_with_chroma()

        if result:
            print("Manual reconciliation completed successfully!")
            print("=================================================\n")
            return {
                "status": "success",
                "message": "Reconciliation completed successfully",
            }
        else:
            print("ERROR: Manual reconciliation failed")
            print("=================================================\n")
            raise HTTPException(status_code=500, detail="Reconciliation failed")
    except Exception as e:
        print(f"ERROR: Manual reconciliation failed: {str(e)}")
        print("=================================================\n")
        raise HTTPException(status_code=500, detail=f"Reconciliation failed: {str(e)}")
