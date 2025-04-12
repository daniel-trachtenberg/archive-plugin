import requests
import logging
import re
import json
from config import settings


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
                return match.group(1) if match else "Uncategorized"
            else:
                logging.error(f"Failed to get suggestion from Ollama: {response.text}")
                return "Uncategorized"
        except Exception as e:
            logging.error(f"Failed to get suggestion from Ollama: {str(e)}")
            return "Uncategorized"

    @staticmethod
    async def get_suggestion_for_image_from_ollama(
        name: str,
        directory_structure: str,
    ) -> str:
        """
        Fetches a path suggestion from Ollama for an image based on the filename and directory structure.
        Since we can't send images to Ollama directly, we'll just use the filename.
        """
        try:
            prompt = f"""
            {LLMService.SYSTEM_PROMPT}
            
            <n>
            {name}
            </n>
            <content>
            This is an image file. Please suggest a path based on the filename and extension.
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
                return match.group(1) if match else "Images/Uncategorized"
            else:
                logging.error(f"Failed to get suggestion from Ollama: {response.text}")
                return "Images/Uncategorized"
        except Exception as e:
            logging.error(f"Failed to get suggestion from Ollama: {str(e)}")
            return "Images/Uncategorized"


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
        return suggested_path if suggested_path else "Uncategorized"
    except Exception as e:
        logging.error(f"Error getting path suggestion: {str(e)}")
        return "Uncategorized"


async def get_path_suggestion_for_image(
    filename: str,
    encoded_image: str,
    directory_structure: str,
    media_type: str,
) -> str:
    """
    Get a path suggestion for an image using the configured LLM service (Ollama).
    """
    try:
        suggested_path = await LLMService.get_suggestion_for_image_from_ollama(
            filename, directory_structure
        )
        return suggested_path if suggested_path else "Images/Uncategorized"
    except Exception as e:
        logging.error(f"Error getting path suggestion for image: {str(e)}")
        return "Images/Uncategorized"
