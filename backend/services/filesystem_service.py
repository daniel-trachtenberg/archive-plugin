import os
import shutil
import logging
from config import settings

_SKIP_DIRECTORY_NAMES = {".chromadb"}


def _is_hidden(name: str) -> bool:
    return bool(name) and name.startswith(".")


def _safe_relative_path(path: str) -> str:
    rel_path = os.path.relpath(path, settings.ARCHIVE_DIR)
    return "" if rel_path == "." else rel_path


def save_file(file_content, file_path):
    """
    Saves a file to the specified path within the archive.
    """
    try:
        full_path = os.path.join(settings.ARCHIVE_DIR, file_path)
        # Ensure the directory exists
        os.makedirs(os.path.dirname(full_path), exist_ok=True)

        # Write the file
        with open(full_path, "wb") as f:
            f.write(file_content)

        return True
    except Exception as e:
        logging.error(f"Error saving file to filesystem: {e}")
        return False


def get_file_path(file_path):
    """
    Returns the full path to a file in the archive.
    """
    return os.path.join(settings.ARCHIVE_DIR, file_path)


def get_directory_structure():
    """
    Builds and returns a nested directory structure for the archive directory.
    """

    def build_structure(path):
        structure = {"type": "dir", "path": _safe_relative_path(path), "children": {}}

        try:
            for item in sorted(os.listdir(path)):
                if _is_hidden(item) or item in _SKIP_DIRECTORY_NAMES:
                    continue

                item_path = os.path.join(path, item)

                if os.path.isdir(item_path):
                    structure["children"][item] = build_structure(item_path)
                else:
                    rel_file_path = _safe_relative_path(item_path)
                    structure["children"][item] = {
                        "type": "file",
                        "path": rel_file_path,
                    }

            return structure
        except Exception as e:
            logging.error(f"Error building directory structure for {path}: {e}")
            return structure

    return build_structure(settings.ARCHIVE_DIR)


def list_archive_files():
    """
    Return all non-hidden files in the Archive directory.
    """
    files = []

    try:
        for root, dirs, filenames in os.walk(settings.ARCHIVE_DIR):
            # Prevent recursing into hidden/system folders.
            dirs[:] = [
                d
                for d in dirs
                if not _is_hidden(d) and d not in _SKIP_DIRECTORY_NAMES
            ]

            for filename in filenames:
                if _is_hidden(filename):
                    continue

                full_path = os.path.join(root, filename)
                files.append(_safe_relative_path(full_path))
    except Exception as e:
        logging.error(f"Error listing archive files: {e}")
        return []

    return sorted(files)


def directory_tree_for_llm(max_entries: int = 1500):
    """
    Render a compact tree string for the LLM.
    Includes all visible archive files, not only indexed files.
    """
    try:
        root = get_directory_structure()
    except Exception as e:
        logging.error(f"Error building directory tree for llm: {e}")
        return "(failed to build directory tree)"

    lines = []

    def walk(node, prefix=""):
        children = node.get("children", {})
        sorted_children = sorted(
            children.items(),
            key=lambda item: (item[1].get("type") != "dir", item[0].lower()),
        )

        for index, (name, child) in enumerate(sorted_children):
            last = index == len(sorted_children) - 1
            connector = "`-- " if last else "|-- "
            is_dir = child.get("type") == "dir"
            lines.append(f"{prefix}{connector}{name}{'/' if is_dir else ''}")

            if is_dir:
                extension = "    " if last else "|   "
                walk(child, prefix + extension)

    walk(root)

    if not lines:
        return "(archive is empty)"

    if max_entries > 0 and len(lines) > max_entries:
        hidden_count = len(lines) - max_entries
        lines = lines[:max_entries] + [f"... ({hidden_count} additional entries)"]

    return "\n".join(lines)


def fetch_content(path):
    """
    Fetches file content from the filesystem.
    """
    try:
        # Skip ChromaDB internal files
        if ".chromadb" in path.split(os.sep):
            logging.debug(f"Skipping ChromaDB internal file: {path}")
            return None

        # Skip hidden files
        if os.path.basename(path).startswith("."):
            logging.debug(f"Skipping hidden file: {path}")
            return None

        full_path = os.path.join(settings.ARCHIVE_DIR, path)

        # Check if file exists before trying to open it
        if not os.path.exists(full_path):
            logging.warning(f"File does not exist: {full_path}")
            return None

        # Check file size to avoid loading very large files
        file_size = os.path.getsize(full_path)
        max_size = 100 * 1024 * 1024  # 100MB max size
        if file_size > max_size:
            logging.warning(
                f"File too large to load: {path} ({file_size/1024/1024:.2f} MB)"
            )
            return None

        with open(full_path, "rb") as f:
            return f.read()
    except Exception as e:
        logging.error(f"Error fetching content from filesystem for {path}: {e}")
        return None
