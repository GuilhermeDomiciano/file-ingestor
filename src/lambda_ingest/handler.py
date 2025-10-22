import boto3
import os
import json
from datetime import datetime
from utils.checksum import calculate_sha256

HOST = os.environ.get("LOCALSTACK_HOSTNAME", "localhost")
ENDPOINT = f"http://{HOST}:4566"

dynamo = boto3.client("dynamodb", endpoint_url=ENDPOINT, region_name="us-east-1")
s3 = boto3.client("s3", endpoint_url=ENDPOINT, region_name="us-east-1")

def lambda_handler(event, context):
    print("Evento recebido:", json.dumps(event))
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = record["s3"]["object"]["key"]

        head = s3.head_object(Bucket=bucket, Key=key)
        size = head["ContentLength"]
        etag = head["ETag"].strip('"')
        content_type = head.get("ContentType", "unknown")

        obj = s3.get_object(Bucket=bucket, Key=key)
        checksum = calculate_sha256(obj["Body"])

        pk = f"file#{key}"

        # status RAW
        dynamo.put_item(
            TableName="files",
            Item={
                "pk": {"S": pk},
                "bucket": {"S": bucket},
                "key": {"S": key},
                "size": {"N": str(size)},
                "etag": {"S": etag},
                "status": {"S": "RAW"},
                "contentType": {"S": content_type},
                "checksum": {"S": checksum},
            },
        )

        dest_bucket = "ingestor-processed"
        s3.copy_object(Bucket=dest_bucket, CopySource={"Bucket": bucket, "Key": key}, Key=key)
        s3.delete_object(Bucket=bucket, Key=key)

        now = datetime.utcnow().isoformat()
        dynamo.update_item(
            TableName="files",
            Key={"pk": {"S": pk}},
            UpdateExpression="SET #st = :p, processedAt = :t",
            ExpressionAttributeNames={"#st": "status"},
            ExpressionAttributeValues={":p": {"S": "PROCESSED"}, ":t": {"S": now}},
        )

    return {"statusCode": 200, "body": json.dumps({"message": "Processamento concluído!"})}
