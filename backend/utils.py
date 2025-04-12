import services.filesystem_service as filesystem
import services.llm_service as llm
import services.chroma_service as chroma
from fastapi import HTTPException
from PyPDF2 import PdfReader
import base64
import io
import os
import logging
from pptx import Presentation


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


def extract_text_from_pptx(file_content):
    """
    Extract text from PowerPoint .pptx file.
    """
    try:
        prs = Presentation(io.BytesIO(file_content))
        full_text = []

        logging.info(
            f"Starting extraction from PowerPoint with {len(prs.slides)} slides"
        )

        for slide_num, slide in enumerate(prs.slides, 1):
            slide_text = [f"Slide {slide_num}:"]

            # Extract text from all shapes including titles and content placeholders
            shape_count = 0
            text_shape_count = 0
            table_count = 0
            group_shape_count = 0

            for shape in slide.shapes:
                if hasattr(shape, "text") and shape.text:
                    slide_text.append(shape.text)
                    text_shape_count += 1

                # Extract text from tables
                if shape.has_table:
                    table_count += 1
                    for row in shape.table.rows:
                        row_text = []
                        for cell in row.cells:
                            if cell.text:
                                row_text.append(cell.text)
                        if row_text:
                            slide_text.append(" | ".join(row_text))

                # Extract text from group shapes
                if shape.shape_type == 6:  # GROUP shape type
                    group_shape_count += 1
                    for subshape in shape.shapes:
                        if hasattr(subshape, "text") and subshape.text:
                            slide_text.append(subshape.text)

                shape_count += 1

            # Add slide text to full text
            if (
                len(slide_text) > 1
            ):  # Only add if there's more than just the slide number
                full_text.append("\n".join(slide_text))

            logging.debug(
                f"Slide {slide_num}: Found {shape_count} shapes, {text_shape_count} with text, {table_count} tables, {group_shape_count} group shapes"
            )

        result = "\n\n".join(full_text)
        logging.info(
            f"PowerPoint extraction complete: {len(result)} characters extracted"
        )

        # Log a preview of the extracted text (first 200 chars)
        if result:
            logging.debug(f"Content preview: {result[:200]}...")

        return result
    except Exception as e:
        logging.error(f"Failed to extract text from PowerPoint: {str(e)}")
        import traceback

        logging.error(traceback.format_exc())
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
        elif filename.lower().endswith(".pptx"):
            file_content = extract_text_from_pptx(content)
            logging.info(
                f"Extracted PowerPoint content length: {len(file_content)} characters"
            )

            # Special handling for PowerPoint files with little or no extractable text
            if not file_content or len(file_content) < 50:
                logging.warning(
                    f"PowerPoint file {filename} has little or no extractable text"
                )
                # Use filename as a fallback for content
                basename = os.path.splitext(os.path.basename(filename))[0]
                processed_name = basename.replace("_", " ").replace("-", " ")
                file_content = f"PowerPoint presentation titled: {processed_name}"
        else:
            file_content = content.decode("utf-8")

        logging.info(f"Getting path suggestion for: {filename}")
        suggested_path = await llm.get_path_suggestion(
            filename=filename,
            content=file_content,
            directory_structure=directory_structure,
        )
        logging.info(f"Initial suggested path: {suggested_path}")

        # PowerPoint-specific classification
        if filename.lower().endswith(".pptx") and (
            not suggested_path or suggested_path == "General"
        ):
            # Special handling for PowerPoint files that didn't get a good classification
            file_ext = os.path.splitext(filename)[1].lower()
            basename = os.path.splitext(os.path.basename(filename))[0]
            topic = basename.replace("_", " ").replace("-", " ").title()

            if topic and topic != "Untitled" and topic != "Presentation":
                suggested_path = f"Presentations/{topic}"
            else:
                suggested_path = "Presentations/General"

            logging.info(f"PowerPoint fallback path: {suggested_path}")

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

        # Log the final path to the terminal
        print(f"Document moved to: {final_path}")

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

        # Log the final path to the terminal
        print(f"Image moved to: {final_path}")

        logging.info(f"Successfully processed: {filename}")
        return final_path
    except Exception as e:
        logging.error(f"Error processing: {filename}. Error: {str(e)}")
        return None
