import os
import shutil
import logging
from config import settings


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

    def build_structure(path, parent_path=""):
        rel_path = os.path.relpath(path, settings.ARCHIVE_DIR)
        structure_path = parent_path + "/" + rel_path if parent_path else rel_path

        if structure_path == ".":
            structure_path = ""

        structure = {"type": "dir", "path": structure_path, "children": {}}

        try:
            for item in os.listdir(path):
                item_path = os.path.join(path, item)

                if os.path.isdir(item_path):
                    structure["children"][item] = build_structure(
                        item_path, parent_path=structure_path
                    )
                else:
                    rel_file_path = os.path.relpath(item_path, settings.ARCHIVE_DIR)
                    structure["children"][item] = {
                        "type": "file",
                        "path": rel_file_path,
                    }

            return structure
        except Exception as e:
            logging.error(f"Error building directory structure for {path}: {e}")
            return structure

    return build_structure(settings.ARCHIVE_DIR)


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
