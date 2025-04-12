from fastapi import (
    APIRouter,
    File,
    UploadFile,
    HTTPException,
    Query,
)
from fastapi.responses import FileResponse
import services.filesystem_service as filesystem
import services.chroma_service as chroma
import utils
import os
from config import settings

router = APIRouter()


@router.post("/upload")
async def upload_file(file: UploadFile = File(...)):
    """
    Manually upload a file to be processed and archived.
    """
    content = await file.read()
    filename_lower = file.filename.lower()
    path = None
    if filename_lower.endswith((".pdf", ".txt", ".pptx")):
        path = await utils.process_document(
            filename=file.filename,
            content=content,
        )
    elif filename_lower.endswith(("jpeg", "jpg", "png", "gif", "webp")):
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

    # Convert to full filesystem paths for easy access
    full_paths = [
        os.path.join(settings.ARCHIVE_DIR, path) for path in formatted_results
    ]

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
