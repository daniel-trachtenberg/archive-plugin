import requests
import logging
import re
import json
import os
from config import settings
from services import image_analysis_service


class LLMService:
    SYSTEM_PROMPT = """
    You are an AI assistant that helps organize files into a directory structure based on the file's content. You will be given the name of a file, its content or description, and the current directory structure. Your task is to analyze the file and suggest the most appropriate directory path to place it within the existing structure. If needed, you may suggest creating new directories to better categorize the file, while ensuring that the naming of any new directories is consistent with the naming of the current directory structure.

    To make your suggestion, simply output the directory path starting with <suggestedpath>, for example:
    <suggestedpath>Work/Project_x/Research/</suggestedpath>

    Remember to consider the following when making your suggestion:
    - The file type (e.g., .txt, .jpg, .pdf)
    - The content or subject matter of the file
    - The existing directory structure and how to best fit the file within it
    - Creating new directories if they would help better organize the file

    Only suggest the directory path.

    Input variables:
    File name: {{name}}
    File content or description: {{content}}
    Current directory structure: {{directory}}
    """

    @staticmethod
    async def get_suggestion_from_ollama(
        name: str, content: str, directory_structure: str
    ) -> str:
        """
        Fetches a path suggestion from Ollama based on the input filename, file content, and current directory structure.
        """
        try:
            prompt = f"""
            {LLMService.SYSTEM_PROMPT}
            
            <n>
            {name}
            </n>
            <content>
            {content[:5000]}  # Limit content size
            </content>
            <directory>
            {directory_structure}
            </directory>
            """

            response = requests.post(
                f"{settings.OLLAMA_BASE_URL}/api/generate",
                json={
                    "model": settings.OLLAMA_MODEL,
                    "prompt": prompt,
                    "stream": False,
                    "options": {
                        "temperature": 0.0,
                    },
                },
                timeout=60,
            )

            if response.status_code == 200:
                result = response.json()
                match = re.search(
                    r"<suggestedpath>(.*?)</suggestedpath>",
                    result.get("response", ""),
                )
                suggested_path = match.group(1) if match else ""

                # If empty or default to "Uncategorized", extract topic from content
                if not suggested_path or suggested_path == "Uncategorized":
                    # Extract topic from filename if available
                    filename_without_ext = os.path.splitext(name)[0]
                    topic = (
                        filename_without_ext.replace("_", " ").replace("-", " ").title()
                    )

                    # Create a meaningful path from the file metadata
                    if (
                        topic
                        and topic != "Untitled"
                        and topic != "Document"
                        and topic != "Image"
                    ):
                        suggested_path = topic
                    else:
                        # Default to a general category based on extension as last resort
                        file_extension = os.path.splitext(name)[1].lower().lstrip(".")
                        if file_extension in [
                            "pdf",
                            "doc",
                            "docx",
                            "txt",
                            "rtf",
                            "odt",
                        ]:
                            suggested_path = "Reading/General"
                        elif file_extension in [
                            "jpg",
                            "jpeg",
                            "png",
                            "gif",
                            "bmp",
                            "svg",
                            "webp",
                        ]:
                            suggested_path = "Visual/General"
                        elif file_extension in [
                            "mp3",
                            "wav",
                            "ogg",
                            "flac",
                            "m4a",
                            "aac",
                        ]:
                            suggested_path = "Audio/General"
                        elif file_extension in [
                            "mp4",
                            "mov",
                            "avi",
                            "mkv",
                            "wmv",
                            "flv",
                        ]:
                            suggested_path = "Media/General"
                        elif file_extension in ["xls", "xlsx", "csv", "tsv"]:
                            suggested_path = "Data/General"
                        elif file_extension in ["ppt", "pptx"]:
                            suggested_path = "Presentations/General"
                        else:
                            suggested_path = "General"

                # Ensure the path doesn't end with the file extension
                suggested_path = suggested_path.rstrip("/")
                return suggested_path
            else:
                logging.error(f"Failed to get suggestion from Ollama: {response.text}")
                # Extract topic from filename if available
                filename_without_ext = os.path.splitext(name)[0]
                topic = filename_without_ext.replace("_", " ").replace("-", " ").title()

                if (
                    topic
                    and topic != "Untitled"
                    and topic != "Document"
                    and topic != "Image"
                ):
                    return topic
                return "General"
        except Exception as e:
            logging.error(f"Failed to get suggestion from Ollama: {str(e)}")
            return "General"

    @staticmethod
    async def get_suggestion_for_image_from_ollama(
        name: str,
        directory_structure: str,
        image_content: bytes = None,  # New parameter for image binary content
    ) -> str:
        """
        Fetches a path suggestion for an image based on the filename and CLIP analysis.
        """
        try:
            # First, try to analyze the image with CLIP for a detailed description
            detailed_description = None
            detailed_categories = []
            clip_path = None

            if image_content:
                analysis = image_analysis_service.analyze_image(image_content)

                if analysis and "description" in analysis:
                    detailed_description = analysis["description"]
                    logging.info(
                        f"Generated CLIP description for {name}: {detailed_description}"
                    )

                if analysis and "categories" in analysis:
                    detailed_categories = analysis["categories"]

                clip_path = image_analysis_service.get_suggested_path_from_analysis(
                    analysis, name
                )
                if clip_path:
                    logging.info(f"CLIP suggested path for {name}: {clip_path}")
                    # Remove "Images/" prefix if present
                    if clip_path.startswith("Images/"):
                        clip_path = clip_path[7:]  # Remove "Images/" prefix

            # Extract potential topic from filename
            filename_without_ext = os.path.splitext(name)[0]
            topic = filename_without_ext.replace("_", " ").replace("-", " ").title()

            # Use detailed image description with LLM for better categorization
            image_content_description = (
                f"This is an image file with the following content: "
            )

            if detailed_description:
                image_content_description += f"{detailed_description}. "

                # Add detailed attributes if available
                if analysis and "attributes" in analysis and analysis["attributes"]:
                    image_content_description += (
                        f"Visual attributes: {', '.join(analysis['attributes'])}. "
                    )

                if analysis and "colors" in analysis and analysis["colors"]:
                    image_content_description += (
                        f"Colors: {', '.join(analysis['colors'])}. "
                    )

                if analysis and "style" in analysis and analysis["style"]:
                    image_content_description += f"Style: {analysis['style']}. "

                if analysis and "orientation" in analysis:
                    image_content_description += (
                        f"Orientation: {analysis['orientation']}. "
                    )
            else:
                # Fallback to basic description from filename
                image_content_description += f"Filename suggests it contains: {topic}. "

            if detailed_categories:
                image_content_description += f"The image appears to contain: {', '.join(detailed_categories[:3])}."

            prompt = f"""
            {LLMService.SYSTEM_PROMPT}
            
            <n>
            {name}
            </n>
            <content>
            {image_content_description}
            Please suggest a path based on the detailed image content description.
            </content>
            <directory>
            {directory_structure}
            </directory>
            """

            response = requests.post(
                f"{settings.OLLAMA_BASE_URL}/api/generate",
                json={
                    "model": settings.OLLAMA_MODEL,
                    "prompt": prompt,
                    "stream": False,
                    "options": {
                        "temperature": 0.0,
                    },
                },
                timeout=30,
            )

            if response.status_code == 200:
                result = response.json()
                match = re.search(
                    r"<suggestedpath>(.*?)</suggestedpath>",
                    result.get("response", ""),
                )
                suggested_path = match.group(1) if match else ""

                # Remove "Images/" prefix if present since we're organizing by content
                if suggested_path.startswith("Images/"):
                    suggested_path = suggested_path[7:]

                # If empty or default to Uncategorized, use CLIP path if available
                if not suggested_path or suggested_path == "Uncategorized":
                    if clip_path:
                        return clip_path

                    # Use detailed categories from CLIP if available
                    if detailed_categories:
                        primary_category = detailed_categories[0].title()
                        return primary_category

                    # Use the meaningful topic from filename as fallback
                    if topic and topic != "Untitled" and topic != "Image":
                        return topic

                    # Generate a category based on image content hint
                    file_extension = os.path.splitext(name)[1].lower().lstrip(".")
                    if file_extension in ["svg", "ai", "eps"]:
                        return "Vector"
                    elif file_extension in ["gif"]:
                        return "Animated"
                    elif file_extension in ["png"] and "screenshot" in name.lower():
                        return "Screenshots"
                    else:
                        return "Photos/General"

                # Ensure the path doesn't end with the file extension
                suggested_path = suggested_path.rstrip("/")
                return suggested_path
            else:
                logging.error(f"Failed to get suggestion from Ollama: {response.text}")

                # Try to use CLIP path as fallback
                if clip_path:
                    return clip_path

                # Try to use categories as fallback
                if detailed_categories:
                    return detailed_categories[0].title()

                # Generate a meaningful fallback from filename
                if topic and topic != "Untitled" and topic != "Image":
                    return topic
                return "Photos/General"
        except Exception as e:
            logging.error(f"Error getting path suggestion for image: {str(e)}")
            return "Photos/General"


async def get_path_suggestion(
    filename: str,
    content: str,
    directory_structure: str,
) -> str:
    """
    Get a path suggestion for a document using the configured LLM service (Ollama).
    """
    try:
        suggested_path = await LLMService.get_suggestion_from_ollama(
            filename, content, directory_structure
        )

        # Ensure we don't return an empty path or just "Uncategorized"
        if not suggested_path or suggested_path == "Uncategorized":
            # Extract topic from filename
            filename_without_ext = os.path.splitext(filename)[0]
            topic = filename_without_ext.replace("_", " ").replace("-", " ").title()

            if (
                topic
                and topic != "Untitled"
                and topic != "Document"
                and topic != "Image"
            ):
                return topic
            return "General"

        return suggested_path
    except Exception as e:
        logging.error(f"Error getting path suggestion: {str(e)}")
        return "General"


async def get_path_suggestion_for_image(
    filename: str,
    encoded_image: str,
    directory_structure: str,
    media_type: str,
) -> str:
    """
    Get a path suggestion for an image using the configured LLM service and CLIP image analysis.
    """
    try:
        # Decode the base64 image if provided
        image_content = None
        if encoded_image and isinstance(encoded_image, str):
            try:
                import base64

                image_content = base64.b64decode(encoded_image)
            except Exception as e:
                logging.error(f"Error decoding image: {str(e)}")

        # Get suggestion with the decoded image content
        suggested_path = await LLMService.get_suggestion_for_image_from_ollama(
            filename, directory_structure, image_content
        )

        # Ensure we don't return an empty path or just "Uncategorized"
        if (
            not suggested_path
            or suggested_path == "Uncategorized"
            or suggested_path == "Images/Uncategorized"
        ):
            # If we have image content, try CLIP analysis as fallback
            if image_content:
                analysis = image_analysis_service.analyze_image(image_content)
                clip_path = image_analysis_service.get_suggested_path_from_analysis(
                    analysis, filename
                )
                if clip_path:
                    # Remove "Images/" prefix if present
                    if clip_path.startswith("Images/"):
                        clip_path = clip_path[7:]
                    return clip_path

            # Extract content from filename
            filename_without_ext = os.path.splitext(filename)[0]
            topic = filename_without_ext.replace("_", " ").replace("-", " ").title()

            if topic and topic != "Untitled" and topic != "Image":
                return topic

            # Fall back to content-based categories
            if "screenshot" in filename.lower():
                return "Screenshots"
            return "Photos/General"

        return suggested_path
    except Exception as e:
        logging.error(f"Error getting path suggestion for image: {str(e)}")
        return "Photos/General"
