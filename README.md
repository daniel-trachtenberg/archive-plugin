[![archive-banner.png](https://i.postimg.cc/NfrkTK7Q/archive-banner.png)](https://postimg.cc/YhMFBqsP)

# /Archive

/Archive is a macOS plugin that automatically categorizes and organizes your files using AI. It provides intelligent file sorting and context-based search, making it easy to find your files when you need them.

## Overview

/Archive watches your designated input folders (like Downloads) and automatically sorts files into appropriate categories in your output folder (like Desktop). When you download a new document, image, or spreadsheet, /Archive analyzes it and moves it to the right place in your file system.

For example:

- A financial statement PDF gets sorted to `Finance/Statements`
- Family photos go to `Photos/Family`
- Work presentations go to `Work/Presentations`

All of this happens automatically, keeping your files organized without manual effort.

## Supported File Types

/Archive currently supports the following file types:

### Documents

- PDF (.pdf)
- Word documents (.doc, .docx)
- Text files (.txt, .md, .rtf)

### Presentations

- PowerPoint (.pptx)

### Spreadsheets

- Excel (.xls, .xlsx)
- CSV (.csv)

### Images

- JPEG (.jpg, .jpeg)
- PNG (.png)
- GIF (.gif)
- WEBP (.webp)
- HEIC (.heic)

## Getting Started

### Prerequisites

- macOS computer
- [Ollama](https://ollama.ai/) installed locally
- Git

### Installation

1. **Clone the repository**

   ```bash
   git clone https://github.com/daniel-trachtenberg/archive-plugin.git
   cd archive-plugin
   ```

2. **Set up Ollama**

   - Install Ollama from [ollama.ai](https://ollama.ai/)
   - Run the model:

   ```bash
   ollama run llama3.2
   ```

3. **Set up the backend**

   ```bash
   cd backend
   pip install -r requirements.txt
   python main.py
   ```

   The backend server will start on http://localhost:8000

4. **Run the macOS app**
   - Open the ArchiveMac project in Xcode:
   ```bash
   cd ../ArchiveMac
   open ArchiveMac.xcodeproj
   ```
   - Build and run the app from Xcode

### Configuration

You can customize Archive by editing the `.env` file in the backend directory:

- `ARCHIVE_DIR`: Where your files will be stored (default: ~/Desktop/Archive)
- `INPUT_DIR`: Where Archive will watch for new files (default: ~/Desktop/Input)
- `OLLAMA_MODEL`: The LLM model to use (default: gemma3:4b)

## Credits

Developed by: **Evan Adami** & **Daniel Trachtenberg**
