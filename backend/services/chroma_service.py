import chromadb
from chromadb.utils.embedding_functions import OpenCLIPEmbeddingFunction
from chromadb.utils.data_loaders import ImageLoader
from PIL import Image
import numpy as np
import io
from config import settings
import logging

# Initialize Chroma Client with local persistence
chroma_client = chromadb.PersistentClient(
    path=settings.CHROMA_DB_DIR,
)

# For image handling
embedding_function = OpenCLIPEmbeddingFunction()
data_loader = ImageLoader()


def ensure_collection_exists(collection_name: str = "archive"):
    """
    Ensure a multi-modal collection exists.
    """
    try:
        collection = chroma_client.get_or_create_collection(
            collection_name,
            embedding_function=embedding_function,
            data_loader=data_loader,
        )
        return collection
    except Exception as e:
        logging.error(f"Error creating/getting collection: {e}")
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
            collection.add(ids=[path], documents=[content])
            return True
        return False
    except Exception as e:
        logging.error(f"Error adding document to collection: {e}")
        return False


def add_image_to_collection(path: str, image: bytes, collection_name: str = "archive"):
    """
    Add an image to the Chroma collection.
    """
    try:
        collection = ensure_collection_exists(collection_name)
        if collection:
            open_image = Image.open(io.BytesIO(image))
            image_array = np.array(open_image)
            collection.add(ids=[path], images=[image_array])
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
                results = collection.query(
                    query_images=[query_image], n_results=n_results
                )
                return results
        return {"ids": [[]], "distances": [[]]}
    except Exception as e:
        logging.error(f"Error querying collection: {e}")
        return {"ids": [[]], "distances": [[]]}


def delete_item(path: str, collection_name: str = "archive"):
    """
    Delete an item from the collection.
    """
    try:
        collection = chroma_client.get_collection(collection_name)
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
            collection.delete(ids=[old_path])

            if is_image:
                open_image = Image.open(io.BytesIO(content))
                image_array = np.array(open_image)
                collection.add(ids=[new_path], images=[image_array])
            else:
                collection.add(ids=[new_path], documents=[content])
            return True
        return False
    except Exception as e:
        logging.error(f"Error renaming item in collection: {e}")
        return False
