from fastapi import (
    APIRouter,
    File,
    UploadFile,
    HTTPException,
    Query,
)
import services.filesystem_service as filesystem
import services.chroma_service as chroma
import utils
import os
from config import settings
from pathlib import Path
from pydantic import BaseModel

router = APIRouter()

DOCUMENT_EXTENSIONS = (
    ".pdf",
    ".txt",
    ".md",
    ".rtf",
    ".doc",
    ".docx",
    ".ppt",
    ".pptx",
    ".xls",
    ".xlsx",
    ".csv",
)

IMAGE_EXTENSIONS = (
    ".jpeg",
    ".jpg",
    ".png",
    ".gif",
    ".webp",
    ".heic",
    ".heif",
)


# New model for directory configuration
class DirectoryConfig(BaseModel):
    input_dir: str
    archive_dir: str


@router.post("/upload")
async def upload_file(file: UploadFile = File(...)):
    """
    Manually upload a file to be processed and archived.
    """
    content = await file.read()
    filename_lower = file.filename.lower()
    path = None
    if filename_lower.endswith(DOCUMENT_EXTENSIONS):
        path = await utils.process_document(
            filename=file.filename,
            content=content,
        )
    elif filename_lower.endswith(IMAGE_EXTENSIONS):
        path = await utils.process_image(
            filename=file.filename,
            content=content,
        )
    else:
        raise HTTPException(
            status_code=400,
            detail="The provided filetype is not supported. Please upload a file with a supported extension.",
        )

    if path:
        print(f"File manually uploaded and moved to: {path}")
        return {"message": "File processed successfully", "path": path}
    else:
        raise HTTPException(status_code=500, detail="Failed to process the file.")


@router.get("/query")
async def query(
    query_text: str = Query(),
    n_results: int = Query(5),
):
    """
    Query the vector database for files matching the query text.
    Returns file paths that can be opened directly from the Archive folder.
    """
    if not query_text:
        raise HTTPException(status_code=400, detail="Query text must be provided.")

    results = chroma.query_collection(query_text=query_text, n_results=n_results)

    formatted_results = (
        results["ids"][0] if results["ids"] and results["ids"][0] else []
    )

    # Convert to full filesystem paths for easy access and drop stale entries.
    full_paths = []
    seen = set()
    for relative_path in formatted_results:
        absolute_path = os.path.join(settings.ARCHIVE_DIR, relative_path)
        if absolute_path in seen:
            continue
        if os.path.exists(absolute_path):
            full_paths.append(absolute_path)
            seen.add(absolute_path)

    return {"results": full_paths}


@router.get("/stats")
async def get_stats():
    """
    Get basic statistics about the archive.
    """
    try:
        structure = filesystem.get_directory_structure()

        # Count files and directories
        def count_items(node):
            if node["type"] == "file":
                return 1, 0

            files = 0
            dirs = 1  # Count this directory

            for child in node["children"].values():
                child_files, child_dirs = count_items(child)
                files += child_files
                dirs += child_dirs

            return files, dirs

        total_files, total_dirs = count_items(structure)

        return {
            "total_files": total_files,
            "total_directories": total_dirs,
            "input_directory": settings.INPUT_DIR,
            "archive_directory": settings.ARCHIVE_DIR,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to get stats: {str(e)}")


@router.get("/directories", response_model=DirectoryConfig)
async def get_directories():
    """
    Get the current input and archive directories.
    """
    return {"input_dir": settings.INPUT_DIR, "archive_dir": settings.ARCHIVE_DIR}


# Helper function to update .env file
def update_env_file(input_dir: str, archive_dir: str):
    """Update the .env file with new directory paths"""
    env_path = os.path.join(os.path.dirname(__file__), ".env")

    if not os.path.exists(env_path):
        # Create .env file if it doesn't exist
        with open(env_path, "w") as f:
            f.write(f"ARCHIVE_DIR={archive_dir}\n")
            f.write(f"INPUT_DIR={input_dir}\n")
        return

    # Read existing .env file
    with open(env_path, "r") as f:
        lines = f.readlines()

    # Check for existing entries
    archive_found = False
    input_found = False
    new_lines = []

    for line in lines:
        if line.strip().startswith("ARCHIVE_DIR="):
            new_lines.append(f"ARCHIVE_DIR={archive_dir}\n")
            archive_found = True
        elif line.strip().startswith("INPUT_DIR="):
            new_lines.append(f"INPUT_DIR={input_dir}\n")
            input_found = True
        else:
            new_lines.append(line)

    # Add entries if not found
    if not archive_found:
        new_lines.append(f"ARCHIVE_DIR={archive_dir}\n")
    if not input_found:
        new_lines.append(f"INPUT_DIR={input_dir}\n")

    # Write updated .env file
    with open(env_path, "w") as f:
        f.writelines(new_lines)


@router.put("/directories", response_model=DirectoryConfig)
async def update_directories(config: DirectoryConfig):
    """
    Update the input and archive directories.
    """
    try:
        # Validate if paths exist or can be created
        input_path = Path(config.input_dir)
        archive_path = Path(config.archive_dir)

        # Create directories if they don't exist
        input_path.mkdir(parents=True, exist_ok=True)
        archive_path.mkdir(parents=True, exist_ok=True)

        # Update settings
        settings.INPUT_DIR = str(input_path)
        settings.ARCHIVE_DIR = str(archive_path)

        # Also update ChromaDB directory which is based on archive directory
        settings.CHROMA_DB_DIR = os.path.join(settings.ARCHIVE_DIR, ".chromadb")
        Path(settings.CHROMA_DB_DIR).mkdir(parents=True, exist_ok=True)

        # Save settings to .env file for persistence
        update_env_file(str(input_path), str(archive_path))

        # Import the restart function here to avoid circular imports
        from main import restart_file_watcher

        # Restart the file watcher with new directory settings
        restart_file_watcher()

        return {"input_dir": settings.INPUT_DIR, "archive_dir": settings.ARCHIVE_DIR}
    except Exception as e:
        raise HTTPException(
            status_code=500, detail=f"Failed to update directories: {str(e)}"
        )


@router.post("/reconcile")
async def reconcile():
    """
    Manually trigger reconciliation between filesystem and ChromaDB.
    """
    try:
        print("\n=================================================")
        print("          MANUAL RECONCILIATION TRIGGERED        ")
        print("=================================================")

        result = await utils.reconcile_filesystem_with_chroma()

        if result:
            print("Manual reconciliation completed successfully!")
            print("=================================================\n")
            return {
                "status": "success",
                "message": "Reconciliation completed successfully",
            }
        else:
            print("ERROR: Manual reconciliation failed")
            print("=================================================\n")
            raise HTTPException(status_code=500, detail="Reconciliation failed")
    except Exception as e:
        print(f"ERROR: Manual reconciliation failed: {str(e)}")
        print("=================================================\n")
        raise HTTPException(status_code=500, detail=f"Reconciliation failed: {str(e)}")
