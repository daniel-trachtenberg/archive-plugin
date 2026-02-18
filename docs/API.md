# Backend API

Base URL:

- `http://localhost:8000`

## Endpoints

### `POST /upload`

Upload and process a single file.

Request:

- Multipart form field: `file`

Response:

```json
{
  "message": "File processed successfully",
  "path": "<absolute archived file path>"
}
```

### `GET /query`

Semantic search over archived files.

Query params:

- `query_text` (required)
- `n_results` (optional, default `5`)

Response:

```json
{
  "results": [
    "/absolute/path/to/file1.pdf",
    "/absolute/path/to/file2.docx"
  ]
}
```

### `GET /stats`

Archive and filesystem stats.

Response:

```json
{
  "total_files": 123,
  "total_directories": 17,
  "input_directory": "/Users/me/Desktop/Input",
  "archive_directory": "/Users/me/Desktop/Archive"
}
```

### `GET /directories`

Get current watched/input and archive directories.

Response:

```json
{
  "input_dir": "/Users/me/Desktop/Input",
  "archive_dir": "/Users/me/Desktop/Archive"
}
```

### `PUT /directories`

Update input/archive directories and restart watchers.

Request:

```json
{
  "input_dir": "/Users/me/Desktop/Input",
  "archive_dir": "/Users/me/Desktop/Archive"
}
```

Response:

```json
{
  "input_dir": "/Users/me/Desktop/Input",
  "archive_dir": "/Users/me/Desktop/Archive"
}
```

### `GET /llm-settings`

Get active provider/model/base URL with masked API key.

Response:

```json
{
  "provider": "openai",
  "model": "gpt-5.2",
  "base_url": "https://api.openai.com/v1",
  "api_key_masked": "sk-...ZtMA"
}
```

### `PUT /llm-settings`

Update provider/model/base URL and optionally API key.

Request:

```json
{
  "provider": "openai",
  "model": "gpt-5.2",
  "base_url": "https://api.openai.com/v1",
  "api_key": ""
}
```

Response:

```json
{
  "provider": "openai",
  "model": "gpt-5.2",
  "base_url": "https://api.openai.com/v1",
  "api_key_masked": "sk-...ZtMA"
}
```

Supported providers:

- `openai`
- `anthropic`
- `openai_compatible`
- `ollama`

### `GET /llm-api-key`

Get masked API key for a cloud provider.

Query params:

- `provider` (`openai`, `anthropic`, `openai_compatible`)

Response:

```json
{
  "provider": "openai",
  "api_key_masked": "sk-...ZtMA"
}
```

### `PUT /llm-api-key`

Set or replace API key for a cloud provider.

Request:

```json
{
  "provider": "openai",
  "api_key": "sk-..."
}
```

Response:

```json
{
  "provider": "openai",
  "api_key_masked": "sk-...ZtMA"
}
```

### `DELETE /llm-api-key`

Delete stored API key for a cloud provider.

Query params:

- `provider` (`openai`, `anthropic`, `openai_compatible`)

Response:

```json
{
  "provider": "openai",
  "api_key_masked": ""
}
```

### `POST /reconcile`

Manually trigger filesystem <-> ChromaDB reconciliation.

Response:

```json
{
  "status": "success",
  "message": "Reconciliation completed successfully"
}
```

### `GET /move-logs`

Get recent plugin file-movement logs for debugging.

Query params:

- `hours` (optional, default `24`, max `8760`)
- `limit` (optional, default `200`, max `1000`)

Response:

```json
{
  "timeframe_hours": 24,
  "total": 2,
  "logs": [
    {
      "id": 18,
      "created_at": "2026-02-18T20:41:26Z",
      "source_path": "/Users/me/Desktop/Input/invoice.pdf",
      "destination_path": "/Users/me/Desktop/Archive/Finance/invoice.pdf",
      "item_type": "file",
      "trigger": "input_watcher",
      "status": "success",
      "note": ""
    }
  ]
}
```

### `GET /health`

Basic backend health check.

Response:

```json
{
  "status": "ok",
  "input_dir": {"path": "...", "exists": true},
  "archive_dir": {"path": "...", "exists": true},
  "ollama": "running",
  "timestamp": "2026-02-17T..."
}
```

## Error format

Most failures return FastAPI HTTP errors with:

```json
{
  "detail": "<message>"
}
```

## Agent-facing note

This API is currently local-first and unauthenticated. If you expose it outside localhost, add authentication and transport security first.
