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
import shutil
import time

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    handlers=[
        logging.StreamHandler(),
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
        observer.schedule(event_handler, path=settings.INPUT_DIR, recursive=True)

        # Start file watching thread
        threading.Thread(
            target=_run_observer_with_event_loop,
            args=(observer, event_handler.loop),
            daemon=True,
        ).start()

        logging.info(f"File watcher started for input directory: {settings.INPUT_DIR}")
        logging.info(f"Files will be organized and stored in: {settings.ARCHIVE_DIR}")
        logging.info(
            f"Folder monitoring enabled - folders will be processed recursively"
        )
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
        self.processing_folders = set()
        # Keep track of folders being processed to avoid processing their files
        self.folders_being_processed = set()

    def on_created(self, event):
        if event.is_directory:
            # Process folders
            folder_path = event.src_path

            # Avoid processing temporary folders or hidden folders
            if os.path.basename(folder_path).startswith("."):
                return

            # Check if we're already processing this folder
            if folder_path in self.processing_folders:
                return

            # Wait a short time to make sure the folder creation is complete
            # This helps with race conditions that might happen with folder operations
            time.sleep(1)

            # Check if the folder still exists after the delay
            if not os.path.exists(folder_path):
                logging.info(
                    f"Folder {folder_path} no longer exists, skipping processing"
                )
                return

            # Mark this folder as being processed to avoid processing its files individually
            self.folders_being_processed.add(folder_path)

            # Give the system a moment before processing the folder
            self._process_folder_after_delay(folder_path)
            return

        file_path = event.src_path
        file_dir = os.path.dirname(file_path)

        # Skip files in folders that are already being processed
        if any(
            file_path.startswith(folder) for folder in self.folders_being_processed
        ) or any(
            file_dir.startswith(folder) for folder in self.folders_being_processed
        ):
            logging.info(
                f"Skipping file {file_path} as its parent folder is being processed"
            )
            return

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

    def _process_folder_after_delay(self, folder_path):
        """Wait before processing to ensure folder creation is complete"""
        threading.Thread(
            target=self._delayed_process_folder, args=(folder_path,)
        ).start()

    def _delayed_process_folder(self, folder_path):
        """Process the folder after a short delay"""
        try:
            self.processing_folders.add(folder_path)

            # Wait a bit longer to make sure all files are copied into the folder
            # This is especially important for large folders or slow file systems
            asyncio.run_coroutine_threadsafe(asyncio.sleep(10), self.loop)

            if not os.path.exists(folder_path):
                logging.warning(
                    f"Folder {folder_path} no longer exists after delay, cannot process"
                )
                return

            folder_name = os.path.basename(folder_path)

            logging.info(f"Starting processing of folder: {folder_path}")

            # Process the folder
            future = asyncio.run_coroutine_threadsafe(
                utils.process_folder(folder_name=folder_name, folder_path=folder_path),
                self.loop,
            )

            # Wait for the processing to complete before removing the original
            try:
                result = future.result(timeout=300)  # 5 minute timeout
                if result:
                    logging.info(f"Folder processing completed successfully: {result}")

                    # Only remove the original folder after successful processing
                    if os.path.exists(folder_path):
                        try:
                            logging.info(f"Removing original folder: {folder_path}")
                            shutil.rmtree(folder_path)
                            logging.info(f"Removed original folder: {folder_path}")
                        except Exception as e:
                            logging.error(
                                f"Error removing folder {folder_path}: {str(e)}"
                            )
                else:
                    logging.error(
                        f"Folder processing failed, will not remove original: {folder_path}"
                    )
            except asyncio.TimeoutError:
                logging.error(f"Folder processing timed out: {folder_path}")
            except Exception as e:
                logging.error(f"Error waiting for folder processing: {str(e)}")

            logging.info(f"Completed processing for folder: {folder_name}")

        except Exception as e:
            logging.error(f"Error processing folder {folder_path}: {str(e)}")
        finally:
            # Remove folder from being processed sets
            if folder_path in self.processing_folders:
                self.processing_folders.remove(folder_path)
            if folder_path in self.folders_being_processed:
                self.folders_being_processed.remove(folder_path)

    def _process_file_after_delay(self, file_path):
        """Wait before processing to ensure file is complete"""
        threading.Thread(target=self._delayed_process, args=(file_path,)).start()

    def _delayed_process(self, file_path):
        """Process the file after a short delay"""
        try:
            self.processing_files.add(file_path)

            # Wait for file to be fully written
            initial_size = -1
            current_size = 0

            # Check if file still exists (may have been deleted by folder processing)
            if not os.path.exists(file_path):
                logging.info(f"File no longer exists, skipping: {file_path}")
                return

            current_size = os.path.getsize(file_path)

            # Wait until the file size stops changing
            while initial_size != current_size:
                initial_size = current_size
                # Wait a bit and check again
                asyncio.run_coroutine_threadsafe(asyncio.sleep(2), self.loop)
                if os.path.exists(file_path):  # File might be deleted
                    current_size = os.path.getsize(file_path)
                else:
                    logging.info(f"File was deleted during processing: {file_path}")
                    return

            # Now process the file
            filename = os.path.basename(file_path)

            # Check again if this file's directory is being processed as a folder
            file_dir = os.path.dirname(file_path)
            if any(
                file_path.startswith(folder) for folder in self.folders_being_processed
            ) or any(
                file_dir.startswith(folder) for folder in self.folders_being_processed
            ):
                logging.info(
                    f"Skipping file {file_path} as its parent folder is now being processed"
                )
                return

            try:
                with open(file_path, "rb") as f:
                    content = f.read()
            except FileNotFoundError:
                logging.info(
                    f"File not found, may have been moved by folder processing: {file_path}"
                )
                return
            except Exception as e:
                logging.error(f"Error reading file {file_path}: {str(e)}")
                return

            # Process based on file type
            if filename.lower().endswith(
                (".pdf", ".txt", ".pptx", ".docx", ".doc", ".xlsx", ".xls")
            ):
                asyncio.run_coroutine_threadsafe(
                    utils.process_document(filename=filename, content=content),
                    self.loop,
                )
            elif filename.lower().endswith((".jpg", ".jpeg", ".png", ".gif", ".webp")):
                asyncio.run_coroutine_threadsafe(
                    utils.process_image(filename=filename, content=content),
                    self.loop,
                )

            # Delete the original file after processing
            if os.path.exists(file_path):
                try:
                    os.remove(file_path)
                    logging.info(f"Removed original file: {file_path}")
                except Exception as e:
                    logging.error(f"Error removing file {file_path}: {str(e)}")

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
