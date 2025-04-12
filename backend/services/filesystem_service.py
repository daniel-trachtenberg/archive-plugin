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
        full_path = os.path.join(settings.ARCHIVE_DIR, path)
        with open(full_path, "rb") as f:
            return f.read()
    except Exception as e:
        logging.error(f"Error fetching content from filesystem for {path}: {e}")
        return None
