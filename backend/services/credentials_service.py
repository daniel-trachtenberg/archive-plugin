import logging
import os
import subprocess
from pathlib import Path

try:
    from cryptography.fernet import Fernet, InvalidToken
except Exception:  # pragma: no cover - dependency installed via requirements
    Fernet = None

    class InvalidToken(Exception):
        pass

try:
    import keyring
except Exception:  # pragma: no cover - optional runtime backend
    keyring = None


_KEYRING_SERVICE = "archive-plugin"
_KEYRING_ACCOUNT = "master-key"
_LOCAL_KEY_PATH = Path.home() / ".archive_plugin" / "master.key"
_KEYCHAIN_SERVICE = "archive-plugin-api-keys"
_KEYCHAIN_REF_PREFIX = "keychain://"

_PROVIDER_FIELD_MAP = {
    "openai": ("OPENAI_API_KEY", "OPENAI_API_KEY_ENC"),
    "anthropic": ("ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY_ENC"),
    "openai_compatible": ("OPENAI_COMPATIBLE_API_KEY", "OPENAI_COMPATIBLE_API_KEY_ENC"),
}


def _require_cryptography() -> None:
    if Fernet is None:
        raise RuntimeError(
            "Missing dependency 'cryptography'. Run: pip install -r backend/requirements.txt"
        )


def _normalize_fernet_key(value: str) -> bytes:
    _require_cryptography()
    candidate = (value or "").strip()
    if not candidate:
        raise ValueError("Missing encryption key")
    if isinstance(candidate, str):
        candidate = candidate.encode("utf-8")
    # Raises if invalid; keeps key format strict.
    Fernet(candidate)
    return candidate


def _load_or_create_master_key() -> bytes:
    _require_cryptography()
    env_key = os.getenv("ARCHIVE_MASTER_KEY", "").strip()
    if env_key:
        return _normalize_fernet_key(env_key)

    if keyring is not None:
        try:
            stored_key = keyring.get_password(_KEYRING_SERVICE, _KEYRING_ACCOUNT)
            if stored_key:
                return _normalize_fernet_key(stored_key)

            new_key = Fernet.generate_key().decode("utf-8")
            keyring.set_password(_KEYRING_SERVICE, _KEYRING_ACCOUNT, new_key)
            return new_key.encode("utf-8")
        except Exception as exc:
            logging.warning("Keyring unavailable for API key encryption, using local key file: %s", exc)

    _LOCAL_KEY_PATH.parent.mkdir(parents=True, exist_ok=True)
    if _LOCAL_KEY_PATH.exists():
        return _normalize_fernet_key(_LOCAL_KEY_PATH.read_text().strip())

    new_key = Fernet.generate_key().decode("utf-8")
    _LOCAL_KEY_PATH.write_text(new_key)
    os.chmod(_LOCAL_KEY_PATH, 0o600)
    return new_key.encode("utf-8")


def _is_probably_fernet_token(value: str) -> bool:
    return (value or "").startswith("gAAAA")


def _keychain_ref(provider: str) -> str:
    return f"{_KEYCHAIN_REF_PREFIX}{provider}"


def _is_keychain_ref(value: str) -> bool:
    return (value or "").startswith(_KEYCHAIN_REF_PREFIX)


def _keychain_account(provider: str) -> str:
    return f"provider:{provider}"


def _store_secret_in_keychain(provider: str, value: str) -> bool:
    if not value:
        return True
    try:
        result = subprocess.run(
            [
                "security",
                "add-generic-password",
                "-a",
                _keychain_account(provider),
                "-s",
                _KEYCHAIN_SERVICE,
                "-w",
                value,
                "-U",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0:
            return True
        logging.error("Failed storing API key in keychain: %s", (result.stderr or "").strip())
        return False
    except Exception as exc:
        logging.error("Failed storing API key in keychain: %s", exc)
        return False


def _read_secret_from_keychain(provider: str) -> str:
    try:
        result = subprocess.run(
            [
                "security",
                "find-generic-password",
                "-a",
                _keychain_account(provider),
                "-s",
                _KEYCHAIN_SERVICE,
                "-w",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0:
            return (result.stdout or "").strip()
        return ""
    except Exception as exc:
        logging.error("Failed reading API key from keychain: %s", exc)
        return ""


def _delete_secret_from_keychain(provider: str) -> None:
    try:
        subprocess.run(
            [
                "security",
                "delete-generic-password",
                "-a",
                _keychain_account(provider),
                "-s",
                _KEYCHAIN_SERVICE,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
    except Exception:
        pass


def encrypt_secret(value: str) -> str:
    if not value:
        return ""
    _require_cryptography()
    fernet = Fernet(_load_or_create_master_key())
    return fernet.encrypt(value.encode("utf-8")).decode("utf-8")


def decrypt_secret(value: str) -> str:
    if not value:
        return ""
    if not _is_probably_fernet_token(value):
        # Backward compatibility for existing plaintext values.
        return value

    _require_cryptography()
    fernet = Fernet(_load_or_create_master_key())
    try:
        return fernet.decrypt(value.encode("utf-8")).decode("utf-8")
    except InvalidToken:
        logging.error("Invalid encrypted API key token; unable to decrypt.")
        return ""
    except Exception as exc:
        logging.error("Failed to decrypt API key: %s", exc)
        return ""


def get_provider_api_key(provider: str, settings) -> str:
    provider = (provider or "").lower()
    fields = _PROVIDER_FIELD_MAP.get(provider)
    if not fields:
        return ""

    plain_field, enc_field = fields
    plain = getattr(settings, plain_field, "") or ""
    encrypted = getattr(settings, enc_field, "") or ""

    if _is_keychain_ref(encrypted):
        keychain_value = _read_secret_from_keychain(provider)
        if keychain_value:
            setattr(settings, plain_field, keychain_value)
            return keychain_value

    if encrypted:
        try:
            decrypted = decrypt_secret(encrypted)
        except RuntimeError as exc:
            logging.error("Could not decrypt %s: %s", enc_field, exc)
            decrypted = ""
        if decrypted:
            setattr(settings, plain_field, decrypted)
            return decrypted

    if plain:
        # Opportunistic migration path for existing plaintext keys.
        try:
            setattr(settings, enc_field, encrypt_secret(plain))
        except RuntimeError:
            if _store_secret_in_keychain(provider, plain):
                setattr(settings, enc_field, _keychain_ref(provider))
            else:
                logging.warning("Failed to migrate plaintext API key to keychain fallback.")
        except Exception as exc:
            logging.warning("Failed to migrate plaintext API key to secure storage: %s", exc)
    return plain


def set_provider_api_key(provider: str, value: str, settings) -> None:
    provider = (provider or "").lower()
    fields = _PROVIDER_FIELD_MAP.get(provider)
    if not fields:
        return

    plain_field, enc_field = fields
    cleaned = (value or "").strip()
    if not cleaned:
        _delete_secret_from_keychain(provider)
        setattr(settings, plain_field, "")
        setattr(settings, enc_field, "")
        return

    try:
        encrypted = encrypt_secret(cleaned)
        setattr(settings, plain_field, cleaned)
        setattr(settings, enc_field, encrypted)
    except RuntimeError:
        if _store_secret_in_keychain(provider, cleaned):
            setattr(settings, plain_field, cleaned)
            setattr(settings, enc_field, _keychain_ref(provider))
            return
        raise RuntimeError("Could not securely store API key. Install cryptography or enable Keychain access.")


def provider_api_env_values(settings) -> dict:
    return {
        "OPENAI_API_KEY_ENC": getattr(settings, "OPENAI_API_KEY_ENC", "") or "",
        "ANTHROPIC_API_KEY_ENC": getattr(settings, "ANTHROPIC_API_KEY_ENC", "") or "",
        "OPENAI_COMPATIBLE_API_KEY_ENC": getattr(settings, "OPENAI_COMPATIBLE_API_KEY_ENC", "") or "",
        # Keep plaintext fields blank in persisted config.
        "OPENAI_API_KEY": "",
        "ANTHROPIC_API_KEY": "",
        "OPENAI_COMPATIBLE_API_KEY": "",
        "LLM_API_KEY": "",
    }


def migrate_plaintext_keys(settings) -> bool:
    changed = False
    for provider, (plain_field, enc_field) in _PROVIDER_FIELD_MAP.items():
        plain = getattr(settings, plain_field, "") or ""
        encrypted = getattr(settings, enc_field, "") or ""
        if plain and not encrypted:
            try:
                setattr(settings, enc_field, encrypt_secret(plain))
                changed = True
            except RuntimeError:
                if _store_secret_in_keychain(provider, plain):
                    setattr(settings, enc_field, _keychain_ref(provider))
                    changed = True
            except Exception as exc:
                logging.warning("Failed migrating %s to encrypted storage: %s", plain_field, exc)
    return changed
