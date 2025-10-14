import azure.functions as func
import logging
import json
from urllib.parse import urlparse, unquote
from azure.storage.blob import BlobClient
from azure.identity import DefaultAzureCredential

app = func.FunctionApp()

def _parse_blob_name_from_url(url: str) -> str:
    p = urlparse(url)
    path = p.path.lstrip("/")
    return unquote(path)

@app.route(route="BlobCreatedHandler", auth_level=func.AuthLevel.FUNCTION)
def BlobCreatedHandler(req: func.HttpRequest) -> func.HttpResponse:
    try:
        events = json.loads(req.get_body() or "[]")

        for event in events:
            event_type = event.get("eventType")

            # Handle Event Grid validation handshake (required when subscription is first created)
            if event_type == "Microsoft.EventGrid.SubscriptionValidationEvent":
                validation_code = event.get("data", {}).get("validationCode")
                if not validation_code:
                    continue
                return func.HttpResponse(
                    body=json.dumps({"validationResponse": validation_code}),
                    mimetype="application/json",
                    status_code=200,
                )

            if event_type == "Microsoft.Storage.BlobCreated":
                data = event.get("data", {})
                url = data.get("url")
                blob_name = _parse_blob_name_from_url(url) if url else None
                blob_size = data.get("contentLength")
                event_time = event.get("eventTime")
                version_id = data.get("versionId")

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

                log_entry = {
                    "blob_name": blob_name,
                    "blob_size": blob_size,
                    "version_id": version_id,
                    "event_time": event_time,
                }
                logging.info(json.dumps(log_entry))

        return func.HttpResponse(status_code=200)

    except Exception as e:
        logging.exception("Error processing Event Grid event")
        return func.HttpResponse("Error", status_code=500)
