import azure.functions as func
import logging
import json
from urllib.parse import urlparse, unquote
from azure.storage.blob import BlobClient
from azure.identity import DefaultAzureCredential

app = func.FunctionApp()

@app.event_grid_trigger(arg_name="event")
def BlobCreatedHandler(event: func.EventGridEvent):
    try:
        data = event.get_json() or {}
        url = data.get("url")
        content_length = data.get("contentLength")
        version_id = data.get("versionId")

        blob_name = _parse_blob_name_from_url(url) if url else None

        # Try to fetch version_id if missing
        if not version_id and url:
            logging.info(f"Try to get blob version by url: {url}")

            try:
                cred = DefaultAzureCredential(exclude_interactive_browser_credential=True)
                blob_client = BlobClient.from_blob_url(url, credential=cred)
                props = blob_client.get_blob_properties()
                version_id = props.version_id
            except Exception as e:
                logging.warning(f"Could not retrieve version_id for {blob_name}: {e}")
                version_id = None

        log_payload = {
            "blob_name": blob_name,
            "blob_size": content_length,
            "version_id": version_id,
            "event_time": event.event_time.isoformat() if event.event_time else None,
        }
        logging.info(json.dumps(log_payload))

    except Exception as e:
        logging.exception("Error processing Event Grid event")


def _parse_blob_name_from_url(url: str) -> str:
    p = urlparse(url)
    path = p.path.lstrip("/")
    return unquote(path)
