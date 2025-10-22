import hashlib

def calculate_sha256(stream):
    hasher = hashlib.sha256()
    for chunk in iter(lambda: stream.read(4096), b""):
        hasher.update(chunk)
    return hasher.hexdigest()
