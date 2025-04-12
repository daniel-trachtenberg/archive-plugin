from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from config import settings
from endpoints import router
import asyncio
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
import utils
import os
import logging
from datetime import datetime
import threading
import requests
import contextlib
from contextlib import asynccontextmanager

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(os.path.join(settings.ARCHIVE_DIR, "archive_log.log")),
    ],
)


# Create a context manager for lifespan events
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Handle startup and shutdown events"""
    try:
        # Create a background thread to run the event loop for handling file events
        event_handler = InputDirectoryHandler()
        observer = Observer()
        observer.schedule(event_handler, path=settings.INPUT_DIR, recursive=False)

        # Start file watching thread
        threading.Thread(
            target=_run_observer_with_event_loop,
            args=(observer, event_handler.loop),
            daemon=True,
        ).start()

        logging.info(f"File watcher started for input directory: {settings.INPUT_DIR}")
        logging.info(f"Files will be organized and stored in: {settings.ARCHIVE_DIR}")
    except Exception as e:
        logging.error(f"Failed to start file watcher: {str(e)}")

    yield  # This is where the app runs

    # Shutdown logic if needed


# Update the FastAPI instance to use the lifespan
app = FastAPI(title=settings.APP_TITLE, lifespan=lifespan)

# CORS middleware setup
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(router)


class InputDirectoryHandler(FileSystemEventHandler):
    def __init__(self):
        self.loop = asyncio.new_event_loop()
        self.processing_files = set()

    def on_created(self, event):
        if event.is_directory:
            return

        file_path = event.src_path

        # Avoid processing temporary files
        if (
            file_path.endswith(".tmp")
            or file_path.endswith(".crdownload")
            or os.path.basename(file_path).startswith(".")
        ):
            return

        # Check if we're already processing this file
        if file_path in self.processing_files:
            return

        # Give the system a moment to finish writing the file
        self._process_file_after_delay(file_path)

    def _process_file_after_delay(self, file_path):
        """Wait before processing to ensure file is complete"""
        threading.Thread(target=self._delayed_process, args=(file_path,)).start()

    def _delayed_process(self, file_path):
        """Process the file after a short delay"""
        try:
            self.processing_files.add(file_path)

            # Wait for file to be fully written
            initial_size = -1
            current_size = os.path.getsize(file_path)

            # Wait until the file size stops changing
            while initial_size != current_size:
                initial_size = current_size
                # Wait a bit and check again
                asyncio.run_coroutine_threadsafe(asyncio.sleep(2), self.loop)
                if os.path.exists(file_path):  # File might be deleted
                    current_size = os.path.getsize(file_path)
                else:
                    return

            # Now process the file
            filename = os.path.basename(file_path)

            with open(file_path, "rb") as f:
                content = f.read()

            # Process based on file type
            if filename.lower().endswith((".pdf", ".txt", ".pptx")):
                asyncio.run_coroutine_threadsafe(
                    utils.process_document(filename=filename, content=content),
                    self.loop,
                )
            elif filename.lower().endswith((".jpg", ".jpeg", ".png", ".gif", ".webp")):
                asyncio.run_coroutine_threadsafe(
                    utils.process_image(filename=filename, content=content), self.loop
                )

            # Delete the original file after processing
            if os.path.exists(file_path):
                os.remove(file_path)

            logging.info(f"Processed and archived file: {filename}")

        except Exception as e:
            logging.error(f"Error processing file {file_path}: {str(e)}")
        finally:
            if file_path in self.processing_files:
                self.processing_files.remove(file_path)


def _run_observer_with_event_loop(observer, loop):
    """Run the observer with the event loop in a separate thread"""
    asyncio.set_event_loop(loop)
    observer.start()
    try:
        # Keep the loop running
        loop.run_forever()
    except Exception as e:
        logging.error(f"Error in observer thread: {str(e)}")
    finally:
        observer.stop()
        observer.join()


@app.get("/health")
async def health_check():
    # Check if input and archive directories exist
    input_exists = os.path.exists(settings.INPUT_DIR)
    archive_exists = os.path.exists(settings.ARCHIVE_DIR)

    # Check if Ollama is running
    ollama_status = "unknown"
    try:
        response = requests.get(f"{settings.OLLAMA_BASE_URL}", timeout=2)
        ollama_status = "running" if response.status_code == 200 else "error"
    except:
        ollama_status = "not_running"

    return {
        "status": (
            "ok"
            if input_exists and archive_exists and ollama_status == "running"
            else "warning"
        ),
        "input_dir": {"path": settings.INPUT_DIR, "exists": input_exists},
        "archive_dir": {"path": settings.ARCHIVE_DIR, "exists": archive_exists},
        "ollama": ollama_status,
        "timestamp": datetime.now().isoformat(),
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=settings.HOST, port=settings.PORT)
