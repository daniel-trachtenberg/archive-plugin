import logging
import os
import shutil
from datetime import datetime
import threading
import numpy as np
from config import settings

CHROMA_IMPORT_ERROR = None

try:
    import chromadb
except Exception as import_error:
    chromadb = None
    CHROMA_IMPORT_ERROR = import_error
    logging.error(
        "Failed to import chromadb. Ensure compatible versions are installed. Error: %s",
        import_error,
    )


def _create_client():
    if chromadb is None:
        return None
    return chromadb.PersistentClient(path=settings.CHROMA_DB_DIR)


# Initialize Chroma Client with local persistence
chroma_client = _create_client()

recovery_lock = threading.Lock()


def _is_schema_mismatch_error(error: Exception) -> bool:
    message = str(error).lower()
    # Common failure after upgrading Chroma against an old SQLite schema.
    return (
        "no such column: collections.topic" in message
        or ("no such column" in message and "collections" in message)
    )


def _recover_chroma_storage(error: Exception) -> bool:
    """
    Backup incompatible local Chroma DB and create a fresh one.
    Returns True if recovery succeeded.
    """
    if not _is_schema_mismatch_error(error):
        return False

    with recovery_lock:
        db_dir = settings.CHROMA_DB_DIR
        backup_dir = f"{db_dir}_backup_{datetime.now().strftime('%Y%m%d_%H%M%S')}"

        try:
            if os.path.exists(db_dir):
                shutil.move(db_dir, backup_dir)
                logging.warning(
                    "Chroma schema mismatch detected. Backed up old DB to: %s",
                    backup_dir,
                )
            os.makedirs(db_dir, exist_ok=True)

            global chroma_client
            chroma_client = _create_client()
            logging.warning("Created fresh Chroma DB at: %s", db_dir)
            return True
        except Exception as recovery_error:
            logging.error("Failed to recover Chroma storage: %s", recovery_error)
            return False


def ensure_collection_exists(collection_name: str = "archive"):
    """
    Ensure the archive collection exists.
    """
    if chromadb is None:
        logging.error("ChromaDB unavailable due to import error: %s", CHROMA_IMPORT_ERROR)
        return None

    if chroma_client is None:
        logging.error("ChromaDB client was not initialized")
        return None

    for attempt in range(2):
        try:
            collection = chroma_client.get_or_create_collection(collection_name)
            return collection
        except Exception as e:
            logging.error(f"Error creating/getting collection: {e}")
            if attempt == 0 and _recover_chroma_storage(e):
                continue
            return None


def add_document_to_collection(
    path: str, content: str, collection_name: str = "archive"
):
    """
    Add a document to the Chroma collection.
    """
    try:
        collection = ensure_collection_exists(collection_name)
        if collection:
            # Don't print the content - it could be binary data
            logging.debug(f"Adding document to collection: {path}")
            collection.upsert(ids=[path], documents=[content])
            logging.debug(f"Successfully added document: {path}")
            return True
        return False
    except Exception as e:
        logging.error(f"Error adding document to collection: {e}")
        return False


def add_image_to_collection(
    path: str,
    image: bytes,
    collection_name: str = "archive",
    summary: str = "",
):
    """
    Add an image to the Chroma collection.
    """
    try:
        collection = ensure_collection_exists(collection_name)
        if collection:
            # Store image entries as text summaries for reliable semantic retrieval.
            logging.debug(f"Adding image to collection: {path}")
            text_summary = (
                summary.strip()
                if summary and summary.strip()
                else f"Image file at path: {path}"
            )
            collection.upsert(ids=[path], documents=[text_summary])
            logging.debug(f"Successfully added image: {path}")
            return True
        return False
    except Exception as e:
        logging.error(f"Error adding image to collection: {e}")
        return False


def query_collection(
    query_text: str = None,
    query_image: np.ndarray = None,
    n_results: int = 5,
    collection_name: str = "archive",
):
    """
    Query the collection for documents matching the query_text or an image.
    """
    try:
        collection = ensure_collection_exists(collection_name)
        if collection:
            if query_text:
                results = collection.query(
                    query_texts=[query_text], n_results=n_results
                )
                return results
            elif query_image is not None:
                # Image queries are not supported in the stable text-only collection path.
                return {"ids": [[]], "distances": [[]]}
        return {"ids": [[]], "distances": [[]]}
    except Exception as e:
        logging.error(f"Error querying collection: {e}")
        return {"ids": [[]], "distances": [[]]}


def delete_item(path: str, collection_name: str = "archive"):
    """
    Delete an item from the collection.
    """
    try:
        collection = ensure_collection_exists(collection_name)
        if not collection:
            return False
        collection.delete(ids=[path])
        return True
    except Exception as e:
        logging.error(f"Error deleting item from collection: {e}")
        return False


def rename(
    old_path: str,
    new_path: str,
    content,
    is_image=False,
    collection_name: str = "archive",
):
    """
    Rename an item in the Chroma collection by deleting the old entry and adding a new one with the updated path.
    """
    try:
        collection = ensure_collection_exists(collection_name)
        if collection:
            logging.debug(f"Renaming item in collection: {old_path} -> {new_path}")
            collection.delete(ids=[old_path])
            logging.debug(f"Deleted old path: {old_path}")

            if is_image:
                image_summary = f"Image file at path: {new_path}"
                collection.upsert(ids=[new_path], documents=[image_summary])
                logging.debug(f"Added image with new path: {new_path}")
            else:
                # Don't print the content - it could be binary data
                collection.upsert(ids=[new_path], documents=[content])
                logging.debug(f"Added document with new path: {new_path}")
            return True
        return False
    except Exception as e:
        logging.error(f"Error renaming item in collection: {e}")
        return False


def list_indexed_paths(collection_name: str = "archive"):
    """
    Return all indexed file paths currently stored in Chroma.
    """
    try:
        collection = ensure_collection_exists(collection_name)
        if not collection:
            return set()

        payload = None
        try:
            payload = collection.get(include=[])
        except Exception:
            payload = collection.get()

        ids = payload.get("ids", []) if isinstance(payload, dict) else []
        return {item for item in ids if isinstance(item, str) and item}
    except Exception as e:
        logging.error(f"Error listing indexed paths from collection: {e}")
        return set()
