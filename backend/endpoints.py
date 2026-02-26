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
import shutil
import re
import time
from config import settings
from pathlib import Path
from pydantic import BaseModel
from difflib import SequenceMatcher

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

PREFERRED_USER_FILE_EXTENSIONS = {
    "pdf",
    "txt",
    "md",
    "rtf",
    "doc",
    "docx",
    "ppt",
    "pptx",
    "xls",
    "xlsx",
    "csv",
    "pages",
    "numbers",
    "key",
    "jpg",
    "jpeg",
    "png",
    "gif",
    "webp",
    "heic",
    "heif",
}

CODE_FILE_EXTENSIONS = {
    "js",
    "jsx",
    "ts",
    "tsx",
    "py",
    "java",
    "c",
    "cc",
    "cpp",
    "h",
    "hpp",
    "go",
    "rs",
    "swift",
    "kt",
    "rb",
    "php",
    "html",
    "css",
    "scss",
    "json",
    "yml",
    "yaml",
    "xml",
    "sh",
    "bash",
    "zsh",
    "sql",
}

CODE_QUERY_HINTS = {
    "code",
    "script",
    "function",
    "class",
    "python",
    "javascript",
    "typescript",
    "html",
    "css",
    "json",
    "yaml",
    "xml",
    "sql",
    "api",
    "backend",
    "frontend",
}

_INDEXED_PATH_CACHE = {"paths": [], "created_at": 0.0}
_INDEXED_PATH_CACHE_TTL_SECONDS = 8


# New model for directory configuration
class DirectoryConfig(BaseModel):
    input_dir: str
    archive_dir: str
    watch_input_dir: bool = True


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


class UninstallCleanupConfig(BaseModel):
    delete_database: bool = True
    delete_move_logs: bool = True
    delete_credentials: bool = True
    delete_backend_support: bool = True


class UninstallCleanupResponse(BaseModel):
    success: bool
    deleted_paths: list[str]
    warnings: list[str]


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


def _remove_path(path: Path, deleted_paths: list[str], warnings: list[str]) -> None:
    try:
        if path.is_symlink() or path.is_file():
            if path.exists() or path.is_symlink():
                path.unlink()
                deleted_paths.append(str(path))
            return

        if path.is_dir():
            shutil.rmtree(path)
            deleted_paths.append(str(path))
    except Exception as exc:
        warnings.append(f"Failed to remove {path}: {exc}")


def _search_tokens(text: str) -> list[str]:
    return [token for token in re.split(r"[^a-z0-9]+", text.lower()) if len(token) >= 2]


def _semantic_score(distance) -> float:
    if distance is None:
        return 0.0
    try:
        normalized = max(float(distance), 0.0)
        return 1.0 / (1.0 + normalized)
    except (TypeError, ValueError):
        return 0.0


def _query_prefers_code(tokens: list[str], normalized_query: str) -> bool:
    if any(token in CODE_QUERY_HINTS or token in CODE_FILE_EXTENSIONS for token in tokens):
        return True
    return normalized_query in CODE_FILE_EXTENSIONS


def _file_type_priority_score(extension: str, query_tokens: list[str], prefers_code: bool) -> float:
    if extension in query_tokens:
        return 1.2
    if extension in PREFERRED_USER_FILE_EXTENSIONS:
        return 1.0
    if extension in CODE_FILE_EXTENSIONS:
        return 0.2 if prefers_code else -0.9
    if not extension:
        return -0.2
    return 0.1


def _filename_match_score(relative_path: str, query: str, query_tokens: list[str]) -> float:
    path = Path(relative_path)
    filename = path.name.lower()
    stem = path.stem.lower()
    path_text = relative_path.lower()
    score = 0.0

    if query:
        if stem == query or filename == query:
            score += 2.8
        elif stem.startswith(query):
            score += 2.1
        elif query in stem:
            score += 1.5
        elif query in path_text:
            score += 0.8

        score += SequenceMatcher(None, query, stem).ratio() * 0.8

    stem_tokens = set(_search_tokens(stem))
    for token in query_tokens:
        if token in stem_tokens:
            score += 0.9
        elif token in stem:
            score += 0.45
        elif token in path_text:
            score += 0.2

    return score


def _cached_indexed_paths() -> list[str]:
    now = time.monotonic()
    if (
        _INDEXED_PATH_CACHE["paths"]
        and now - _INDEXED_PATH_CACHE["created_at"] <= _INDEXED_PATH_CACHE_TTL_SECONDS
    ):
        return _INDEXED_PATH_CACHE["paths"]

    indexed_paths = sorted(chroma.list_indexed_paths())
    if not indexed_paths:
        indexed_paths = filesystem.list_archive_files()

    _INDEXED_PATH_CACHE["paths"] = indexed_paths
    _INDEXED_PATH_CACHE["created_at"] = now
    return indexed_paths


def _rank_search_results(
    query_text: str,
    semantic_ids: list[str],
    semantic_distances: list,
    n_results: int,
) -> list[str]:
    normalized_query = query_text.strip().lower()
    query_tokens = _search_tokens(normalized_query)
    prefers_code = _query_prefers_code(query_tokens, normalized_query)

    candidate_distances: dict[str, float | None] = {}

    for index, relative_path in enumerate(semantic_ids):
        if not isinstance(relative_path, str) or not relative_path:
            continue

        distance = None
        if index < len(semantic_distances):
            distance = semantic_distances[index]

        existing = candidate_distances.get(relative_path)
        if existing is None:
            candidate_distances[relative_path] = distance
        elif distance is not None:
            try:
                candidate_distances[relative_path] = min(float(existing), float(distance))
            except (TypeError, ValueError):
                candidate_distances[relative_path] = distance

    for relative_path in _cached_indexed_paths():
        if not isinstance(relative_path, str) or not relative_path:
            continue
        if relative_path in candidate_distances:
            continue
        if _is_hidden_path(relative_path):
            continue

        path_text = relative_path.lower()
        if normalized_query and normalized_query in path_text:
            candidate_distances[relative_path] = None
            continue
        if query_tokens and any(token in path_text for token in query_tokens):
            candidate_distances[relative_path] = None

    ranked = []
    seen = set()
    for relative_path, distance in candidate_distances.items():
        if _is_hidden_path(relative_path):
            continue

        absolute_path = os.path.join(settings.ARCHIVE_DIR, relative_path)
        if absolute_path in seen:
            continue
        if _is_hidden_path(absolute_path):
            continue
        if not os.path.exists(absolute_path):
            continue

        extension = Path(relative_path).suffix.lower().lstrip(".")
        semantic = _semantic_score(distance)
        name_score = _filename_match_score(relative_path, normalized_query, query_tokens)
        type_score = _file_type_priority_score(extension, query_tokens, prefers_code)

        final_score = semantic * 3.2 + name_score * 1.7 + type_score
        ranked.append((final_score, semantic, name_score, type_score, absolute_path))
        seen.add(absolute_path)

    ranked.sort(
        key=lambda item: (item[0], item[1], item[2], item[3], item[4]),
        reverse=True,
    )

    return [item[4] for item in ranked[:n_results]]


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

    result_limit = min(max(n_results, 1), 50)
    semantic_fetch_size = max(result_limit * 8, 60)
    results = chroma.query_collection(query_text=query_text, n_results=semantic_fetch_size)

    semantic_ids = results.get("ids", [[]])
    semantic_distances = results.get("distances", [[]])

    semantic_paths = semantic_ids[0] if semantic_ids and semantic_ids[0] else []
    distances = (
        semantic_distances[0]
        if semantic_distances and semantic_distances[0]
        else []
    )

    full_paths = _rank_search_results(
        query_text=query_text,
        semantic_ids=semantic_paths,
        semantic_distances=distances,
        n_results=result_limit,
    )

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
    return {
        "input_dir": settings.INPUT_DIR,
        "archive_dir": settings.ARCHIVE_DIR,
        "watch_input_dir": settings.WATCH_INPUT_DIR,
    }


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
        settings.WATCH_INPUT_DIR = bool(config.watch_input_dir)

        # Also update ChromaDB directory which is based on archive directory
        settings.CHROMA_DB_DIR = os.path.join(settings.ARCHIVE_DIR, ".chromadb")
        Path(settings.CHROMA_DB_DIR).mkdir(parents=True, exist_ok=True)

        # Save settings to .env file for persistence
        update_env_values(
            {
                "ARCHIVE_DIR": str(archive_path),
                "INPUT_DIR": str(input_path),
                "WATCH_INPUT_DIR": str(settings.WATCH_INPUT_DIR).lower(),
            }
        )

        # Import the restart function here to avoid circular imports
        from main import restart_file_watcher

        # Restart the file watcher with new directory settings
        restart_file_watcher()

        return {
            "input_dir": settings.INPUT_DIR,
            "archive_dir": settings.ARCHIVE_DIR,
            "watch_input_dir": settings.WATCH_INPUT_DIR,
        }
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


@router.post("/uninstall-cleanup", response_model=UninstallCleanupResponse)
async def uninstall_cleanup(config: UninstallCleanupConfig):
    """
    Remove local Archive data to help users uninstall cleanly.
    """
    deleted_paths: list[str] = []
    warnings: list[str] = []

    if config.delete_database:
        _remove_path(Path(settings.CHROMA_DB_DIR), deleted_paths, warnings)

    if config.delete_move_logs:
        move_log_path = Path(settings.MOVE_LOG_DB_PATH)
        _remove_path(move_log_path, deleted_paths, warnings)
        _remove_path(Path(f"{settings.MOVE_LOG_DB_PATH}-shm"), deleted_paths, warnings)
        _remove_path(Path(f"{settings.MOVE_LOG_DB_PATH}-wal"), deleted_paths, warnings)

    if config.delete_credentials:
        for provider in ("openai", "anthropic", "openai_compatible"):
            try:
                _set_provider_api_key(provider, "")
            except Exception as exc:
                warnings.append(f"Failed to remove {provider} API key: {exc}")

        settings.LLM_API_KEY = ""

        try:
            update_env_values(
                {
                    **credentials.provider_api_env_values(settings),
                }
            )
        except Exception as exc:
            warnings.append(f"Failed to clear persisted API key fields: {exc}")

        credentials_key_path = Path.home() / ".archive_plugin" / "master.key"
        _remove_path(credentials_key_path, deleted_paths, warnings)

        credentials_dir = credentials_key_path.parent
        try:
            credentials_dir.rmdir()
            deleted_paths.append(str(credentials_dir))
        except OSError:
            pass

    if config.delete_backend_support:
        env_path = Path(getattr(settings, "ENV_PATH", ""))
        support_dir = env_path.parent
        # Safety guard so we never recursively remove arbitrary directories.
        safe_to_remove = (
            support_dir.name == "backend"
            and "ArchivePlugin" in support_dir.parts
        )
        if safe_to_remove:
            _remove_path(support_dir, deleted_paths, warnings)
        else:
            warnings.append(
                f"Skipped backend support cleanup for safety: {support_dir}"
            )

    return {
        "success": len(warnings) == 0,
        "deleted_paths": deleted_paths,
        "warnings": warnings,
    }


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
