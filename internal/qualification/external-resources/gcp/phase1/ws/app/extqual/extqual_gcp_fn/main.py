import json
import os
import uuid

from google.api_core.exceptions import Forbidden, PermissionDenied
from google.cloud import pubsub_v1, storage


def main():
    publisher = pubsub_v1.PublisherClient()
    subscriber = pubsub_v1.SubscriberClient()
    storage_client = storage.Client()
    project = os.environ["GOOGLE_CLOUD_PROJECT"]
    topic = publisher.topic_path(project, os.environ["TOPIC"])
    subscription = subscriber.subscription_path(project, os.environ["SUBSCRIPTION"])
    bucket = storage_client.bucket(os.environ["BUCKET"])
    marker = "extqual-gcp-" + uuid.uuid4().hex
    message_id = publisher.publish(topic, marker.encode()).result(timeout=30)
    response = subscriber.pull(
        request={"subscription": subscription, "max_messages": 1}, timeout=30
    )
    if not response.received_messages:
        raise SystemExit("no message received")
    received = response.received_messages[0]
    if received.message.data.decode() != marker:
        raise SystemExit("unexpected message")
    subscriber.acknowledge(request={"subscription": subscription, "ack_ids": [received.ack_id]})
    key = "extqual/" + marker + ".json"
    body = json.dumps({"marker": marker, "message_id": message_id}).encode()
    blob = bucket.blob(key)
    blob.upload_from_string(body, content_type="application/json")
    if blob.download_as_bytes() != body:
        raise SystemExit("object round trip mismatch")
    denied = []
    negative_topic = os.environ.get("NEGATIVE_TOPIC", "")
    if negative_topic:
        try:
            publisher.publish(
                publisher.topic_path(project, negative_topic), b"must-not-publish"
            ).result(timeout=30)
        except (Forbidden, PermissionDenied):
            denied.append("publish")
        else:
            raise SystemExit("publish to an unrelated topic was allowed")
    negative_bucket = os.environ.get("NEGATIVE_BUCKET", "")
    if negative_bucket:
        try:
            storage_client.bucket(negative_bucket).blob("must-not-write").upload_from_string(
                b"must-not-write"
            )
        except (Forbidden, PermissionDenied):
            denied.append("object-write")
        else:
            raise SystemExit("write to an unrelated bucket was allowed")
    print(
        json.dumps(
            {
                "status": "ok",
                "message_id": message_id,
                "object_key": key,
                "denied": denied,
            }
        )
    )


if __name__ == "__main__":
    main()
