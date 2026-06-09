import os
from flask import Flask, jsonify

app = Flask(__name__)
GREETING = os.environ.get("APP_GREETING", "hello")


@app.get("/")
def root():
    return jsonify(message=GREETING, source="api")


@app.get("/health")
def health():
    return jsonify(status="ok")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
