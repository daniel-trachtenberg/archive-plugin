import services.filesystem_service as filesystem
import services.llm_service as llm
import services.chroma_service as chroma
from fastapi import HTTPException
from PyPDF2 import PdfReader
import base64
import io
import os
import logging


def extract_text_from_pdf(file_content):
    try:
        reader = PdfReader(io.BytesIO(file_content))
        full_text = []
        for page in reader.pages:
            page_text = page.extract_text()
            if page_text:
                full_text.append(page_text.replace("\n", " "))
        return " ".join(full_text)
    except Exception as e:
        logging.error(f"Failed to extract text from PDF: {str(e)}")
        return ""


async def process_document(
    filename: str,
    content: bytes,
):
    try:
        logging.info(f"Processing document: {filename}")

        directory_structure = filesystem.get_directory_structure()

        if filename.lower().endswith(".pdf"):
            file_content = extract_text_from_pdf(content)
        else:
            file_content = content.decode("utf-8")

        suggested_path = await llm.get_path_suggestion(
            filename=filename,
            content=file_content,
            directory_structure=directory_structure,
        )

        file_extension = os.path.splitext(filename)[1]
        if not suggested_path.endswith(file_extension):
            suggested_path = os.path.join(suggested_path, filename)

        # Clean up path parts
        path_parts = suggested_path.split("/")
        corrected_path_parts = [
            path_parts[i]
            for i in range(len(path_parts))
            if i == 0 or path_parts[i] != path_parts[i - 1]
        ]

        logging.info(f"Suggested path: {suggested_path}")

        final_path = "/".join(corrected_path_parts)
        final_path = os.path.normpath(final_path)

        # Save file to filesystem
        filesystem.save_file(content, final_path)

        # Add to vector database
        chroma.add_document_to_collection(final_path, file_content)

        logging.info(f"Successfully processed: {filename}")
        return final_path
    except Exception as e:
        logging.error(f"Error processing: {filename}. Error: {str(e)}")
        return None


async def process_image(
    filename: str,
    content: bytes,
):
    try:
        logging.info(f"Processing image: {filename}")

        directory_structure = filesystem.get_directory_structure()

        # No need to encode the image for CLIP analysis - we'll use binary content directly
        # The encoded version is still needed for some other potential uses
        encoded_image = base64.b64encode(content).decode("utf-8")

        file_extension = filename.split(".")[-1].lower()
        if file_extension in ["jpg", "jpeg"]:
            media_type = "image/jpeg"
        elif file_extension == "png":
            media_type = "image/png"
        elif file_extension == "gif":
            media_type = "image/gif"
        else:
            media_type = "application/octet-stream"

        # Send raw content for CLIP analysis instead of relying only on filename
        # The llm_service will use the image content for CLIP analysis directly
        suggested_path = await llm.get_path_suggestion_for_image(
            filename=filename,
            encoded_image=encoded_image,  # This will be decoded in the service
            directory_structure=directory_structure,
            media_type=media_type,
        )

        file_extension = os.path.splitext(filename)[1]
        if not suggested_path.endswith(file_extension):
            suggested_path = os.path.join(suggested_path, filename)

        # Clean up path parts
        path_parts = suggested_path.split("/")
        corrected_path_parts = [
            path_parts[i]
            for i in range(len(path_parts))
            if i == 0 or path_parts[i] != path_parts[i - 1]
        ]

        logging.info(f"Suggested path (with CLIP analysis): {suggested_path}")

        final_path = "/".join(corrected_path_parts)
        final_path = os.path.normpath(final_path)

        # Save file to filesystem
        filesystem.save_file(content, final_path)

        # Add to vector database
        chroma.add_image_to_collection(final_path, content)

        logging.info(f"Successfully processed: {filename}")
        return final_path
    except Exception as e:
        logging.error(f"Error processing: {filename}. Error: {str(e)}")
        return None
