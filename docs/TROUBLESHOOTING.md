# Troubleshooting

## Update check failed

Symptom:

- App shows update check error dialog.

Checks:

- Confirm repository has at least one GitHub release or version tag.
- Confirm internet access from your machine.
- Confirm GitHub API is not rate-limiting you.

Expected behavior:

- If no release/tag exists, app should report that no published version exists yet.

## Backend is not reachable

Symptom:

- Settings or search fails with network/server errors.

Checks:

- Start backend from `backend/` with `python main.py`.
- Confirm server is listening on `http://localhost:8000`.
- Open `http://localhost:8000/health`.

## Local model not responding

Symptom:

- Local provider selected but organization/search behaves poorly or fails.

Checks:

- Verify local runtime is running (for example Ollama).
- Verify base URL in Settings is reachable (`http://localhost:11434` by default).
- Verify model id exists locally.

## Cloud provider API key issues

Symptom:

- Provider requests fail or key appears missing.

Checks:

- Add key from Settings > AI.
- Confirm provider selection matches the key you added.
- Re-add key if it was migrated from old plaintext config.

## ChromaDB schema/runtime issues

Symptom examples:

- `no such column: collections.topic`
- `'_type'`
- `Could not access ChromaDB collection`

Checks:

- Ensure `backend/requirements.txt` installed in a clean virtualenv.
- Stop backend and restart.
- Trigger manual reconcile from API: `POST /reconcile`.
- If issue persists after upgrades, back up and recreate `.chromadb` directory under archive path.

## Watcher not reacting to new files

Symptom:

- Dropping files in input folder does nothing.

Checks:

- Confirm configured Input/Archive paths in Settings.
- Confirm backend log shows watcher startup.
- Update directories in Settings to force watcher restart.

## Reset local environment

From repository root:

```bash
cd backend
rm -rf .venv
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python main.py
```

Then rebuild/run macOS app from Xcode.
