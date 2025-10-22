import boto3
import os
import json
from datetime import datetime

HOST = os.environ.get("LOCALSTACK_HOSTNAME", "localhost")
ENDPOINT = f"http://{HOST}:4566"

dynamo = boto3.client("dynamodb", endpoint_url=ENDPOINT, region_name="us-east-1")

def lambda_handler(event, context):
    path = event.get("path", "")
    method = event.get("httpMethod", "")
    params = event.get("queryStringParameters") or {}

    if path.endswith("/files") and method == "GET":
        return list_files(params)
    elif "/files/" in path and method == "GET":
        file_id = path.rsplit("/", 1)[-1]
        pk = f"file#{file_id}"
        return get_file(pk)
    else:
        return {"statusCode": 404, "body": json.dumps({"error": "Not found"})}

def list_files(params):
    resp = dynamo.scan(TableName="files", Limit=100)
    items = [parse_item(i) for i in resp.get("Items", [])]

    status = params.get("status")
    dt_from = params.get("from")
    dt_to = params.get("to")

    def within(item):
        if status and item.get("status") != status:
            return False
        if dt_from and item.get("processedAt") and item["processedAt"] < dt_from:
            return False
        if dt_to and item.get("processedAt") and item["processedAt"] > dt_to:
            return False
        return True

    items = [i for i in items if within(i)]
    return {"statusCode": 200, "body": json.dumps(items)}

def get_file(pk):
    resp = dynamo.get_item(TableName="files", Key={"pk": {"S": pk}})
    item = resp.get("Item")
    if not item:
        return {"statusCode": 404, "body": json.dumps({"error": "Item not found"})}
    return {"statusCode": 200, "body": json.dumps(parse_item(item))}

def parse_item(item):
    return {k: list(v.values())[0] for k, v in item.items()}
