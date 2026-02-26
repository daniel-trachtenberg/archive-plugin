import base64
import json
import logging
import os
import re
from typing import Optional

import requests

from config import settings
from services import image_analysis_service
from services import credentials_service

_PATH_TAG_PATTERN = re.compile(r"<suggestedpath>(.*?)</suggestedpath>", re.IGNORECASE | re.DOTALL)
_SUMMARY_TAG_PATTERN = re.compile(r"<summary>(.*?)</summary>", re.IGNORECASE | re.DOTALL)
_JSON_BLOCK_PATTERN = re.compile(r"\{[\s\S]*\}")

_TEXT_EXTENSIONS = {
    ".txt",
    ".md",
    ".rtf",
    ".pdf",
    ".doc",
    ".docx",
    ".ppt",
    ".pptx",
    ".xls",
    ".xlsx",
    ".csv",
}

_IMAGE_EXTENSIONS = {
    ".jpg",
    ".jpeg",
    ".png",
    ".gif",
    ".bmp",
    ".webp",
    ".heic",
    ".heif",
    ".tiff",
}

_AUDIO_EXTENSIONS = {".mp3", ".wav", ".m4a", ".flac", ".aac", ".ogg"}
_VIDEO_EXTENSIONS = {".mp4", ".mov", ".mkv", ".avi", ".webm", ".wmv", ".flv"}
_ARCHIVE_EXTENSIONS = {".zip", ".tar", ".gz", ".7z", ".rar"}
_CODE_EXTENSIONS = {
    ".py",
    ".js",
    ".ts",
    ".tsx",
    ".jsx",
    ".go",
    ".rs",
    ".java",
    ".c",
    ".cpp",
    ".h",
    ".swift",
    ".kt",
    ".rb",
    ".php",
    ".css",
    ".html",
    ".json",
    ".yaml",
    ".yml",
    ".toml",
    ".sql",
}

_KEYWORD_CATEGORIES = {
    "finance": ["invoice", "receipt", "tax", "w2", "1099", "bank", "payment", "budget"],
    "legal": ["contract", "agreement", "nda", "policy", "terms", "compliance", "legal"],
    "work": ["meeting", "project", "roadmap", "proposal", "strategy", "report", "brief"],
    "education": ["course", "class", "lecture", "assignment", "syllabus", "homework", "research"],
    "health": ["medical", "health", "lab", "prescription", "insurance", "doctor"],
    "travel": ["flight", "hotel", "itinerary", "trip", "passport", "boarding"],
    "personal": ["resume", "cv", "cover letter", "family", "personal", "photo", "journal"],
}

_GENERIC_ROOT_SEGMENTS = {
    "documents",
    "document",
    "files",
    "file",
    "misc",
    "miscellaneous",
    "other",
    "general",
    "unsorted",
}

_DOMAIN_ALIASES = {
    "finance": {"finance", "financial", "money", "billing", "tax"},
    "legal": {"legal", "contracts", "compliance", "law"},
    "work": {"work", "business", "project", "projects", "client"},
    "education": {"education", "school", "course", "class", "university", "study"},
    "health": {"health", "medical", "care", "insurance"},
    "travel": {"travel", "trip", "flights", "hotel", "itinerary"},
    "personal": {"personal", "home", "family"},
}

_TOKEN_STOPWORDS = {
    "the",
    "and",
    "for",
    "with",
    "from",
    "that",
    "this",
    "into",
    "about",
    "file",
    "files",
    "document",
    "documents",
    "image",
    "images",
    "folder",
    "folders",
    "archive",
}

_TREE_LINE_PATTERN = re.compile(
    r"^(?P<prefix>(?:\|   |    )*)(?:\|-- |`-- )(?P<name>.+)$"
)


class LLMService:
    SYSTEM_PROMPT = """
You organize local files into clean folders for semantic retrieval.

Rules:
- Return only a folder path, never a filename.
- Keep paths shallow (1 to 3 levels).
- Use concise folder names in TitleCase.
- Prefer an existing path when appropriate, but create a clear new path if needed.
""".strip()

    @staticmethod
    async def get_suggestion_from_ollama(name: str, content: str, directory_structure: str) -> str:
        """Compatibility wrapper used by legacy callers."""
        summary = await get_file_summary(name, content)
        return await get_path_from_summary(name, summary, directory_structure)

    @staticmethod
    async def get_suggestion_for_image_from_ollama(
        name: str,
        directory_structure: str,
        image_content: bytes = None,
    ) -> str:
        """Compatibility wrapper used by legacy callers."""
        encoded = base64.b64encode(image_content).decode("utf-8") if image_content else ""
        summary = await get_image_summary(name, encoded, _guess_media_type(name))
        return await get_path_from_summary(name, summary, directory_structure)


def _call_ollama(prompt: str, *, timeout: int = 45, num_predict: int = 160) -> str:
    """Best-effort Ollama call; always returns a string."""
    try:
        response = requests.post(
            f"{settings.OLLAMA_BASE_URL}/api/generate",
            json={
                "model": settings.OLLAMA_MODEL,
                "prompt": prompt,
                "stream": False,
                "options": {
                    "temperature": 0,
                    "num_predict": num_predict,
                },
            },
            timeout=timeout,
        )
    except Exception as exc:
        logging.error("Failed calling Ollama: %s", exc)
        return ""

    if response.status_code != 200:
        logging.error("Ollama returned status %s: %s", response.status_code, response.text)
        return ""

    try:
        payload = response.json()
    except Exception as exc:
        logging.error("Invalid JSON from Ollama: %s", exc)
        return ""

    return (payload.get("response") or "").strip()


def _call_openai_compatible(
    prompt: str,
    *,
    timeout: int = 45,
    num_predict: int = 400,
    base_url: str = "https://api.openai.com/v1",
    api_key: str = "",
) -> str:
    url = base_url.rstrip("/") + "/chat/completions"
    model = settings.LLM_MODEL or "gpt-5.2"
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    try:
        response = requests.post(
            url,
            headers=headers,
            json={
                "model": model,
                "messages": [{"role": "user", "content": prompt}],
                "temperature": 0,
                "max_tokens": num_predict,
            },
            timeout=timeout,
        )
    except Exception as exc:
        logging.error("Failed calling OpenAI-compatible provider: %s", exc)
        return ""

    if response.status_code != 200:
        logging.error(
            "OpenAI-compatible provider returned status %s: %s",
            response.status_code,
            response.text,
        )
        return ""

    try:
        payload = response.json()
        return (
            payload.get("choices", [{}])[0]
            .get("message", {})
            .get("content", "")
            .strip()
        )
    except Exception as exc:
        logging.error("Invalid JSON from OpenAI-compatible provider: %s", exc)
        return ""


def _call_anthropic(prompt: str, *, timeout: int = 45, num_predict: int = 400) -> str:
    api_key = credentials_service.get_provider_api_key("anthropic", settings)
    if not api_key:
        logging.error("Missing ANTHROPIC_API_KEY for Anthropic provider")
        return ""

    model = settings.LLM_MODEL or "claude-sonnet-4-6"
    base_url = settings.LLM_BASE_URL or "https://api.anthropic.com"
    url = base_url.rstrip("/") + "/v1/messages"

    try:
        response = requests.post(
            url,
            headers={
                "x-api-key": api_key,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            },
            json={
                "model": model,
                "max_tokens": num_predict,
                "temperature": 0,
                "messages": [{"role": "user", "content": prompt}],
            },
            timeout=timeout,
        )
    except Exception as exc:
        logging.error("Failed calling Anthropic provider: %s", exc)
        return ""

    if response.status_code != 200:
        logging.error("Anthropic returned status %s: %s", response.status_code, response.text)
        return ""

    try:
        payload = response.json()
        content = payload.get("content", [])
        if isinstance(content, list) and content:
            return content[0].get("text", "").strip()
        return ""
    except Exception as exc:
        logging.error("Invalid JSON from Anthropic provider: %s", exc)
        return ""


def _call_model(prompt: str, *, timeout: int = 45, num_predict: int = 160) -> str:
    provider = (settings.LLM_PROVIDER or "openai").lower()
    if provider == "ollama":
        settings.LLM_API_KEY = ""
        return _call_ollama(prompt, timeout=timeout, num_predict=num_predict)
    if provider == "openai":
        base = settings.LLM_BASE_URL or "https://api.openai.com/v1"
        api_key = credentials_service.get_provider_api_key("openai", settings)
        if not api_key:
            logging.error("Missing OPENAI_API_KEY for OpenAI provider")
            return ""
        settings.LLM_API_KEY = api_key
        return _call_openai_compatible(
            prompt,
            timeout=timeout,
            num_predict=num_predict,
            base_url=base,
            api_key=api_key,
        )
    if provider == "openai_compatible":
        base = settings.LLM_BASE_URL or "http://localhost:1234/v1"
        api_key = credentials_service.get_provider_api_key("openai_compatible", settings)
        settings.LLM_API_KEY = api_key
        return _call_openai_compatible(
            prompt,
            timeout=timeout,
            num_predict=num_predict,
            base_url=base,
            api_key=api_key,
        )
    if provider == "anthropic":
        settings.LLM_API_KEY = credentials_service.get_provider_api_key("anthropic", settings)
        if not settings.LLM_API_KEY:
            logging.error("Missing ANTHROPIC_API_KEY for Anthropic provider")
            return ""
        return _call_anthropic(prompt, timeout=timeout, num_predict=num_predict)

    logging.error("Unsupported LLM provider '%s', falling back to ollama", provider)
    return _call_ollama(prompt, timeout=timeout, num_predict=num_predict)


def _clean_model_output(text: str) -> str:
    if not text:
        return ""
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = re.sub(r"^```(?:json)?", "", stripped).strip()
        stripped = re.sub(r"```$", "", stripped).strip()
    return stripped


def _extract_summary(text: str) -> str:
    if not text:
        return ""
    match = _SUMMARY_TAG_PATTERN.search(text)
    if match:
        return match.group(1).strip()
    return text.strip()


def _extract_path_from_response(text: str) -> str:
    """Accepts JSON, XML tags, or plain path-like output."""
    cleaned = _clean_model_output(text)
    if not cleaned:
        return ""

    # 1) <suggestedpath> tag
    tag_match = _PATH_TAG_PATTERN.search(cleaned)
    if tag_match:
        return tag_match.group(1).strip()

    # 2) JSON: {"path": "..."}
    json_match = _JSON_BLOCK_PATTERN.search(cleaned)
    if json_match:
        try:
            decoded = json.loads(json_match.group(0))
            candidate = decoded.get("path") or decoded.get("suggested_path") or ""
            if isinstance(candidate, str):
                return candidate.strip()
        except Exception:
            pass

    # 3) First path-like line
    for line in cleaned.splitlines():
        candidate = line.strip().strip('"\'`')
        if not candidate:
            continue
        if "/" in candidate and len(candidate.split()) <= 5:
            return candidate

    # 4) Single token fallback
    if len(cleaned.split()) <= 4:
        return cleaned

    return ""


def _sanitize_segment(segment: str) -> str:
    segment = re.sub(r"[^A-Za-z0-9 _-]", "", segment or "").strip()
    segment = re.sub(r"\s+", " ", segment)
    if not segment:
        return ""
    words = [w.capitalize() for w in segment.replace("_", " ").split(" ") if w]
    return "".join(words[:4])


def _normalize_path(path: str) -> str:
    path = (path or "").replace("\\", "/").strip().strip("/")
    if not path:
        return ""

    raw_parts = [p for p in path.split("/") if p and p not in {".", ".."}]
    cleaned_parts = []
    for part in raw_parts[:3]:
        clean_part = _sanitize_segment(part)
        if clean_part:
            cleaned_parts.append(clean_part)

    return "/".join(cleaned_parts)


def _is_generic_root(path: str) -> bool:
    normalized = _normalize_path(path)
    if not normalized:
        return True
    first_segment = normalized.split("/", 1)[0].lower()
    return first_segment in _GENERIC_ROOT_SEGMENTS


def _strip_generic_root(path: str) -> str:
    normalized = _normalize_path(path)
    if not normalized:
        return ""

    parts = normalized.split("/")
    if len(parts) >= 2 and parts[0].lower() in _GENERIC_ROOT_SEGMENTS:
        return "/".join(parts[1:])
    return normalized


def _tokenize_for_matching(text: str) -> set[str]:
    if not text:
        return set()
    spaced = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", text)
    tokens = re.findall(r"[a-z0-9]+", spaced.lower())
    return {
        token
        for token in tokens
        if len(token) >= 3 and token not in _TOKEN_STOPWORDS and not token.isdigit()
    }


def _parse_directory_context_payload(directory_structure: str) -> dict:
    context_text = str(directory_structure or "").strip()
    if not context_text:
        return {}

    try:
        decoded = json.loads(context_text)
        if isinstance(decoded, dict):
            return decoded
    except Exception:
        pass

    # Fallback for contexts wrapped in additional text.
    json_match = _JSON_BLOCK_PATTERN.search(context_text)
    if json_match:
        try:
            decoded = json.loads(json_match.group(0))
            if isinstance(decoded, dict):
                return decoded
        except Exception:
            pass

    return {}


def _add_directory_prefixes(path: str, accumulator: set[str]) -> None:
    normalized = _normalize_path(path)
    if not normalized:
        return

    parts = normalized.split("/")
    for idx in range(1, min(len(parts), 3) + 1):
        candidate = "/".join(parts[:idx])
        if candidate:
            accumulator.add(candidate)


def _extract_existing_directories(directory_structure: str) -> list[str]:
    payload = _parse_directory_context_payload(directory_structure)
    if not payload:
        return []

    directories: set[str] = set()

    for key in ("archive_files", "unindexed_archive_files", "indexed_files"):
        entries = payload.get(key, [])
        if not isinstance(entries, list):
            continue

        for entry in entries:
            if not isinstance(entry, str):
                continue
            candidate = entry.replace("\\", "/").strip().strip("/")
            if not candidate or candidate.startswith("... ("):
                continue

            parent = os.path.dirname(candidate).replace("\\", "/").strip("/")
            if parent:
                _add_directory_prefixes(parent, directories)

    tree = payload.get("archive_tree")
    if isinstance(tree, str) and tree:
        stack: list[str] = []
        for line in tree.splitlines():
            match = _TREE_LINE_PATTERN.match(line.rstrip())
            if not match:
                continue

            raw_name = match.group("name").strip()
            if not raw_name.endswith("/"):
                continue

            depth = len(match.group("prefix")) // 4
            folder_name = raw_name[:-1].strip()
            if not folder_name:
                continue

            stack = stack[:depth]
            stack.append(folder_name)
            _add_directory_prefixes("/".join(stack), directories)

    return sorted(directories)


def _score_directory_candidate(
    candidate: str,
    summary_tokens: set[str],
    filename_tokens: set[str],
) -> float:
    candidate_tokens = _tokenize_for_matching(candidate.replace("/", " "))
    if not candidate_tokens:
        return -1.0

    summary_overlap = len(candidate_tokens & summary_tokens)
    filename_overlap = len(candidate_tokens & filename_tokens)

    score = (summary_overlap * 2.0) + (filename_overlap * 3.0)
    if not _is_generic_root(candidate):
        score += 0.6

    generic_segments = sum(
        1 for segment in candidate.split("/") if segment.lower() in _GENERIC_ROOT_SEGMENTS
    )
    score -= float(generic_segments)
    score += min(len(candidate.split("/")), 3) * 0.1

    return score


def _best_existing_path_from_context(
    filename: str,
    summary: str,
    directory_structure: str,
) -> str:
    existing_dirs = _extract_existing_directories(directory_structure)
    if not existing_dirs:
        return ""

    filename_base = os.path.splitext(os.path.basename(filename or ""))[0]
    summary_tokens = _tokenize_for_matching(summary)
    filename_tokens = _tokenize_for_matching(filename_base)

    domain = (_domain_from_text(summary) or "").lower()
    if domain:
        summary_tokens.add(domain)
        summary_tokens |= _DOMAIN_ALIASES.get(domain, set())

    if not summary_tokens and not filename_tokens:
        return ""

    scored = [
        (
            _score_directory_candidate(candidate, summary_tokens, filename_tokens),
            candidate,
        )
        for candidate in existing_dirs
    ]
    scored.sort(key=lambda item: item[0], reverse=True)
    best_score, best_candidate = scored[0]

    if best_score < 1.5:
        return ""
    return best_candidate


def _guess_media_type(filename: str) -> str:
    ext = os.path.splitext(filename.lower())[1]
    return {
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".png": "image/png",
        ".gif": "image/gif",
        ".webp": "image/webp",
        ".heic": "image/heic",
    }.get(ext, "application/octet-stream")


def _domain_from_text(summary: str) -> Optional[str]:
    lowered = (summary or "").lower()
    for domain, keywords in _KEYWORD_CATEGORIES.items():
        if any(keyword in lowered for keyword in keywords):
            return domain.capitalize()
    return None


def _fallback_path(filename: str, summary: str = "", directory_structure: str = "") -> str:
    ext = os.path.splitext(filename.lower())[1]
    domain = _domain_from_text(summary)
    existing_context_path = _best_existing_path_from_context(
        filename=filename,
        summary=summary,
        directory_structure=directory_structure,
    )
    if existing_context_path:
        return existing_context_path

    if domain:
        normalized_domain = _normalize_path(domain)
        if normalized_domain:
            return normalized_domain

    if ext in _IMAGE_EXTENSIONS:
        return "Images"
    if ext in _AUDIO_EXTENSIONS:
        return "Audio"
    if ext in _VIDEO_EXTENSIONS:
        return "Video"
    if ext in _ARCHIVE_EXTENSIONS:
        return "Archives"
    if ext in _CODE_EXTENSIONS:
        return "Code"
    if ext in _TEXT_EXTENSIONS:
        return "Inbox"
    return "Inbox"


def _safe_summary_fallback(filename: str, content: str) -> str:
    if content:
        trimmed = re.sub(r"\s+", " ", content).strip()
        if trimmed:
            return trimmed[:400]
    return f"File named {filename}"


async def get_file_summary(filename: str, content: str) -> str:
    """Generate a compact semantic summary for a document."""
    sampled_content = (content or "")[:6000]

    prompt = f"""
Summarize this file in 2-3 concise sentences for downstream folder classification and semantic search.
Return XML only in this format:
<summary>...</summary>

<file-name>{filename}</file-name>
<content>{sampled_content}</content>
""".strip()

    raw = _call_model(prompt, timeout=45, num_predict=180)
    summary = _extract_summary(raw)
    if summary:
        return summary

    return _safe_summary_fallback(filename, sampled_content)


async def get_image_summary(filename: str, encoded_image: str, media_type: str) -> str:
    """Generate text summary for image embeddings/classification."""
    analysis = None
    if encoded_image:
        try:
            binary = base64.b64decode(encoded_image)
            analysis = image_analysis_service.analyze_image(binary)
        except Exception as exc:
            logging.error("Failed to decode/analyze image '%s': %s", filename, exc)

    description = ""
    if analysis:
        description = analysis.get("description") or ""
        categories = analysis.get("categories") or []
        if categories:
            description = f"{description} Categories: {', '.join(categories[:4])}."

    if not description:
        basename = os.path.splitext(os.path.basename(filename))[0]
        description = f"Image file named {basename.replace('_', ' ').replace('-', ' ')}"

    prompt = f"""
Create a 2 sentence semantic summary of this image description for search indexing.
Return XML only:
<summary>...</summary>

<file-name>{filename}</file-name>
<image-analysis>{description}</image-analysis>
""".strip()

    raw = _call_model(prompt, timeout=35, num_predict=140)
    summary = _extract_summary(raw)
    return summary or description


async def get_path_from_summary(filename: str, summary: str, directory_structure: str) -> str:
    """Return a normalized folder path from file summary."""
    structure_text = str(directory_structure or "")
    structure_preview = structure_text[:16000]

    prompt = f"""
{LLMService.SYSTEM_PROMPT}

Pick the best folder path for this file.
Return JSON only: {{"path": "Top/Sub"}}

Constraints:
- No filename in the path.
- Max depth: 3 segments.
- Prefer existing folder patterns from the provided context.
- Prefer topical folders over file-type buckets (for example, `Taxes/2025` not `Documents/Taxes`).
- Avoid starting paths with generic roots like `Documents` or `Files` unless there is no clearer topic.
- The context includes filesystem tree + index status. Files in `unindexed_archive_files`
  are on disk but not yet embedded; files in `db_only_index_records` are stale DB records.

<file-name>{filename}</file-name>
<summary>{summary}</summary>
<placement-context-json>{structure_preview}</placement-context-json>
""".strip()

    raw = _call_model(prompt, timeout=45, num_predict=80)
    extracted = _extract_path_from_response(raw)
    normalized = _normalize_path(extracted)
    normalized = _strip_generic_root(normalized)

    existing_context_path = _best_existing_path_from_context(
        filename=filename,
        summary=summary,
        directory_structure=directory_structure,
    )

    if normalized and not _is_generic_root(normalized):
        return normalized

    if existing_context_path:
        return existing_context_path

    if normalized:
        return normalized

    return _fallback_path(filename, summary, directory_structure)


async def get_path_suggestion(filename: str, content: str, directory_structure: str) -> str:
    """Legacy API wrapper for document path suggestions."""
    summary = await get_file_summary(filename, content)
    return await get_path_from_summary(filename, summary, directory_structure)


async def get_path_suggestion_for_image(
    filename: str,
    encoded_image: str,
    directory_structure: str,
    media_type: str,
) -> str:
    """Legacy API wrapper for image path suggestions."""
    summary = await get_image_summary(filename, encoded_image, media_type)
    return await get_path_from_summary(filename, summary, directory_structure)


async def get_path_suggestion_for_folder(
    folder_name: str,
    folder_content: str,
    directory_structure: str,
) -> str:
    """Legacy API wrapper for folder placement suggestions."""
    folder_summary = await get_file_summary(folder_name, folder_content)
    path = await get_path_from_summary(folder_name, folder_summary, directory_structure)
    return path or "Folders"
