import base64
import json
import logging
import os
import re
from dataclasses import dataclass
from functools import lru_cache
from uuid import uuid4

import azure.functions as func
from azure.core import MatchConditions
from azure.core.exceptions import AzureError, ResourceNotFoundError
from azure.identity import AzureCliCredential, ManagedIdentityCredential
from azure.keyvault.keys.crypto import CryptographyClient
from azure.storage.blob import ContainerClient
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

# Authentication is enforced by Function App Authentication (Microsoft Entra).
# Configure the principal allowlist before deploying or exposing this sample.
app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)
MAX_DOCUMENT_BYTES = 8 * 1024 * 1024
GCM_TAG_BYTES = 16
WRAP_ALGORITHM = "A256KW"
FORMAT = "1"
HEX_ID = re.compile(r"[0-9a-f]{32}")

# Servicesクラス
#  ContainerClient: Azure Blob Storageのコンテナクライアント
#  credential: Azureの認証情報（Azure CLIまたはManaged Identity）
#  key_base: Managed HSMの鍵バージョンを含まないURL（例: https://<hsm-name>.managedhsm.azure.net/keys/<key-name>）
#  write_version: 新規保存時にDEKをラップするCMKのバージョンID

@dataclass(frozen=True)
class Services:
    container: ContainerClient
    credential: AzureCliCredential | ManagedIdentityCredential
    key_base: str
    write_version: str


@lru_cache(maxsize=1)
def services() -> Services:
    if os.environ.get("DOCUMENT_USE_AZURE_CLI") == "1":
        credential = AzureCliCredential()
    else:
        client_id = os.environ.get("DOCUMENT_MANAGED_IDENTITY_CLIENT_ID")
        credential = ManagedIdentityCredential(client_id=client_id)

    version = os.environ["HSM_KEY_VERSION"]
    if not HEX_ID.fullmatch(version):
        raise ValueError("HSM_KEY_VERSION must be a version ID")

    hsm_url = os.environ["HSM_URL"].rstrip("/")
    key_name = os.environ["HSM_KEY_NAME"]
    return Services(
        container=ContainerClient(
            os.environ["DOCUMENT_BLOB_URL"],
            os.environ["DOCUMENT_CONTAINER"],
            credential=credential,
        ),
        credential=credential,
        key_base=f"{hsm_url}/keys/{key_name}",
        write_version=version,
    )


def aad(document_id: str) -> bytes:
    return f"document-envelope:{FORMAT}:{document_id}".encode("ascii")


def json_response(status: int, payload: dict) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps(payload),
        status_code=status,
        mimetype="application/json",
        headers={"Cache-Control": "no-store"},
    )


@app.route(route="v1/documents", methods=["POST"])
def save_document(req: func.HttpRequest) -> func.HttpResponse:
    if req.headers.get("Content-Type", "").split(";")[0].strip().lower() != "application/octet-stream":
        return json_response(415, {"error": "use application/octet-stream"})

    plaintext = req.get_body()
    if not plaintext:
        return json_response(400, {"error": "empty document"})
    if len(plaintext) > MAX_DOCUMENT_BYTES:
        return json_response(413, {"error": "document exceeds 8 MiB"})

    document_id = uuid4().hex
    try:
        config = services()
        dek = AESGCM.generate_key(bit_length=256)
        nonce = os.urandom(12)
        ciphertext = AESGCM(dek).encrypt(nonce, plaintext, aad(document_id))
        with CryptographyClient(
            f"{config.key_base}/{config.write_version}", config.credential
        ) as crypto:
            wrapped = crypto.wrap_key(WRAP_ALGORITHM, dek)

        config.container.upload_blob(
            name=document_id,
            data=ciphertext,
            overwrite=False,
            metadata={
                "envelope_version": FORMAT,
                "key_version": config.write_version,
                "nonce": base64.b64encode(nonce).decode("ascii"),
                "wrapped_dek": base64.b64encode(wrapped.encrypted_key).decode("ascii"),
            },
        )
    except AzureError as exc:
        logging.error("Document save dependency error: %s", type(exc).__name__)
        return json_response(502, {"error": "document could not be stored"})

    return json_response(201, {"id": document_id})


@app.route(route="v1/documents/{document_id}", methods=["GET"])
def get_document(req: func.HttpRequest) -> func.HttpResponse:
    document_id = req.route_params["document_id"]
    if not HEX_ID.fullmatch(document_id):
        return json_response(400, {"error": "invalid document ID"})

    config = services()
    blob = config.container.get_blob_client(document_id)
    try:
        properties = blob.get_blob_properties()
        metadata = properties.metadata
        key_version = metadata["key_version"]
        if metadata["envelope_version"] != FORMAT or not HEX_ID.fullmatch(key_version):
            raise ValueError("Invalid envelope")
        if not GCM_TAG_BYTES < properties.size <= MAX_DOCUMENT_BYTES + GCM_TAG_BYTES:
            raise ValueError("Invalid ciphertext size")
        nonce = base64.b64decode(metadata["nonce"], validate=True)
        wrapped_dek = base64.b64decode(metadata["wrapped_dek"], validate=True)
        if len(nonce) != 12 or len(wrapped_dek) != 40:
            raise ValueError("Invalid nonce or wrapped key")

        ciphertext = blob.download_blob(
            etag=properties.etag,
            match_condition=MatchConditions.IfNotModified,
        ).readall()
    except ResourceNotFoundError as exc:
        if exc.error_code == "BlobNotFound":
            return json_response(404, {"error": "document not found"})
        return json_response(502, {"error": "document storage unavailable"})
    except AzureError as exc:
        logging.error("Document read dependency error: %s", type(exc).__name__)
        return json_response(502, {"error": "document could not be retrieved"})
    except (KeyError, ValueError):
        logging.error("Invalid envelope metadata for document %s", document_id)
        return json_response(500, {"error": "document could not be decrypted"})

    try:
        # Only a version is taken from Blob metadata. Host and key name come
        # from trusted application settings.
        with CryptographyClient(
            f"{config.key_base}/{key_version}", config.credential
        ) as crypto:
            dek = crypto.unwrap_key(WRAP_ALGORITHM, wrapped_dek).key
        if len(dek) != 32:
            raise ValueError("Invalid DEK size")
        plaintext = AESGCM(dek).decrypt(nonce, ciphertext, aad(document_id))
    except (InvalidTag, ValueError):
        logging.error("Invalid envelope for document %s", document_id)
        return json_response(500, {"error": "document could not be decrypted"})
    except AzureError as exc:
        logging.error("Document unwrap dependency error: %s", type(exc).__name__)
        return json_response(502, {"error": "document could not be decrypted"})

    return func.HttpResponse(
        plaintext,
        mimetype="application/octet-stream",
        headers={"Cache-Control": "no-store"},
    )
