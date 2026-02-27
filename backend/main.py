from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from config import settings
from endpoints import router
import asyncio
from concurrent.futures import ThreadPoolExecutor
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
import utils
import os
import logging
from datetime import datetime
import threading
import requests
from contextlib import asynccontextmanager
import shutil
import time
import signal
import services.filesystem_service as filesystem
import services.chroma_service as chroma

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    handlers=[
        logging.StreamHandler(),
    ],
)

# Global variables for managing observer
global_observer = None
global_event_handler = None
global_archive_observer = None
global_archive_event_handler = None
global_observer_thread = None
global_archive_observer_thread = None
observer_lock = threading.Lock()

_reconciliation_lock = threading.Lock()
_reconciliation_timer = None
_reconciliation_pending = False
_reconciliation_running = False

_OLLAMA_HEALTH_CACHE_TTL_SECONDS = 30
_OLLAMA_HEALTH_CACHE = {
    "checked_at": 0.0,
    "status": "unknown",
}

_MANAGED_BY_APP = (
    os.getenv("ARCHIVE_MANAGED_BY_APP", "").strip().lower() in {"1", "true", "yes", "on"}
)
try:
    _MANAGED_APP_PID = int((os.getenv("ARCHIVE_APP_PID", "") or "0").strip())
except ValueError:
    _MANAGED_APP_PID = 0
_PARENT_WATCHDOG_STARTED = False

DOCUMENT_EXTENSIONS = (
    ".pdf",
    ".txt",
    ".md",
    ".rtf",
    ".ppt",
    ".pptx",
    ".doc",
    ".docx",
    ".xls",
    ".xlsx",
    ".csv",
)

IMAGE_EXTENSIONS = (".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif")


def _is_pid_alive(pid: int) -> bool:
    if pid <= 1:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _start_parent_watchdog_if_managed():
    global _PARENT_WATCHDOG_STARTED

    if _PARENT_WATCHDOG_STARTED:
        return
    if not _MANAGED_BY_APP or _MANAGED_APP_PID <= 1:
        return

    _PARENT_WATCHDOG_STARTED = True

    def _watch_parent():
        while True:
            if not _is_pid_alive(_MANAGED_APP_PID):
                logging.warning(
                    "Managed backend detected missing app parent pid=%s; exiting.",
                    _MANAGED_APP_PID,
                )
                os._exit(0)
            time.sleep(3.0)

    threading.Thread(
        target=_watch_parent,
        daemon=True,
        name="archive-parent-watchdog",
    ).start()


def _run_reconciliation_worker():
    global _reconciliation_running, _reconciliation_pending

    while True:
        with _reconciliation_lock:
            if _reconciliation_running:
                return
            if not _reconciliation_pending:
                return
            _reconciliation_pending = False
            _reconciliation_running = True

        try:
            asyncio.run(utils.reconcile_filesystem_with_chroma())
        except Exception as exc:
            logging.error("Reconciliation worker failed: %s", exc)
        finally:
            with _reconciliation_lock:
                _reconciliation_running = False
                should_rerun = _reconciliation_pending

        if not should_rerun:
            return

        # Coalesce bursts into a single follow-up run.
        time.sleep(1.0)


def schedule_reconciliation(*, reason: str = "", debounce_seconds: float = 2.0):
    global _reconciliation_timer, _reconciliation_pending

    with _reconciliation_lock:
        _reconciliation_pending = True
        if _reconciliation_timer is not None:
            _reconciliation_timer.cancel()

        def _dispatch():
            _run_reconciliation_worker()

        timer = threading.Timer(max(float(debounce_seconds), 0.0), _dispatch)
        timer.daemon = True
        _reconciliation_timer = timer
        timer.start()

    if reason:
        logging.info("Scheduled reconciliation (%s) with debounce %.1fs", reason, debounce_seconds)


def _cached_ollama_status() -> str:
    now = time.monotonic()
    last_checked = _OLLAMA_HEALTH_CACHE["checked_at"]
    if now - last_checked < _OLLAMA_HEALTH_CACHE_TTL_SECONDS:
        return _OLLAMA_HEALTH_CACHE["status"]

    status = "not_running"
    try:
        response = requests.get(f"{settings.OLLAMA_BASE_URL}", timeout=0.8)
        status = "running" if response.status_code == 200 else "error"
    except Exception:
        status = "not_running"

    _OLLAMA_HEALTH_CACHE["checked_at"] = now
    _OLLAMA_HEALTH_CACHE["status"] = status
    return status


# Function to restart file watcher with new directory
def restart_file_watcher():
    global global_observer, global_event_handler, global_archive_observer, global_archive_event_handler
    global global_observer_thread, global_archive_observer_thread

    with observer_lock:
        print("\n---------- RESTARTING FILE WATCHERS ----------")
        # Stop existing input observer if it's running
        if global_observer:
            logging.info("Stopping existing input file watcher...")
            print("Stopping input directory watcher...")
            global_observer.stop()
        if global_event_handler and global_event_handler.loop.is_running():
            global_event_handler.loop.call_soon_threadsafe(global_event_handler.loop.stop)
        if global_observer and global_observer.is_alive():
            global_observer.join(timeout=2)
            logging.info("Existing input file watcher stopped")
        if global_observer_thread and global_observer_thread.is_alive():
            global_observer_thread.join(timeout=2)
        if global_event_handler:
            global_event_handler.shutdown()

        # Update input watcher based on settings.
        if settings.WATCH_INPUT_DIR:
            event_handler = InputDirectoryHandler()
            observer = Observer()
            observer.schedule(event_handler, path=settings.INPUT_DIR, recursive=True)

            # Start the new input observer
            input_observer_thread = threading.Thread(
                target=_run_observer_with_event_loop,
                args=(observer, event_handler.loop),
                daemon=True,
            )
            input_observer_thread.start()
            print(f"Started watching input directory: {settings.INPUT_DIR}")

            # Update global references for input watcher
            global_observer = observer
            global_event_handler = event_handler
            global_observer_thread = input_observer_thread
        else:
            print("Input directory watcher is disabled in settings")
            logging.info("Input directory watcher is disabled in settings")
            global_observer = None
            global_event_handler = None
            global_observer_thread = None

        # Stop existing archive observer if it's running
        if global_archive_observer:
            logging.info("Stopping existing archive file watcher...")
            print("Stopping archive directory watcher...")
            global_archive_observer.stop()
        if global_archive_event_handler and global_archive_event_handler.loop.is_running():
            global_archive_event_handler.loop.call_soon_threadsafe(
                global_archive_event_handler.loop.stop
            )
        if global_archive_observer and global_archive_observer.is_alive():
            global_archive_observer.join(timeout=2)
            logging.info("Existing archive file watcher stopped")
        if global_archive_observer_thread and global_archive_observer_thread.is_alive():
            global_archive_observer_thread.join(timeout=2)
        if global_archive_event_handler:
            global_archive_event_handler.shutdown()

        # Create a new archive observer
        archive_event_handler = ArchiveDirectoryHandler()
        archive_observer = Observer()
        archive_observer.schedule(
            archive_event_handler, path=settings.ARCHIVE_DIR, recursive=True
        )

        # Start the new archive observer
        archive_observer_thread = threading.Thread(
            target=_run_observer_with_event_loop,
            args=(archive_observer, archive_event_handler.loop),
            daemon=True,
        )
        archive_observer_thread.start()
        print(f"Started watching archive directory: {settings.ARCHIVE_DIR}")

        # Update global references for archive watcher
        global_archive_observer = archive_observer
        global_archive_event_handler = archive_event_handler
        global_archive_observer_thread = archive_observer_thread

        print("File watchers restarted successfully")
        print("---------------------------------------------\n")

        logging.info(
            (
                f"File watchers restarted. Input: {settings.INPUT_DIR} "
                f"(enabled={settings.WATCH_INPUT_DIR}), Archive: {settings.ARCHIVE_DIR}"
            )
        )


# Create a context manager for lifespan events
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Handle startup and shutdown events"""
    global global_observer, global_event_handler, global_archive_observer, global_archive_event_handler
    global global_observer_thread, global_archive_observer_thread

    try:
        print("\n=================================================")
        print("          STARTING ARCHIVE PLUGIN SERVER         ")
        print("=================================================")
        _start_parent_watchdog_if_managed()

        # Start the file watchers
        print("\nInitializing file watchers...")
        restart_file_watcher()
        print(f"Input directory: {settings.INPUT_DIR}")
        print(f"Input watcher enabled: {settings.WATCH_INPUT_DIR}")
        print(f"Archive directory: {settings.ARCHIVE_DIR}")

        # Run a debounced reconciliation on startup.
        print("\nStarting database reconciliation process...")
        print("This will ensure ChromaDB and the filesystem are in sync.")
        print("See details below:\n")
        schedule_reconciliation(reason="startup", debounce_seconds=0.5)

        print("\nServer ready! Monitoring for file changes...")
        print("=================================================\n")

    except Exception as e:
        logging.error(f"Failed to start file watchers or reconciliation: {str(e)}")
        print(f"ERROR: Failed to start system: {str(e)}")

    yield  # This is where the app runs

    # Shutdown logic
    print("\n=================================================")
    print("          SHUTTING DOWN ARCHIVE PLUGIN           ")
    print("=================================================")

    with observer_lock:
        if global_observer:
            logging.info("Stopping input file watcher...")
            print("Stopping input directory watcher...")
            global_observer.stop()
        if global_event_handler and global_event_handler.loop.is_running():
            global_event_handler.loop.call_soon_threadsafe(global_event_handler.loop.stop)
        if global_observer and global_observer.is_alive():
            global_observer.join(timeout=2)
            logging.info("Input file watcher stopped")
        if global_observer_thread and global_observer_thread.is_alive():
            global_observer_thread.join(timeout=2)
        if global_event_handler:
            global_event_handler.shutdown()

        if global_archive_observer:
            logging.info("Stopping archive file watcher...")
            print("Stopping archive directory watcher...")
            global_archive_observer.stop()
        if global_archive_event_handler and global_archive_event_handler.loop.is_running():
            global_archive_event_handler.loop.call_soon_threadsafe(
                global_archive_event_handler.loop.stop
            )
        if global_archive_observer and global_archive_observer.is_alive():
            global_archive_observer.join(timeout=2)
            logging.info("Archive file watcher stopped")
        if global_archive_observer_thread and global_archive_observer_thread.is_alive():
            global_archive_observer_thread.join(timeout=2)
        if global_archive_event_handler:
            global_archive_event_handler.shutdown()

    print("Server shutdown complete.")
    print("=================================================\n")


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
        self.state_lock = threading.Lock()
        self.worker_pool = ThreadPoolExecutor(
            max_workers=3,
            thread_name_prefix="archive-input-worker",
        )

    def shutdown(self):
        try:
            self.worker_pool.shutdown(wait=False, cancel_futures=True)
        except Exception as exc:
            logging.error("Failed shutting down input worker pool: %s", exc)

    def _is_folder_in_progress_for_path(self, file_path: str, file_dir: str) -> bool:
        with self.state_lock:
            in_progress_folders = tuple(self.folders_being_processed)
        return any(
            file_path.startswith(folder) or file_dir.startswith(folder)
            for folder in in_progress_folders
        )

    def on_created(self, event):
        if event.is_directory:
            # Process folders
            folder_path = event.src_path

            # Avoid processing temporary folders or hidden folders
            if os.path.basename(folder_path).startswith("."):
                return

            # Check if we're already processing this folder
            with self.state_lock:
                if (
                    folder_path in self.processing_folders
                    or folder_path in self.folders_being_processed
                ):
                    return
                self.folders_being_processed.add(folder_path)

            # Give the system a moment before processing the folder
            self._process_folder_after_delay(folder_path)
            return

        file_path = event.src_path
        file_dir = os.path.dirname(file_path)

        # Skip files in folders that are already being processed
        if self._is_folder_in_progress_for_path(file_path=file_path, file_dir=file_dir):
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
        with self.state_lock:
            if file_path in self.processing_files:
                return
            self.processing_files.add(file_path)

        # Give the system a moment to finish writing the file
        self._process_file_after_delay(file_path)

    def _process_folder_after_delay(self, folder_path):
        """Wait before processing to ensure folder creation is complete"""
        self.worker_pool.submit(self._delayed_process_folder, folder_path)

    def _delayed_process_folder(self, folder_path):
        """Process the folder after a short delay"""
        try:
            with self.state_lock:
                self.processing_folders.add(folder_path)

            # Wait a bit longer to make sure all files are copied into the folder
            # This is especially important for large folders or slow file systems
            time.sleep(10)

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
            with self.state_lock:
                self.processing_folders.discard(folder_path)
                self.folders_being_processed.discard(folder_path)

    def _process_file_after_delay(self, file_path):
        """Wait before processing to ensure file is complete"""
        self.worker_pool.submit(self._delayed_process, file_path)

    def _delayed_process(self, file_path):
        """Process the file after a short delay"""
        try:
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
                time.sleep(2)
                if os.path.exists(file_path):  # File might be deleted
                    current_size = os.path.getsize(file_path)
                else:
                    logging.info(f"File was deleted during processing: {file_path}")
                    return

            # Now process the file
            filename = os.path.basename(file_path)

            # Check again if this file's directory is being processed as a folder
            file_dir = os.path.dirname(file_path)
            if self._is_folder_in_progress_for_path(file_path=file_path, file_dir=file_dir):
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

            # Process based on file type and only remove input file on success.
            process_future = None
            filename_lower = filename.lower()
            if filename_lower.endswith(DOCUMENT_EXTENSIONS):
                process_future = asyncio.run_coroutine_threadsafe(
                    utils.process_document(
                        filename=filename,
                        content=content,
                        source_path=file_path,
                    ),
                    self.loop,
                )
            elif filename_lower.endswith(IMAGE_EXTENSIONS):
                process_future = asyncio.run_coroutine_threadsafe(
                    utils.process_image(
                        filename=filename,
                        content=content,
                        source_path=file_path,
                    ),
                    self.loop,
                )
            else:
                logging.info(
                    f"Skipping unsupported file type in input directory: {filename}"
                )
                return

            processed_path = None
            try:
                processed_path = process_future.result(timeout=300)
            except Exception as process_error:
                logging.error(
                    f"Processing failed for {filename}: {str(process_error)}"
                )

            if processed_path and os.path.exists(file_path):
                try:
                    os.remove(file_path)
                    logging.info(f"Removed original file: {file_path}")
                except Exception as e:
                    logging.error(f"Error removing file {file_path}: {str(e)}")
            elif not processed_path:
                logging.warning(
                    f"Keeping original file because processing did not complete: {file_path}"
                )

            if processed_path:
                logging.info(f"Processed and archived file: {filename}")

        except Exception as e:
            logging.error(f"Error processing file {file_path}: {str(e)}")
        finally:
            with self.state_lock:
                self.processing_files.discard(file_path)


class ArchiveDirectoryHandler(FileSystemEventHandler):
    def __init__(self):
        self.loop = asyncio.new_event_loop()
        self.processing_files = set()
        self.processing_folders = set()

    def shutdown(self):
        # Placeholder for parity with input handler lifecycle management.
        return None

    def _should_skip_path(self, path):
        """Helper method to determine if a path should be skipped"""
        # Skip ChromaDB internal files and hidden files
        relative_path = os.path.relpath(path, settings.ARCHIVE_DIR)
        path_parts = relative_path.split(os.sep)

        # Skip if path contains .chromadb directory
        if ".chromadb" in path_parts:
            return True

        # Skip hidden files
        if os.path.basename(path).startswith("."):
            return True

        # Skip temporary folders created during folder processing
        basename = os.path.basename(path)
        if basename.startswith("temp_") and "_" in basename[5:]:
            try:
                # Check if the part after temp_ contains a timestamp (temp_foldername_timestamp)
                parts = basename.split("_")
                if len(parts) >= 3:
                    # Try to parse the last part as a timestamp
                    timestamp = parts[-1]
                    int(timestamp)  # This will fail if it's not a number
                    return True
            except (ValueError, IndexError):
                # If parsing fails, it's not our temp folder format
                pass

        # Check if the path is inside a temporary folder
        parent_dir = os.path.dirname(path)
        if parent_dir != settings.ARCHIVE_DIR:  # Not directly in the archive root
            parent_basename = os.path.basename(parent_dir)
            # Check if parent directory is a temp folder
            if parent_basename.startswith("temp_") and "_" in parent_basename[5:]:
                try:
                    parts = parent_basename.split("_")
                    if len(parts) >= 3:
                        # Try to parse the last part as a timestamp
                        timestamp = parts[-1]
                        int(timestamp)  # This will fail if it's not a number
                        return True
                except (ValueError, IndexError):
                    pass

            # Also check if any ancestor directory is a temp folder
            current_path = parent_dir
            while (
                current_path != settings.ARCHIVE_DIR
                and os.path.dirname(current_path) != current_path
            ):
                current_basename = os.path.basename(current_path)
                if current_basename.startswith("temp_") and "_" in current_basename[5:]:
                    try:
                        parts = current_basename.split("_")
                        if len(parts) >= 3:
                            timestamp = parts[-1]
                            int(timestamp)
                            return True
                    except (ValueError, IndexError):
                        pass
                current_path = os.path.dirname(current_path)

        return False

    def _get_all_files_in_dir(self, dir_path):
        """Get all files in a directory and its subdirectories"""
        files = []
        try:
            for root, _, filenames in os.walk(dir_path):
                for filename in filenames:
                    # Skip hidden files
                    if filename.startswith("."):
                        continue
                    file_path = os.path.join(root, filename)
                    files.append(file_path)
        except Exception as e:
            logging.error(f"Error walking directory {dir_path}: {str(e)}")
        return files

    def on_created(self, event):
        """Handle file/directory creation events in the Archive directory"""
        # Skip if this is a temporary folder or a file within a temporary folder
        if self._should_skip_path(event.src_path):
            basename = os.path.basename(event.src_path)
            if basename.startswith("temp_") and "_" in basename[5:]:
                logging.info(f"Ignoring temporary folder creation: {event.src_path}")
            return

        # If it's a directory creation not related to temp folders, we don't need to do anything
        # Files in this directory will be added to the DB by process_folder when the operation is complete
        if event.is_directory:
            return

        # Normal file creation event handling can be added here if needed
        # But this shouldn't be needed since files are explicitly added to the DB after being processed

    def on_moved(self, event):
        # Handle file moves
        if not event.is_directory:
            # Check if source path is within Archive directory but destination is not
            src_in_archive = not self._should_skip_path(event.src_path)
            dest_in_archive = (
                os.path.commonpath([event.dest_path, settings.ARCHIVE_DIR])
                == settings.ARCHIVE_DIR
            )

            # If file was moved out of the Archive folder, treat it as a deletion
            if src_in_archive and not dest_in_archive:
                old_relative_path = os.path.relpath(
                    event.src_path, settings.ARCHIVE_DIR
                )

                print(f"\n========== FILE MOVED OUT OF ARCHIVE ==========")
                print(f"File: {old_relative_path}")
                print(f"Destination: {event.dest_path}")
                print(f"Treating as deletion...")

                try:
                    chroma.delete_item(old_relative_path)
                    print(f"✓ Removed from ChromaDB")
                    logging.info(
                        f"Deleted item from ChromaDB (moved out): {old_relative_path}"
                    )
                except Exception as e:
                    print(f"✗ Failed to delete from ChromaDB: {str(e)}")
                    logging.error(f"Error deleting item from ChromaDB: {str(e)}")
                return

            # Normal file move within the Archive folder
            # Skip ChromaDB files and hidden files
            if self._should_skip_path(event.src_path) or self._should_skip_path(
                event.dest_path
            ):
                return

            old_relative_path = os.path.relpath(event.src_path, settings.ARCHIVE_DIR)
            new_relative_path = os.path.relpath(event.dest_path, settings.ARCHIVE_DIR)

            print(f"\n========== FILE MOVED ==========")
            print(f"From: {old_relative_path}")
            print(f"To:   {new_relative_path}")

            try:
                content = filesystem.fetch_content(new_relative_path)
                if content:
                    is_image = new_relative_path.lower().endswith(
                        (".jpg", ".jpeg", ".png", ".gif", ".webp")
                    )
                    chroma.rename(
                        old_relative_path, new_relative_path, content, is_image=is_image
                    )
                    print(f"✓ ChromaDB updated with new path")
                    logging.info(
                        f"Updated ChromaDB after file move: {old_relative_path} -> {new_relative_path}"
                    )
                else:
                    print(f"✗ Could not fetch content for {new_relative_path}")
            except Exception as e:
                print(f"✗ Failed to update ChromaDB: {str(e)}")
                logging.error(f"Error updating ChromaDB after file move: {str(e)}")

        # Handle directory moves/renames
        else:
            # Check if source path is within Archive directory but destination is not
            src_in_archive = not self._should_skip_path(event.src_path)
            dest_in_archive = (
                os.path.commonpath([event.dest_path, settings.ARCHIVE_DIR])
                == settings.ARCHIVE_DIR
            )

            # If folder was moved out of the Archive folder, treat it as a deletion
            if src_in_archive and not dest_in_archive:
                dir_path = event.src_path
                dir_relative_path = os.path.relpath(dir_path, settings.ARCHIVE_DIR)

                print(f"\n========== FOLDER MOVED OUT OF ARCHIVE ==========")
                print(f"Folder: {dir_relative_path}")
                print(f"Destination: {event.dest_path}")
                print(f"Treating as deletion...")
                print(
                    f"Running reconciliation to remove any deleted files from database..."
                )

                try:
                    schedule_reconciliation(
                        reason="folder-moved-out-of-archive",
                        debounce_seconds=1.5,
                    )
                    print(f"✓ Started reconciliation process to clean up database")
                    logging.info(
                        f"Folder moved out of archive: {dir_relative_path}, started reconciliation"
                    )
                except Exception as e:
                    print(f"✗ Failed to start reconciliation: {str(e)}")
                    logging.error(
                        f"Error starting reconciliation after folder moved out: {str(e)}"
                    )
                return

            # Skip ChromaDB directories and hidden folders
            if self._should_skip_path(event.src_path) or self._should_skip_path(
                event.dest_path
            ):
                return

            # Avoid processing if already in progress
            if (
                event.src_path in self.processing_folders
                or event.dest_path in self.processing_folders
            ):
                return

            old_dir_path = event.src_path
            new_dir_path = event.dest_path

            old_relative_path = os.path.relpath(old_dir_path, settings.ARCHIVE_DIR)
            new_relative_path = os.path.relpath(new_dir_path, settings.ARCHIVE_DIR)

            print(f"\n========== FOLDER MOVED/RENAMED ==========")
            print(f"From: {old_relative_path}")
            print(f"To:   {new_relative_path}")

            try:
                self.processing_folders.add(new_dir_path)

                # Get all files in the directory that was moved
                files_to_update = self._get_all_files_in_dir(new_dir_path)

                if not files_to_update:
                    print(f"No files found in moved directory: {new_relative_path}")
                    return

                print(f"Found {len(files_to_update)} files to update in ChromaDB")
                updated_count = 0
                failed_count = 0

                for file_path in files_to_update:
                    if self._should_skip_path(file_path):
                        continue

                    # Calculate the old and new relative paths for this file
                    file_relative_path = os.path.relpath(
                        file_path, settings.ARCHIVE_DIR
                    )

                    # Determine what the old path would have been for this file
                    old_file_relative_path = file_relative_path.replace(
                        new_relative_path, old_relative_path, 1
                    )

                    # Skip files that aren't in the database (might be new)
                    try:
                        content = filesystem.fetch_content(file_relative_path)
                        if not content:
                            print(f"✗ Could not fetch content for {file_relative_path}")
                            failed_count += 1
                            continue

                        # Update the path in ChromaDB
                        is_image = file_relative_path.lower().endswith(
                            (".jpg", ".jpeg", ".png", ".gif", ".webp")
                        )

                        # Delete the old entry and add with new path
                        try:
                            # Try to delete the old entry first
                            chroma.delete_item(old_file_relative_path)

                            # Add with the new path
                            if is_image:
                                chroma.add_image_to_collection(
                                    file_relative_path, content
                                )
                            else:
                                text_content = utils.extract_text_for_file_type(
                                    file_relative_path, content
                                )
                                chroma.add_document_to_collection(
                                    file_relative_path, text_content
                                )

                            print(f"✓ Updated path for file: {file_relative_path}")
                            updated_count += 1
                        except Exception as e:
                            # File might not have been in DB, just add it
                            if is_image:
                                chroma.add_image_to_collection(
                                    file_relative_path, content
                                )
                            else:
                                text_content = utils.extract_text_for_file_type(
                                    file_relative_path, content
                                )
                                chroma.add_document_to_collection(
                                    file_relative_path, text_content
                                )

                            print(f"✓ Added file with new path: {file_relative_path}")
                            updated_count += 1

                    except Exception as e:
                        print(f"✗ Failed to update {file_relative_path}: {str(e)}")
                        failed_count += 1

                print(
                    f"\nFolder rename/move complete. Updated {updated_count} files, failed to update {failed_count} files."
                )
                logging.info(
                    f"Folder rename/move processed: {old_relative_path} -> {new_relative_path}, updated {updated_count} files"
                )

            except Exception as e:
                print(f"✗ Error processing folder move/rename: {str(e)}")
                logging.error(f"Error processing folder move/rename: {str(e)}")
            finally:
                if new_dir_path in self.processing_folders:
                    self.processing_folders.remove(new_dir_path)

    def on_deleted(self, event):
        # Handle file deletions
        if not event.is_directory:
            # Skip ChromaDB files and hidden files
            if self._should_skip_path(event.src_path):
                return

            relative_path = os.path.relpath(event.src_path, settings.ARCHIVE_DIR)

            print(f"\n========== FILE DELETED ==========")
            print(f"File: {relative_path}")

            try:
                chroma.delete_item(relative_path)
                print(f"✓ Removed from ChromaDB")
                logging.info(f"Deleted item from ChromaDB: {relative_path}")
            except Exception as e:
                print(f"✗ Failed to delete from ChromaDB: {str(e)}")
                logging.error(f"Error deleting item from ChromaDB: {str(e)}")

        # Handle directory deletions
        else:
            # Skip ChromaDB directories and hidden folders
            if self._should_skip_path(event.src_path):
                return

            dir_path = event.src_path
            dir_relative_path = os.path.relpath(dir_path, settings.ARCHIVE_DIR)

            print(f"\n========== FOLDER DELETED ==========")
            print(f"Folder: {dir_relative_path}")

            # Since the directory is already deleted, we can't scan it
            # We need to run a reconciliation to clean up orphaned entries
            print(
                f"Running reconciliation to remove any deleted files from database..."
            )

            try:
                schedule_reconciliation(
                    reason="folder-deleted-in-archive",
                    debounce_seconds=1.5,
                )
                print(f"✓ Started reconciliation process to clean up database")
                logging.info(
                    f"Folder deletion detected for {dir_relative_path}, started reconciliation"
                )
            except Exception as e:
                print(f"✗ Failed to start reconciliation: {str(e)}")
                logging.error(
                    f"Error starting reconciliation after folder deletion: {str(e)}"
                )

    def on_modified(self, event):
        # Skip temp folders and paths that should be skipped based on _should_skip_path
        if self._should_skip_path(event.src_path):
            basename = os.path.basename(event.src_path)
            if basename.startswith("temp_") and "_" in basename[5:]:
                logging.info(
                    f"Ignoring modification to temporary folder: {event.src_path}"
                )
            return

        if not event.is_directory:
            relative_path = os.path.relpath(event.src_path, settings.ARCHIVE_DIR)

            # Skip processing if already being processed
            if relative_path in self.processing_files:
                return

            print(f"\n========== FILE MODIFIED ==========")
            print(f"File: {relative_path}")

            try:
                self.processing_files.add(relative_path)

                # Re-fetch the current content
                content = filesystem.fetch_content(relative_path)
                if content:
                    is_image = relative_path.lower().endswith(
                        (".jpg", ".jpeg", ".png", ".gif", ".webp")
                    )

                    # Remove the old entry
                    chroma.delete_item(relative_path)
                    print(f"✓ Removed old data from ChromaDB")

                    if is_image:
                        chroma.add_image_to_collection(relative_path, content)
                        print(f"✓ Added updated image to ChromaDB")
                    else:
                        # Extract text based on file type
                        text_content = utils.extract_text_for_file_type(
                            relative_path, content
                        )
                        chroma.add_document_to_collection(relative_path, text_content)
                        print(f"✓ Added updated document to ChromaDB")

                    logging.info(
                        f"Updated item in ChromaDB after modification: {relative_path}"
                    )
                else:
                    print(f"✗ Could not fetch content for {relative_path}")
            except Exception as e:
                print(f"✗ Failed to update ChromaDB: {str(e)}")
                logging.error(
                    f"Error updating item in ChromaDB after modification: {str(e)}"
                )
            finally:
                if relative_path in self.processing_files:
                    self.processing_files.remove(relative_path)


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
        try:
            loop.stop()
        except RuntimeError:
            pass
        try:
            loop.close()
        except Exception as exc:
            logging.error("Failed closing observer loop: %s", exc)


@app.get("/health")
def health_check():
    # Check if input and archive directories exist
    input_exists = os.path.exists(settings.INPUT_DIR)
    archive_exists = os.path.exists(settings.ARCHIVE_DIR)
    provider = (settings.LLM_PROVIDER or "openai").strip().lower()

    ollama_status = "skipped"
    llm_runtime_ok = True
    if provider == "ollama":
        ollama_status = _cached_ollama_status()
        llm_runtime_ok = ollama_status == "running"

    return {
        "status": (
            "ok"
            if input_exists and archive_exists and llm_runtime_ok
            else "warning"
        ),
        "pid": os.getpid(),
        "managed_by_app": _MANAGED_BY_APP,
        "managed_app_pid": _MANAGED_APP_PID if _MANAGED_BY_APP else None,
        "provider": provider,
        "input_dir": {"path": settings.INPUT_DIR, "exists": input_exists},
        "watch_input_dir": settings.WATCH_INPUT_DIR,
        "archive_dir": {"path": settings.ARCHIVE_DIR, "exists": archive_exists},
        "ollama": ollama_status,
        "timestamp": datetime.now().isoformat(),
    }


@app.post("/shutdown")
def shutdown_backend():
    def _terminate():
        # Return response first, then terminate process.
        time.sleep(0.15)
        os.kill(os.getpid(), signal.SIGTERM)

    threading.Thread(target=_terminate, daemon=True, name="archive-shutdown").start()
    return {"status": "shutting_down", "pid": os.getpid()}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=settings.HOST, port=settings.PORT)
