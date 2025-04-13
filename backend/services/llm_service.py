import requests
import logging
import re
import json
import os
from config import settings
from services import image_analysis_service


class LLMService:
    SYSTEM_PROMPT = """
    YOU MUST ONLY RESPOND WITH A PATH. NO OTHER TEXT.
    
    Format your response EXACTLY like this:
    <suggestedpath>path/goes/here</suggestedpath>
    
    Given a file and its content, suggest where to put it in a directory structure.
    Consider:
    - Content is most important for categorization
    - File type (e.g., .txt, .jpg, .pdf)
    - Existing directories
    
    DO NOT SAY ANYTHING ELSE. DO NOT EXPLAIN. ONLY PROVIDE THE PATH IN THE FORMAT SHOWN.
    
    <suggestedpath>path/goes/here</suggestedpath>
    
    Input variables:
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
            is_docx = name.lower().endswith(".docx") or name.lower().endswith(".doc")

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
                # For docx files, prioritize headers, titles, and important paragraphs
                elif is_docx:
                    # Look for potential headers or section markers in the document
                    paragraphs = content.split("\n\n")
                    intro_content = content[
                        :500
                    ]  # First 500 chars often has title/intro

                    # Check for document metadata in the content
                    title_match = re.search(r"Title:\s*(.*?)(\n|$)", content)
                    subject_match = re.search(r"Subject:\s*(.*?)(\n|$)", content)
                    keywords_match = re.search(r"Keywords:\s*(.*?)(\n|$)", content)

                    metadata = []
                    if title_match:
                        metadata.append(f"Document Title: {title_match.group(1)}")
                    if subject_match:
                        metadata.append(f"Document Subject: {subject_match.group(1)}")
                    if keywords_match:
                        metadata.append(f"Document Keywords: {keywords_match.group(1)}")

                    # Add metadata to the beginning of processed content
                    intro_with_metadata = (
                        "\n".join(metadata) + "\n\n" + intro_content
                        if metadata
                        else intro_content
                    )

                    # More aggressive pattern to find headers in DOCX content
                    potential_headers = re.findall(
                        r"(?:^|\n)(?:[A-Z][A-Za-z\s]{2,50}:?|[0-9]+\.?\s+[A-Za-z\s]{2,50}|[IVX]+\.\s+[A-Za-z\s]{2,50})(?:\n|$)",
                        content,
                    )

                    # Create a summary of the document
                    main_sections = []
                    chars_remaining = content_limit - len(intro_with_metadata)

                    # Important section keywords to prioritize - expanded list
                    important_section_keywords = [
                        "introduction",
                        "abstract",
                        "summary",
                        "conclusion",
                        "results",
                        "findings",
                        "discussion",
                        "methodology",
                        "background",
                        "references",
                        "appendix",
                        "overview",
                        "purpose",
                        "objective",
                        "goal",
                        "scope",
                        "problem",
                        "solution",
                        "analysis",
                        "recommendation",
                        "executive",
                        "implementation",
                        "evaluation",
                        "assessment",
                        "review",
                        "chapter",
                        "section",
                        "part",
                        "content",
                        "table of contents",
                        "summary",
                    ]

                    # If we found headers, extract content from important sections
                    if potential_headers and len(potential_headers) > 1:
                        for header in potential_headers[
                            :10
                        ]:  # Check first 10 potential headers
                            header_text = header.strip().lower()
                            header_start = content.find(header)

                            if header_start > 0 and (
                                any(
                                    keyword in header_text
                                    for keyword in important_section_keywords
                                )
                                or len(header_text)
                                < 30  # Shorter headers are likely more important
                            ):
                                # Find the next header or take up to 500 chars
                                next_header_idx = potential_headers.index(header) + 1
                                if next_header_idx < len(potential_headers):
                                    next_header = potential_headers[next_header_idx]
                                    next_header_start = content.find(next_header)
                                    section_content = content[
                                        header_start : min(
                                            header_start + 500, next_header_start
                                        )
                                    ]
                                else:
                                    section_content = content[
                                        header_start : header_start + 500
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

                    # If we couldn't find good headers or need more content, sample paragraphs
                    if not main_sections or chars_remaining > 1000:
                        # Sample some paragraphs throughout the document
                        if paragraphs:
                            # Always include first paragraph (often contains title/summary)
                            if paragraphs[0] and chars_remaining > len(paragraphs[0]):
                                main_sections.append(paragraphs[0])
                                chars_remaining -= len(paragraphs[0])

                            # Sample paragraphs from different parts of the document
                            if len(paragraphs) > 5:
                                sample_indices = [
                                    1,  # Second paragraph
                                    len(paragraphs) // 4,  # 25% through
                                    len(paragraphs) // 2,  # Middle
                                    (3 * len(paragraphs)) // 4,  # 75% through
                                    len(paragraphs)
                                    - 1,  # Last paragraph (often conclusion)
                                ]

                                for idx in sample_indices:
                                    if chars_remaining <= 0:
                                        break

                                    paragraph = paragraphs[idx]
                                    if len(paragraph) > 0:
                                        if chars_remaining >= len(paragraph):
                                            main_sections.append(paragraph)
                                            chars_remaining -= len(paragraph)
                                        else:
                                            main_sections.append(
                                                paragraph[:chars_remaining]
                                            )
                                            chars_remaining = 0
                                            break

                    # Construct processed content
                    if main_sections:
                        processed_content = (
                            intro_with_metadata + "\n\n" + "\n\n".join(main_sections)
                        )
                    else:
                        # If we couldn't extract meaningful sections, sample throughout document
                        chunks = []
                        total_chunks = 6  # Take samples from 6 different parts
                        chunk_size = content_limit // total_chunks

                        for i in range(total_chunks):
                            start_pos = i * (len(content) // total_chunks)
                            chunks.append(content[start_pos : start_pos + chunk_size])

                        processed_content = (
                            intro_with_metadata + "\n...\n" + "\n...\n".join(chunks)
                        )
                else:
                    # For other file types, just take beginning and end with a note in between
                    start_content = content[: content_limit // 2]
                    end_content = content[-content_limit // 2 :]
                    processed_content = (
                        f"{start_content}\n...[content truncated]...\n{end_content}"
                    )

            # Add an instruction for PDFs, DOCXs, and pptx to emphasize content analysis
            content_hint = ""
            if is_pdf:
                content_hint = "\nIMPORTANT: This is a PDF document. Please analyze its CONTENT carefully to categorize it, rather than relying on the filename."
            elif is_docx:
                content_hint = "\nIMPORTANT: This is a Word document. Please analyze its CONTENT carefully to determine a meaningful category. Focus on the document topic, subject matter, and key themes rather than the filename. Please suggest a specific folder path based on what the document is about, not just 'General'."

            prompt = f"""
            {LLMService.SYSTEM_PROMPT}
            
            <file-name>
            {name}
            </file-name>
            <content>
            {processed_content}{content_hint}
            </content>
            <directory>
            {directory_structure}
            </directory>
            
            RESPOND ONLY WITH: <suggestedpath>path/goes/here</suggestedpath>
            NO EXPLANATIONS - JUST THE PATH. YOU WILL BE FIRED IF YOU PROVIDE ANYTHING BUT THE PATH.
            """

            response = requests.post(
                f"{settings.OLLAMA_BASE_URL}/api/generate",
                json={
                    "model": settings.OLLAMA_MODEL,
                    "prompt": prompt,
                    "stream": False,
                    "options": {
                        "temperature": 0.0,
                        "num_predict": 60,  # Limit response length to avoid long explanations
                    },
                },
                timeout=60,
            )

            if response.status_code == 200:
                result = response.json()

                # Print the raw response from Ollama
                print(f"Raw Ollama response: {result.get('response', '')}")

                # Try to find the properly formatted tag first
                match = re.search(
                    r"<suggestedpath>(.*?)</suggestedpath>",
                    result.get("response", ""),
                )

                if match:
                    suggested_path = match.group(1)
                    logging.info(f"Found path in tags: {suggested_path}")
                else:
                    # The LLM is not properly wrapping the path in tags or is providing explanations
                    logging.warning("LLM response did not include properly tagged path")
                    response_text = result.get("response", "").strip()

                    if response_text:
                        # First try to extract just the path by aggressive cleaning:
                        # 1. First try to detect if there's a proper directory path in the response
                        path_patterns = [
                            # Match paths like "Documents/Work", "Finance/Taxes/2023", etc.
                            r"([A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)+)",
                            # Match single directories like "Documents", "Finance", etc.
                            r"\b(Documents|Finance|Photos|Projects|Education|Work|Research|Personal|Travel|Media|Videos|Music)\b",
                            # Match something that looks like a folder path
                            r"([A-Za-z0-9_-]+/[A-Za-z0-9_-]+)",
                        ]

                        path_found = False
                        for pattern in path_patterns:
                            path_match = re.search(pattern, response_text)
                            if path_match:
                                suggested_path = path_match.group(1)
                                logging.info(
                                    f"Extracted path using pattern: {suggested_path}"
                                )
                                path_found = True
                                break

                        if not path_found:
                            # Try splitting by lines and taking a short line that might be a path
                            lines = [
                                line.strip()
                                for line in response_text.split("\n")
                                if line.strip()
                            ]
                            for line in lines:
                                if len(line.split()) <= 3 and "/" in line:
                                    suggested_path = line
                                    logging.info(
                                        f"Extracted path from short line: {suggested_path}"
                                    )
                                    path_found = True
                                    break

                        if not path_found:
                            # Last resort: clean the text aggressively and take the first word as a category
                            # Remove common explanatory phrases
                            for phrase in [
                                "I would suggest",
                                "I recommend",
                                "should be placed in",
                                "would fit best in",
                                "belongs in",
                                "should go in",
                                "appropriate path would be",
                                "suitable location is",
                            ]:
                                if phrase.lower() in response_text.lower():
                                    parts = response_text.lower().split(
                                        phrase.lower(), 1
                                    )
                                    if len(parts) > 1 and parts[1].strip():
                                        # Take the text after the phrase
                                        cleaned = parts[1].strip()
                                        # Take first word that could be a category
                                        first_word = cleaned.split()[0].strip(",.;:\"'")
                                        if first_word and len(first_word) > 1:
                                            suggested_path = first_word
                                            logging.info(
                                                f"Extracted category from phrase: {suggested_path}"
                                            )
                                            path_found = True
                                            break

                        if not path_found:
                            # First check if the response is just a simple path without tags
                            if (
                                "/" in response_text
                                and len(response_text.split()) <= 3
                                and not response_text.startswith("I ")
                            ):
                                potential_path = response_text.strip()
                                if len(potential_path) < 100:  # Reasonable path length
                                    suggested_path = potential_path
                                    logging.info(
                                        f"Using simple path from response: {suggested_path}"
                                    )
                                else:
                                    # Path too long, likely not a real path
                                    suggested_path = ""
                            else:
                                # Try to find a reasonable short directory name in the response
                                # First look for common directory words like "Documents/", "Education/", etc.
                                dir_pattern = re.search(
                                    r"(Documents|Education|School|Research|Projects|Academic|Classes|Finance|Photos|Work)/\w+",
                                    response_text,
                                )
                                if dir_pattern:
                                    suggested_path = dir_pattern.group(0)
                                    logging.info(
                                        f"Extracted directory pattern: {suggested_path}"
                                    )
                                else:
                                    # Just take the first word that's reasonably long as a category
                                    words = [
                                        w
                                        for w in response_text.split()
                                        if len(w) > 3 and w.isalpha()
                                    ]
                                    if words:
                                        suggested_path = words[0]
                                        logging.info(
                                            f"Using first significant word as category: {suggested_path}"
                                        )
                                    else:
                                        suggested_path = ""
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
                            r"report|analysis|research": "Reports",
                            r"contract|agreement|legal": "Legal",
                            r"manual|guide|instructions": "Manuals",
                            r"certificate|diploma|degree": "Certificates",
                            r"letter|correspondence": "Correspondence",
                            r"article|journal|publication": "Articles",
                            r"resume|cv|curriculum": "Resumes",
                            r"meeting|minutes|agenda": "Meetings",
                            r"proposal|plan|strategy": "Proposals",
                        }

                        # Check content against patterns
                        for pattern, category in document_type_patterns.items():
                            if re.search(pattern, content.lower()):
                                suggested_path = category
                                break

                        # If still no match, ask LLM for a meaningful category
                        if not suggested_path or suggested_path == "Uncategorized":
                            suggested_path = "General"
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
                # For PDFs and DOCX files, use document categories rather than filename
                if is_pdf:
                    return "General"
                elif is_docx:
                    # Try to extract a topic from content before falling back to the filename
                    # Look for potential titles or headings in the first few paragraphs
                    first_lines = content.split("\n\n")[:5]  # First 5 paragraphs
                    potential_topics = []

                    for line in first_lines:
                        line = line.strip()
                        # Skip empty lines or very long paragraphs (unlikely to be titles)
                        if not line or len(line) > 100:
                            continue
                        # Look for lines that might be titles (Title case, all caps, etc.)
                        if (
                            line.istitle()
                            or line.isupper()
                            or line.startswith("Title:")
                            or re.match(r"^[A-Z][a-z]+(\s+[A-Z][a-z]+)+$", line)
                        ):
                            potential_topics.append(line)

                    if potential_topics:
                        # Use the first potential title as a topic
                        topic = potential_topics[0].replace("Title:", "").strip()
                        if len(topic) > 3:  # Ensure it's not just a short abbreviation
                            logging.info(f"Extracted topic from DOCX content: {topic}")
                            return f"Documents/{topic}"

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
                return "General"
            elif name.lower().endswith(".docx") or name.lower().endswith(".doc"):
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
            
            <file-name>
            {name}
            </file-name>
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

        # Print the raw response before any sanitization
        print(f"Raw LLM response for {filename}: {suggested_path}")

        # Sanitize the path - remove any unexpected or debug text like "This is a directory listing of"
        if suggested_path:
            # Remove any text that clearly isn't a path
            problematic_prefixes = [
                "This is a directory listing of",
                "This is a path",
                "Path:",
                "Suggested path:",
                "Directory:",
                "I suggest",
                "I would suggest",
                "I recommend",
                "Based on",
                "Given the",
                "Looking at",
                "Considering",
                "After analyzing",
                "The structure suggests",
                "The content indicates",
            ]
            for prefix in problematic_prefixes:
                if suggested_path.lower().startswith(prefix.lower()):
                    suggested_path = suggested_path[len(prefix) :].strip()
                    logging.warning(f"Removed problematic prefix from path: {prefix}")

            # Check for explanatory paragraph with the actual path inside
            if (
                len(suggested_path.split()) > 5
            ):  # More than 5 words suggests explanatory text
                # Try to find a path-like part (containing slash)
                path_parts = [p for p in suggested_path.split() if "/" in p]
                if path_parts:
                    # Take the first path-like segment
                    suggested_path = path_parts[0].strip(",.:;\"'")
                    logging.warning(
                        f"Extracted path from explanatory text: {suggested_path}"
                    )
                else:
                    # Try to pick out directory names
                    known_directories = [
                        "Documents",
                        "Photos",
                        "Music",
                        "Videos",
                        "Education",
                        "Work",
                        "Projects",
                        "Finance",
                        "Personal",
                        "Travel",
                    ]
                    for directory in known_directories:
                        if directory in suggested_path:
                            # Find where the directory is mentioned and try to extract a path
                            idx = suggested_path.find(directory)
                            # Extract a reasonable length substring starting with directory
                            potential_path = suggested_path[idx : idx + 50].split()[0]
                            if potential_path and len(potential_path) > 0:
                                suggested_path = potential_path
                                logging.warning(
                                    f"Extracted directory name from text: {suggested_path}"
                                )
                                break

            # If the path contains unexpected characters, log and fix
            if not all(c.isalnum() or c in "/_-. " for c in suggested_path):
                logging.warning(f"Suspicious characters in path: {suggested_path}")
                # Keep only valid path characters
                clean_path = "".join(
                    c for c in suggested_path if c.isalnum() or c in "/_-. "
                )
                logging.info(
                    f"Sanitized path from '{suggested_path}' to '{clean_path}'"
                )
                suggested_path = clean_path

        # Ensure we don't return an empty path or just "Uncategorized"
        if not suggested_path or suggested_path == "Uncategorized":
            # Extract topic from filename
            filename_without_ext = os.path.splitext(filename)[0]
            topic = filename_without_ext.replace("_", " ").replace("-", " ").title()

            # Check for course codes like "CS 103" in the filename
            course_match = re.search(r"([A-Z]{2,5}\s*\d{3})", filename_without_ext)
            if course_match:
                return f"Education/{course_match.group(1)}"

            if (
                topic
                and topic != "Untitled"
                and topic != "Document"
                and topic != "Image"
            ):
                # For PDF files, ensure we're returning a directory, not a filename
                if filename.lower().endswith(".pdf"):
                    if (
                        "education" in topic.lower()
                        or "course" in topic.lower()
                        or "class" in topic.lower()
                    ):
                        return f"Education/{topic}"
                    return f"Documents/{topic}"
                return topic

            # Default paths for different file types
            if filename.lower().endswith(".pdf"):
                return "Documents/General"
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
        YOU MUST ONLY RESPOND WITH A PATH. NO OTHER TEXT.
        
        Format your response EXACTLY like this:
        <suggestedpath>path/goes/here</suggestedpath>
        
        Given a folder and its contents, suggest the best directory for it.
        Consider:
        - Folder content is most important
        - Folder name
        - Existing directories
        
        DO NOT include the folder name in your path.
        DO NOT explain your reasoning.
        ONLY respond with the path in tags.
        
        <suggestedpath>path/goes/here</suggestedpath>
        
        Input variables:
        """

        # Pre-process the folder content to highlight key information
        processed_content = folder_content
        if folder_content and len(folder_content) > 50:
            # Add an analysis hint if we have sufficient content
            processed_content += "\n\nPlease suggest a path for this folder."

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
        
        RESPOND ONLY WITH: <suggestedpath>path/goes/here</suggestedpath>
        NO EXPLANATIONS - JUST THE PATH. YOU WILL BE FIRED IF YOU PROVIDE ANYTHING BUT THE PATH.
        """

        response = requests.post(
            f"{settings.OLLAMA_BASE_URL}/api/generate",
            json={
                "model": settings.OLLAMA_MODEL,
                "prompt": prompt,
                "stream": False,
                "options": {
                    "temperature": 0.0,
                    "num_predict": 60,  # Limit response length to avoid long explanations
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

            # If no match found or it's empty, try to extract just a path without tags
            if not suggested_path:
                response_text = result.get("response", "").strip()

                # First try to extract just the path by aggressive cleaning
                path_patterns = [
                    # Match paths like "Documents/Work", "Finance/Taxes/2023", etc.
                    r"([A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)+)",
                    # Match single directories like "Documents", "Finance", etc.
                    r"\b(Documents|Finance|Photos|Projects|Education|Work|Research|Personal|Travel|Media|Videos|Music)\b",
                    # Match something that looks like a folder path
                    r"([A-Za-z0-9_-]+/[A-Za-z0-9_-]+)",
                ]

                path_found = False
                for pattern in path_patterns:
                    path_match = re.search(pattern, response_text)
                    if path_match:
                        suggested_path = path_match.group(1)
                        logging.info(
                            f"Extracted folder path using pattern: {suggested_path}"
                        )
                        path_found = True
                        break

                if not path_found:
                    # Try splitting by lines and taking a short line that might be a path
                    lines = [
                        line.strip()
                        for line in response_text.split("\n")
                        if line.strip()
                    ]
                    for line in lines:
                        if len(line.split()) <= 3 and (
                            "/" in line
                            or any(
                                word in line
                                for word in ["Documents", "Photos", "Finance"]
                            )
                        ):
                            suggested_path = line
                            logging.info(
                                f"Extracted folder path from short line: {suggested_path}"
                            )
                            path_found = True
                            break

                if not path_found:
                    # Last resort: clean the text aggressively and take the first word as a category
                    # Remove common explanatory phrases
                    for phrase in [
                        "I would suggest",
                        "I recommend",
                        "should be placed in",
                        "would fit best in",
                        "belongs in",
                        "should go in",
                        "appropriate path would be",
                        "suitable location is",
                    ]:
                        if phrase.lower() in response_text.lower():
                            parts = response_text.lower().split(phrase.lower(), 1)
                            if len(parts) > 1 and parts[1].strip():
                                # Take the text after the phrase
                                cleaned = parts[1].strip()
                                # Take first word that could be a category
                                first_word = cleaned.split()[0].strip(",.;:\"'")
                                if first_word and len(first_word) > 1:
                                    suggested_path = first_word
                                    logging.info(
                                        f"Extracted folder category from phrase: {suggested_path}"
                                    )
                                    path_found = True
                                    break

                if (
                    not path_found
                    and "/" in response_text
                    and len(response_text.split()) <= 3
                ):
                    # This might be a simple path without tags
                    potential_path = response_text.strip()
                    if len(potential_path) < 100:  # Reasonable path length
                        suggested_path = potential_path
                        logging.info(
                            f"Using simple folder path from response: {suggested_path}"
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
