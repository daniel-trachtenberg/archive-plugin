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
import shutil
from config import settings
from datetime import datetime
import docx


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


def extract_text_from_docx(file_content):
    """
    Extract text from Word .docx file.
    """
    try:
        doc = docx.Document(io.BytesIO(file_content))
        full_text = []

        # Extract text from paragraphs
        for para in doc.paragraphs:
            if para.text:
                full_text.append(para.text)

        # Extract text from tables
        for table in doc.tables:
            for row in table.rows:
                row_text = []
                for cell in row.cells:
                    if cell.text:
                        row_text.append(cell.text)
                if row_text:
                    full_text.append(" | ".join(row_text))

        result = "\n\n".join(full_text)
        logging.info(
            f"Word document extraction complete: {len(result)} characters extracted"
        )

        # Log a preview of the extracted text (first 200 chars)
        if result:
            logging.debug(f"Content preview: {result[:200]}...")

        return result
    except Exception as e:
        logging.error(f"Failed to extract text from Word document: {str(e)}")
        import traceback

        logging.error(traceback.format_exc())
        return ""


def limit_text_for_llm(text, max_chars=8192):
    """
    Limit text size to prevent exceeding LLM context window.
    Takes the first max_chars characters from the text.

    Args:
        text (str): The input text to limit
        max_chars (int): Maximum number of characters to keep, defaults to 8192

    Returns:
        str: The limited text
    """
    if not text:
        return ""

    if len(text) <= max_chars:
        return text

    return text[:max_chars]


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
        elif filename.lower().endswith((".docx", ".doc")):
            file_content = extract_text_from_docx(content)
            logging.info(
                f"Extracted Word document content length: {len(file_content)} characters"
            )

            # Special handling for Word files with little or no extractable text
            if not file_content or len(file_content) < 50:
                logging.warning(
                    f"Word document {filename} has little or no extractable text"
                )
                # Use filename as a fallback for content
                basename = os.path.splitext(os.path.basename(filename))[0]
                processed_name = basename.replace("_", " ").replace("-", " ")
                file_content = f"Word document titled: {processed_name}"
        else:
            file_content = content.decode("utf-8")

        # Limit text size to prevent exceeding LLM context window
        file_content_for_llm = limit_text_for_llm(file_content)

        # Step 1: Generate a 3-sentence summary of the file content
        logging.info(f"Generating summary for: {filename}")
        file_summary = await llm.get_file_summary(
            filename=filename,
            content=file_content_for_llm,
        )
        logging.info(f"Generated summary: {file_summary}")

        # Step 2: Get path suggestion based on the summary and directory structure
        logging.info(f"Getting path suggestion for: {filename} based on summary")
        suggested_path = await llm.get_path_from_summary(
            filename=filename,
            summary=file_summary,
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

        # Sanitize the suggested path to ensure proper file placement
        suggested_path = sanitize_path_suggestion(suggested_path, filename)

        # After sanitizing, check if we need to add the filename
        if not suggested_path.endswith(filename):
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

        # Ensure directory structure is not too large for LLM context
        limited_dir_structure = limit_text_for_llm(directory_structure)

        # Try to get CLIP description directly
        image_summary = ""
        try:
            # Get the image summary from the CLIP model and LLM
            image_summary = await llm.get_image_summary(
                filename=filename,
                encoded_image=encoded_image,
                media_type=media_type,
            )
            logging.info(f"Image summary: {image_summary}")
        except Exception as e:
            logging.error(
                f"Error getting image summary, falling back to direct path suggestion: {e}"
            )
            # Use the path suggestion for image directly on failure
            suggested_path = await llm.get_path_suggestion_for_image(
                filename=filename,
                encoded_image=encoded_image,
                directory_structure=limited_dir_structure,
                media_type=media_type,
            )
            logging.info(f"Got path suggestion directly: {suggested_path}")

        # If we got a summary, use it to get a path suggestion
        if image_summary:
            # Get path suggestion based on the image summary
            logging.info(
                f"Getting path suggestion for image: {filename} based on summary"
            )
            suggested_path = await llm.get_path_from_summary(
                filename=filename,
                summary=image_summary,
                directory_structure=limited_dir_structure,
            )
            logging.info(f"Path suggestion from summary: {suggested_path}")

        # Sanitize the suggested path to ensure proper file placement
        suggested_path = sanitize_path_suggestion(suggested_path, filename)

        # After sanitizing, check if we need to add the filename
        if not suggested_path.endswith(filename):
            suggested_path = os.path.join(suggested_path, filename)

        # Clean up path parts
        path_parts = suggested_path.split("/")
        corrected_path_parts = [
            path_parts[i]
            for i in range(len(path_parts))
            if i == 0 or path_parts[i] != path_parts[i - 1]
        ]

        logging.info(f"Suggested path (with image analysis): {suggested_path}")

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


async def process_folder(
    folder_name: str,
    folder_path: str,
):
    """
    Process a folder and move it to the suggested path within the Archive folder.
    Uses the folder name and filenames inside as content for classification.

    Args:
        folder_name: The name of the folder
        folder_path: The full path to the folder in the Input directory

    Returns:
        The final path where the folder was moved to in the Archive
    """
    try:
        logging.info(f"Processing folder: {folder_name} at path: {folder_path}")

        # First verify the folder still exists
        if not os.path.exists(folder_path):
            logging.error(f"Folder no longer exists at {folder_path}, cannot process")
            return None

        # Verify it's actually a directory
        if not os.path.isdir(folder_path):
            logging.error(f"Path {folder_path} is not a directory, cannot process")
            return None

        directory_structure = filesystem.get_directory_structure()

        # Create enhanced content with detailed folder analysis
        folder_content = f"FOLDER ANALYSIS:\n\nFolder name: {folder_name}\n\n"

        # Track file types for better categorization
        file_counts = {
            "images": 0,
            "documents": 0,
            "spreadsheets": 0,
            "presentations": 0,
            "audio": 0,
            "video": 0,
            "code": 0,
            "data": 0,
            "archives": 0,
            "other": 0,
        }

        file_extensions = []
        total_files = 0
        total_subfolders = 0

        try:
            # First gather statistics about the folder contents
            for root, dirs, files in os.walk(folder_path):
                # Count subfolders at the top level
                if root == folder_path:
                    total_subfolders = len(dirs)

                total_files += len(files)

                for file in files:
                    if file.startswith("."):
                        continue

                    # Track file extension
                    ext = os.path.splitext(file)[1].lower()
                    if ext and ext not in file_extensions:
                        file_extensions.append(ext)

                    # Count file types
                    if ext in [
                        ".jpg",
                        ".jpeg",
                        ".png",
                        ".gif",
                        ".bmp",
                        ".tiff",
                        ".webp",
                    ]:
                        file_counts["images"] += 1
                    elif ext in [".doc", ".docx", ".txt", ".rtf", ".odt", ".pdf"]:
                        file_counts["documents"] += 1
                    elif ext in [".xls", ".xlsx", ".csv", ".ods"]:
                        file_counts["spreadsheets"] += 1
                    elif ext in [".ppt", ".pptx", ".odp"]:
                        file_counts["presentations"] += 1
                    elif ext in [".mp3", ".wav", ".ogg", ".flac", ".aac", ".m4a"]:
                        file_counts["audio"] += 1
                    elif ext in [".mp4", ".mov", ".avi", ".mkv", ".webm", ".flv"]:
                        file_counts["video"] += 1
                    elif ext in [
                        ".py",
                        ".js",
                        ".html",
                        ".css",
                        ".java",
                        ".c",
                        ".cpp",
                        ".php",
                        ".rb",
                        ".go",
                        ".ts",
                    ]:
                        file_counts["code"] += 1
                    elif ext in [".json", ".xml", ".yaml", ".sql", ".db"]:
                        file_counts["data"] += 1
                    elif ext in [".zip", ".rar", ".tar", ".gz", ".7z"]:
                        file_counts["archives"] += 1
                    else:
                        file_counts["other"] += 1

            # Add file type summary
            folder_content += f"File type summary:\n"
            for file_type, count in file_counts.items():
                if count > 0:
                    folder_content += f"- {file_type}: {count} files\n"

            if file_extensions:
                folder_content += f"\nFile extensions: {', '.join(file_extensions)}\n"

            folder_content += f"\nTotal files: {total_files}\n"
            folder_content += f"Total subfolders: {total_subfolders}\n\n"

            # Now list specific files and folders for context
            folder_content += "FOLDER CONTENTS:\n\n"

            # Get list of files for classification
            file_list = []
            subfolder_list = []

            # Just get the top level contents for conciseness
            for item in os.listdir(folder_path):
                item_path = os.path.join(folder_path, item)

                # Skip hidden files/folders
                if item.startswith("."):
                    continue

                if os.path.isdir(item_path):
                    subfolder_list.append(item)
                else:
                    file_list.append(item)

            # Add folder content details
            if subfolder_list:
                folder_content += "Subfolders:\n"
                for subfolder in sorted(subfolder_list):
                    subfolder_desc = subfolder.replace("_", " ").replace("-", " ")
                    folder_content += f"- {subfolder_desc}\n"
                folder_content += "\n"

            if file_list:
                folder_content += "Files:\n"
                for file in sorted(file_list):
                    file_desc = file.replace("_", " ").replace("-", " ")
                    folder_content += f"- {file_desc}\n"
            else:
                folder_content += "- (Empty folder)\n"

        except Exception as e:
            logging.error(f"Error analyzing folder contents: {str(e)}")
            folder_content += "Error reading folder contents"

        # Limit text size to prevent exceeding LLM context window
        folder_content_for_llm = limit_text_for_llm(folder_content)

        # Step 1: Generate a summary of the folder content
        logging.info(f"Generating summary for folder: {folder_name}")
        folder_summary = await llm.get_file_summary(
            filename=folder_name,
            content=folder_content_for_llm,
        )
        logging.info(f"Generated folder summary: {folder_summary}")

        # Step 2: Get path suggestion based on the folder summary
        logging.info(
            f"Getting path suggestion for folder: {folder_name} based on summary"
        )
        suggested_path = await llm.get_path_from_summary(
            filename=folder_name,
            summary=folder_summary,
            directory_structure=directory_structure,
        )

        logging.info(f"Initial suggested path for folder: {suggested_path}")

        # Add the folder name to the path
        if suggested_path:
            final_path = os.path.join(suggested_path, folder_name)
        else:
            final_path = folder_name

        final_path = os.path.normpath(final_path)

        # Get the full source and destination paths
        source_path = folder_path
        dest_path = os.path.join(settings.ARCHIVE_DIR, final_path)

        logging.info(f"Planning to move folder from {source_path} to {dest_path}")

        # Verify again that the source folder exists before copying
        if not os.path.exists(source_path):
            logging.error(
                f"Source folder no longer exists at {source_path}, cannot copy"
            )
            return None

        # Create a temporary copy to ensure we don't lose the folder during processing
        temp_copy_path = os.path.join(
            settings.ARCHIVE_DIR,
            f"temp_{folder_name}_{int(datetime.now().timestamp())}",
        )
        try:
            # Create a safe copy of the folder first
            logging.info(f"Creating temporary copy at {temp_copy_path}")
            shutil.copytree(source_path, temp_copy_path)
        except Exception as e:
            logging.error(f"Error creating temporary copy of folder: {str(e)}")
            return None

        # If the destination exists but isn't a directory, find an alternative
        if os.path.exists(dest_path) and not os.path.isdir(dest_path):
            i = 1
            original_path = dest_path
            while os.path.exists(dest_path) and not os.path.isdir(dest_path):
                new_folder_name = f"{folder_name}_{i}"
                final_path = os.path.join(suggested_path, new_folder_name)
                dest_path = os.path.join(settings.ARCHIVE_DIR, final_path)
                i += 1
            logging.info(
                f"Destination exists as file, using alternative path: {dest_path}"
            )

        # Ensure the parent directory exists for the destination
        parent_dir = os.path.dirname(dest_path)
        os.makedirs(parent_dir, exist_ok=True)

        # Move from the temporary copy to the final destination
        try:
            if os.path.exists(dest_path):
                if os.path.isdir(dest_path):
                    # If destination exists and is a directory, merge contents
                    logging.info(f"Destination exists, merging contents")
                    for item in os.listdir(temp_copy_path):
                        src = os.path.join(temp_copy_path, item)
                        dst = os.path.join(dest_path, item)
                        if os.path.isdir(src):
                            if not os.path.exists(dst):
                                shutil.copytree(src, dst)
                            else:
                                # Recursively merge subdirectories
                                for subitem in os.listdir(src):
                                    src_sub = os.path.join(src, subitem)
                                    dst_sub = os.path.join(dst, subitem)
                                    if os.path.isdir(src_sub):
                                        if not os.path.exists(dst_sub):
                                            shutil.copytree(src_sub, dst_sub)
                                    elif not os.path.exists(dst_sub):
                                        shutil.copy2(src_sub, dst_sub)
                        elif not os.path.exists(dst):
                            shutil.copy2(src, dst)
                else:
                    # Edge case: destination exists but is not a directory
                    logging.error(
                        f"Destination exists but is not a directory: {dest_path}"
                    )
                    # Create a new unique folder name
                    i = 1
                    while os.path.exists(dest_path):
                        new_folder_name = f"{folder_name}_{i}"
                        final_path = os.path.join(suggested_path, new_folder_name)
                        dest_path = os.path.join(settings.ARCHIVE_DIR, final_path)
                        i += 1
                    os.makedirs(dest_path, exist_ok=True)
                    # Copy from temp to new location
                    for item in os.listdir(temp_copy_path):
                        src = os.path.join(temp_copy_path, item)
                        dst = os.path.join(dest_path, item)
                        if os.path.isdir(src):
                            shutil.copytree(src, dst)
                        else:
                            shutil.copy2(src, dst)
            else:
                # Destination doesn't exist, move the temp folder to destination
                logging.info(f"Creating new directory at destination")
                # Create parent directories
                os.makedirs(os.path.dirname(dest_path), exist_ok=True)
                # Move the temp folder to the final destination
                shutil.move(temp_copy_path, dest_path)
        except Exception as e:
            logging.error(f"Error moving folder to final destination: {str(e)}")
            # Try to clean up temporary files
            if os.path.exists(temp_copy_path):
                try:
                    shutil.rmtree(temp_copy_path)
                except:
                    pass
            return None

        # Clean up temporary files
        if os.path.exists(temp_copy_path) and temp_copy_path != dest_path:
            try:
                shutil.rmtree(temp_copy_path)
            except Exception as e:
                logging.warning(
                    f"Could not remove temporary folder {temp_copy_path}: {str(e)}"
                )

        # Log the final path to the terminal
        print(f"Folder moved to: {final_path}")

        logging.info(f"Successfully processed folder: {folder_name}")
        return final_path
    except Exception as e:
        logging.error(f"Error processing folder: {folder_name}. Error: {str(e)}")
        return None


def sanitize_path_suggestion(suggested_path, filename):
    """
    Sanitize path suggestions to ensure correct file placement.

    Fixes common issues like:
    1. Paths containing existing filenames (creating file-inside-file situations)
    2. File extensions in directory names
    3. Missing directory structure

    Args:
        suggested_path (str): The path suggested by the LLM
        filename (str): The name of the file being processed

    Returns:
        str: A sanitized path that ensures proper file placement
    """
    logging.info(f"Sanitizing path suggestion: {suggested_path} for file {filename}")

    # First, normalize path separators
    suggested_path = suggested_path.replace("\\", "/")

    # Check if the suggested path already ends with the filename
    if suggested_path.endswith(filename):
        # Path already includes filename - extract the directory part
        directory_path = os.path.dirname(suggested_path)
        logging.info(
            f"Path already includes filename, extracted directory: {directory_path}"
        )
        return directory_path

    # Get the base filename without path
    basename = os.path.basename(filename)

    # Check if any path component resembles a filename (contains periods)
    path_parts = suggested_path.split("/")
    i = 0
    while i < len(path_parts):
        part = path_parts[i]

        # Skip empty parts
        if not part:
            i += 1
            continue

        # Check if this component is or contains our filename
        if part == basename or filename in part:
            # Remove this part as it's the filename we're trying to place
            path_parts.pop(i)
            logging.info(f"Removed filename from path parts at position {i}")
            continue

        # Check if this part looks like a filename with extension
        if "." in part and not part.startswith("."):
            # Check if it's a common file extension pattern
            ext = os.path.splitext(part)[1].lower()
            if ext and len(ext) <= 5:  # .html, .jpeg, .docx, etc.
                # This looks like a filename - remove it entirely
                path_parts.pop(i)
                logging.info(f"Removed file-like component: {part}")
                continue

        i += 1

    # Rebuild the path
    sanitized_path = "/".join(path_parts)

    # Make sure we don't have an empty path
    if not sanitized_path:
        file_extension = os.path.splitext(filename)[1].lower()
        if file_extension in [".jpg", ".jpeg", ".png", ".gif"]:
            sanitized_path = "Images"
        elif file_extension in [".pdf", ".doc", ".docx", ".txt"]:
            sanitized_path = "Documents"
        elif file_extension in [".mp3", ".wav", ".flac"]:
            sanitized_path = "Music"
        elif file_extension in [".mp4", ".mov", ".avi"]:
            sanitized_path = "Videos"
        else:
            sanitized_path = "General"

    logging.info(f"Sanitized path: {sanitized_path}")
    return sanitized_path
