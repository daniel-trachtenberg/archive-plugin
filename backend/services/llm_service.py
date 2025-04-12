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

    IMPORTANT: For PDF files and documents, prioritize analyzing the CONTENT over the filename. Read and comprehend the actual content carefully to determine meaningful categories based on the subject matter, topics, and themes discussed in the document.

    To make your suggestion, simply output the directory path starting with <suggestedpath>, for example:
    <suggestedpath>Work/Project_x/Research/</suggestedpath>

    Remember to consider the following when making your suggestion:
    1. CONTENT FIRST: The actual content and subject matter of the file is the PRIMARY factor for categorization
    2. ANALYZE THE TEXT: For documents like PDFs, thoroughly analyze the text content to understand the topics
    3. The file type (e.g., .txt, .jpg, .pdf) 
    4. The existing directory structure and how to best fit the file within it
    5. Creating new directories if they would help better organize the file
    6. Don't create deep file paths, keep it simple and relatively shallow
    7. File name should be a secondary factor after content analysis
    8. For PDFs with random filenames, focus entirely on the document content

    Only suggest the directory path.

    Input variables:
    <file-name>
    {{name}}
    </file-name>
    <content>
    {{content}}
    </content>
    <directory>
    {{directory}}
    </directory>
    """

    @staticmethod
    async def get_suggestion_from_ollama(
        name: str, content: str, directory_structure: str
    ) -> str:
        """
        Fetches a path suggestion from Ollama based on the input filename, file content, and current directory structure.
        """
        try:
            # Handle large content by extracting most important parts (up to 5000 chars)
            processed_content = content
            content_limit = 5000

            # Special handling for PDFs to prioritize content analysis
            is_pdf = name.lower().endswith(".pdf")

            # Check if we need to truncate and summarize
            if len(content) > content_limit:
                # PDF-specific processing to extract more meaningful context
                if is_pdf:
                    # For PDFs, try to extract key sections by looking for headers and important content
                    # First, get the first 500 chars which often has the title/abstract
                    intro_content = content[:500]

                    # Look for potential headers or section markers in the document
                    potential_sections = re.findall(
                        r"(?:^|\n)(?:[A-Z][A-Za-z\s]{2,50}:?|[0-9]+\.\s+[A-Z][A-Za-z\s]{2,50})(?:\n|$)",
                        content,
                    )

                    # If we found section headers, try to extract content from important sections
                    if potential_sections and len(potential_sections) > 2:
                        main_sections = []
                        chars_remaining = content_limit - len(intro_content)

                        # Try to extract content from sections that seem most relevant
                        important_section_keywords = [
                            "introduction",
                            "abstract",
                            "summary",
                            "conclusion",
                            "results",
                            "findings",
                            "discussion",
                        ]

                        # Find important sections
                        for section in potential_sections[
                            :10
                        ]:  # Check first 10 potential sections
                            section_title = section.strip().lower()
                            section_start = content.find(section)

                            if section_start > 0 and any(
                                keyword in section_title
                                for keyword in important_section_keywords
                            ):
                                # Find the next section or take 300 chars
                                next_section_start = (
                                    content.find(
                                        potential_sections[
                                            potential_sections.index(section) + 1
                                        ]
                                    )
                                    if potential_sections.index(section)
                                    < len(potential_sections) - 1
                                    else -1
                                )

                                if next_section_start > 0:
                                    section_content = content[
                                        section_start : min(
                                            section_start + 300, next_section_start
                                        )
                                    ]
                                else:
                                    section_content = content[
                                        section_start : section_start + 300
                                    ]

                                if chars_remaining > len(section_content):
                                    main_sections.append(section_content)
                                    chars_remaining -= len(section_content)
                                else:
                                    main_sections.append(
                                        section_content[:chars_remaining]
                                    )
                                    chars_remaining = 0
                                    break

                        # If we extracted meaningful sections
                        if main_sections:
                            processed_content = (
                                intro_content + "\n\n" + "\n\n".join(main_sections)
                            )
                        else:
                            # If no meaningful sections found, just sample throughout the document
                            chunks = []
                            total_chunks = (
                                6  # Take samples from 6 different parts of the document
                            )
                            chunk_size = content_limit // total_chunks

                            for i in range(total_chunks):
                                start_pos = i * (len(content) // total_chunks)
                                chunks.append(
                                    content[start_pos : start_pos + chunk_size]
                                )

                            processed_content = "\n...\n".join(chunks)
                    else:
                        # If no clear sections, take samples from throughout the document
                        chunks = []
                        total_chunks = (
                            6  # Take samples from 6 different parts of the document
                        )
                        chunk_size = content_limit // total_chunks

                        for i in range(total_chunks):
                            start_pos = i * (len(content) // total_chunks)
                            chunks.append(content[start_pos : start_pos + chunk_size])

                        processed_content = "\n...\n".join(chunks)
                # For pptx files, prioritize slide titles and first few lines of each slide
                elif name.lower().endswith(".pptx"):
                    # Existing PPTX handling
                    slides = content.split("\n\n")
                    summary_slides = []
                    remaining_chars = content_limit

                    # Always include the first slide (usually has title/overview)
                    if slides and remaining_chars > 0:
                        first_slide = slides[0][
                            : min(len(slides[0]), 500)
                        ]  # First 500 chars of first slide
                        summary_slides.append(first_slide)
                        remaining_chars -= len(first_slide)

                    # Extract title and first line from each slide until we reach the limit
                    for slide in slides[1:]:
                        if remaining_chars <= 0:
                            break

                        slide_lines = slide.split("\n")
                        slide_title = slide_lines[0] if slide_lines else ""

                        # Get title and first content line if available
                        slide_extract = slide_title
                        if len(slide_lines) > 1:
                            # Add first content line if it's not empty
                            first_content = next(
                                (line for line in slide_lines[1:] if line.strip()), ""
                            )
                            if first_content:
                                slide_extract += "\n" + first_content

                        # Add if we have space
                        if len(slide_extract) < remaining_chars:
                            summary_slides.append(slide_extract)
                            remaining_chars -= len(slide_extract)
                        else:
                            # Add truncated version with as much as will fit
                            summary_slides.append(slide_extract[:remaining_chars])
                            remaining_chars = 0
                            break

                    processed_content = "\n\n".join(summary_slides)
                else:
                    # For other file types, just take beginning and end with a note in between
                    start_content = content[: content_limit // 2]
                    end_content = content[-content_limit // 2 :]
                    processed_content = (
                        f"{start_content}\n...[content truncated]...\n{end_content}"
                    )

            # Add an instruction for PDFs to emphasize content analysis
            content_hint = ""
            if is_pdf:
                content_hint = "\nIMPORTANT: This is a PDF document. Please analyze its CONTENT carefully to categorize it, rather than relying on the filename."

            prompt = f"""
            {LLMService.SYSTEM_PROMPT}
            
            <n>
            {name}
            </n>
            <content>
            {processed_content}{content_hint}
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

                # For PDFs, avoid using filename-based categorization entirely if we have content
                if (
                    is_pdf
                    and content
                    and (not suggested_path or suggested_path == "Uncategorized")
                ):
                    # Try one more attempt with temperature 0.2 for more creative categorization
                    response = requests.post(
                        f"{settings.OLLAMA_BASE_URL}/api/generate",
                        json={
                            "model": settings.OLLAMA_MODEL,
                            "prompt": prompt
                            + "\n\nPlease analyze the content carefully and suggest a more specific category based on the document's subject matter.",
                            "stream": False,
                            "options": {
                                "temperature": 0.2,  # Slightly higher temperature for more creative categorization
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
                        second_attempt = match.group(1) if match else ""
                        if second_attempt and second_attempt != "Uncategorized":
                            suggested_path = second_attempt

                    # If we still don't have a good category, use document content type
                    if not suggested_path or suggested_path == "Uncategorized":
                        # For PDFs, categorize by document type if possible
                        document_type_patterns = {
                            r"invoice|receipt|bill|payment": "Finance/Invoices",
                            r"tax|taxes|irs|1099|w-2": "Finance/Taxes",
                            r"report|analysis|research": "Documents/Reports",
                            r"contract|agreement|legal": "Documents/Legal",
                            r"manual|guide|instructions": "Documents/Manuals",
                            r"certificate|diploma|degree": "Documents/Certificates",
                            r"letter|correspondence": "Documents/Correspondence",
                            r"article|journal|publication": "Documents/Articles",
                            r"resume|cv|curriculum": "Documents/Resumes",
                            r"meeting|minutes|agenda": "Documents/Meetings",
                            r"proposal|plan|strategy": "Documents/Proposals",
                        }

                        # Check content against patterns
                        for pattern, category in document_type_patterns.items():
                            if re.search(pattern, content.lower()):
                                suggested_path = category
                                break

                        # If still no match, use "Documents" as default for PDFs
                        if not suggested_path or suggested_path == "Uncategorized":
                            suggested_path = "Documents/General"
                # If empty or default to "Uncategorized" for non-PDFs, extract topic from content
                elif not is_pdf and (
                    not suggested_path or suggested_path == "Uncategorized"
                ):
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
                # For PDFs, use document categories rather than filename
                if is_pdf:
                    return "Documents/General"

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
            if name.lower().endswith(".pdf"):
                return "Documents/General"
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


async def get_path_suggestion_for_folder(
    folder_name: str,
    folder_content: str,
    directory_structure: str,
) -> str:
    """
    Get a path suggestion for a folder using the configured LLM service (Ollama).
    Uses a specialized prompt for folder organization.
    """
    try:
        FOLDER_SYSTEM_PROMPT = """
        You are an AI assistant specializing in knowledge management and folder organization. Your job is to intelligently categorize folders based on their content and name, placing them into a meaningful directory structure.

        IMPORTANT: Your task is to analyze a folder's name and contents, then suggest the best directory path for it in the Archive. Think carefully about the most meaningful category for this folder based on its content.

        For example:
        - A folder named "Vacation Photos" containing image files from Hawaii should go in "Travel/Hawaii" or "Photos/Vacations/Hawaii"
        - A folder named "Financials 2023" with spreadsheets should go in "Finance/2023" or "Documents/Financial/2023"
        - A folder named "Project X" with code files should go in "Projects/Development" or "Work/Programming/ProjectX"

        To make your suggestion, output the directory path starting with <suggestedpath>, for example:
        <suggestedpath>Work/Projects/Research</suggestedpath>

        Rules:
        1. ANALYZE both the folder name AND its contents carefully to determine the best category
        2. DO NOT simply repeat the folder name or put it in a generic "Folders" directory
        3. Place the folder in a MEANINGFUL CATEGORY based on what it contains
        4. Create logical category hierarchies (up to 2-3 levels deep) that reflect real-world organization
        5. The folder name itself will be added automatically, so DO NOT include it in your path
        6. NEVER suggest just "Archive" or a top-level directory only
        7. If the folder contains mixed content, categorize it based on the predominant theme

        Input variables:
        <folder-name>
        {{name}}
        </folder-name>
        <content>
        {{content}}
        </content>
        <directory>
        {{directory}}
        </directory>
        """

        # Pre-process the folder content to highlight key information
        processed_content = folder_content
        if folder_content and len(folder_content) > 50:
            # Add an analysis hint if we have sufficient content
            processed_content += "\n\nPlease analyze both the folder name and its contents to determine the most appropriate category."

        # Generate the prompt with the enhanced content
        prompt = f"""
        {FOLDER_SYSTEM_PROMPT}
        
        <folder-name>
        {folder_name}
        </folder-name>
        <content>
        {processed_content}
        </content>
        <directory>
        {directory_structure}
        </directory>
        
        Remember to suggest a MEANINGFUL CATEGORY PATH, not just repeat the folder name or use a generic location.
        """

        response = requests.post(
            f"{settings.OLLAMA_BASE_URL}/api/generate",
            json={
                "model": settings.OLLAMA_MODEL,
                "prompt": prompt,
                "stream": False,
                "options": {
                    "temperature": 0.2,  # Slight increase in creativity for better categorization
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

            logging.info(
                f"Raw LLM suggestion for folder '{folder_name}': {suggested_path}"
            )

            # Check if the suggestion is meaningful
            if (
                not suggested_path
                or suggested_path == "Uncategorized"
                or suggested_path == "Archive"
                or suggested_path == "/"
                or suggested_path == "General"
                or suggested_path == "Folders"
                or suggested_path == "Folders/General"
            ):

                logging.warning(
                    f"LLM provided generic path '{suggested_path}' for folder '{folder_name}', attempting to improve"
                )

                # Try to extract meaningful categories from the folder_name
                folder_keywords = (
                    folder_name.replace("_", " ").replace("-", " ").lower().split()
                )

                # Map common keywords to categories
                keyword_to_category = {
                    "photo": "Photos",
                    "photos": "Photos",
                    "image": "Photos",
                    "images": "Photos",
                    "picture": "Photos",
                    "pictures": "Photos",
                    "doc": "Documents",
                    "docs": "Documents",
                    "document": "Documents",
                    "documents": "Documents",
                    "finance": "Finance",
                    "financial": "Finance",
                    "bank": "Finance",
                    "tax": "Finance/Taxes",
                    "taxes": "Finance/Taxes",
                    "receipt": "Finance/Receipts",
                    "receipts": "Finance/Receipts",
                    "invoice": "Finance/Invoices",
                    "invoices": "Finance/Invoices",
                    "project": "Projects",
                    "projects": "Projects",
                    "work": "Work",
                    "personal": "Personal",
                    "travel": "Travel",
                    "vacation": "Travel/Vacations",
                    "trip": "Travel",
                    "school": "Education",
                    "college": "Education",
                    "university": "Education",
                    "course": "Education/Courses",
                    "class": "Education/Courses",
                    "code": "Development",
                    "programming": "Development",
                    "software": "Development",
                    "app": "Development/Apps",
                    "recipe": "Recipes",
                    "recipes": "Recipes",
                    "food": "Food",
                    "health": "Health",
                    "medical": "Health/Medical",
                    "fitness": "Health/Fitness",
                    "workout": "Health/Fitness",
                    "book": "Books",
                    "books": "Books",
                    "music": "Music",
                    "song": "Music",
                    "video": "Videos",
                    "movie": "Videos/Movies",
                    "movies": "Videos/Movies",
                    "show": "Videos/TV",
                    "tv": "Videos/TV",
                    "series": "Videos/TV",
                    "home": "Home",
                    "house": "Home",
                    "apartment": "Home",
                    "furniture": "Home/Furniture",
                    "decoration": "Home/Decoration",
                    "garden": "Home/Garden",
                    "car": "Vehicles/Cars",
                    "vehicle": "Vehicles",
                    "art": "Art",
                    "design": "Design",
                    "presentation": "Presentations",
                    "slideshow": "Presentations",
                    "slide": "Presentations",
                    "meeting": "Work/Meetings",
                    "report": "Work/Reports",
                    "family": "Personal/Family",
                    "kid": "Personal/Family",
                    "children": "Personal/Family",
                    "event": "Events",
                }

                # Check if any keywords match categories
                for keyword in folder_keywords:
                    if keyword in keyword_to_category:
                        suggested_path = keyword_to_category[keyword]
                        logging.info(
                            f"Improved path based on keyword '{keyword}': {suggested_path}"
                        )
                        break

                # If still no good suggestion, analyze content for common file types
                if not suggested_path or suggested_path in [
                    "Uncategorized",
                    "Archive",
                    "/",
                    "General",
                    "Folders",
                    "Folders/General",
                ]:
                    # Look for file extensions in the content
                    if "pdf" in folder_content.lower():
                        suggested_path = "Documents"
                    elif any(
                        ext in folder_content.lower()
                        for ext in [".jpg", ".jpeg", ".png", ".gif"]
                    ):
                        suggested_path = "Photos"
                    elif any(
                        ext in folder_content.lower()
                        for ext in [".doc", ".docx", ".txt"]
                    ):
                        suggested_path = "Documents"
                    elif any(
                        ext in folder_content.lower()
                        for ext in [".xls", ".xlsx", ".csv"]
                    ):
                        suggested_path = "Data"
                    elif any(
                        ext in folder_content.lower()
                        for ext in [".mp3", ".wav", ".flac"]
                    ):
                        suggested_path = "Music"
                    elif any(
                        ext in folder_content.lower()
                        for ext in [".mp4", ".mov", ".avi"]
                    ):
                        suggested_path = "Videos"
                    elif any(
                        ext in folder_content.lower()
                        for ext in [".py", ".js", ".java", ".html", ".css"]
                    ):
                        suggested_path = "Development"
                    else:
                        # Last resort - use capitalized folder name as category
                        suggested_path = (
                            folder_name.replace("_", " ").replace("-", " ").title()
                        )

                logging.info(
                    f"Final fallback path for folder '{folder_name}': {suggested_path}"
                )

            # Ensure the path doesn't end with the folder name (we'll add that later)
            if suggested_path.endswith(folder_name):
                suggested_path = suggested_path[: -len(folder_name)].rstrip("/")

            # Ensure the path doesn't end with a file extension
            if "." in suggested_path.split("/")[-1]:
                suggested_path = os.path.dirname(suggested_path)

            # Remove trailing slashes
            suggested_path = suggested_path.rstrip("/")

            # Make sure we're not returning an empty path
            if not suggested_path:
                suggested_path = "Documents"

            logging.info(
                f"Final processed path for folder '{folder_name}': {suggested_path}"
            )
            return suggested_path
        else:
            logging.error(
                f"Failed to get folder suggestion from Ollama: {response.text}"
            )
            return "Documents"
    except Exception as e:
        logging.error(f"Error getting path suggestion for folder: {str(e)}")
        return "Documents"
