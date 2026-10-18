#!/usr/bin/env python3
"""Local OpenAI-compatible fixture for Simulator integration tests; no model download or cloud traffic.

Run: python3 scripts/model-fixture-server.py
Then run AgoraTests/ModelIntegrationTests/testLoopbackServerChatToolsCaptionAndRecognition.
The listener defaults to 127.0.0.1:18766. It logs no request bodies, media, credentials or model messages.
"""

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FIXTURE_ID = "agora-model-fixture-v1"
MODEL_ID = "agora-fixture/vision:local"


def answer(body):
    messages = body.get("messages", [])
    tools = body.get("tools", [])
    schema = body.get("response_format", {}).get("json_schema", {}).get("schema")
    if tools and not any(message.get("role") == "tool" for message in messages):
        names = [tool.get("function", {}).get("name") for tool in tools]
        name = "browser_observe" if "browser_observe" in names else names[0]
        return None, [{"id": "fixture-observe-1", "type": "function", "function": {
            "name": name, "arguments": "{}"}}], "tool_calls"
    if tools:
        return "The browser tool completed. Open a page to continue.", [], "stop"
    if schema is not None:
        item_schema = schema.get("properties", {}).get("items", {}).get("items", {}).get("properties", {})
        if "count" in item_schema:
            item = {"name": "milk", "brand": None, "category": "dairy", "count": 2,
                    "fill_fraction": None, "box": [100, 100, 800, 800], "confidence": 0.93}
        else:
            item = {"name": "Milk", "category": "dairy", "unit": "cartons", "quantity": 2, "confidence": 0.93}
        return json.dumps({"items": [item]}), [], "stop"
    if any(isinstance(message.get("content"), list) and any(
            part.get("type") == "image_url" for part in message["content"]) for message in messages):
        return "A blue square on a plain background.", [], "stop"
    return "Hello from the local model fixture.", [], "stop"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send_json(self, value, status=200):
        encoded = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if self.path == "/healthz":
            self.send_json({"fixture": FIXTURE_ID})
        elif self.path == "/v1/models":
            self.send_json({"object": "list", "data": [{"id": MODEL_ID, "object": "model"}]})
        else:
            self.send_json({"error": "not_found"}, 404)

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_json({"error": "not_found"}, 404)
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 8_000_000:
                self.send_json({"error": "invalid_body_size"}, 413)
                return
            body = json.loads(self.rfile.read(size))
            if not isinstance(body, dict) or not isinstance(body.get("messages"), list):
                raise ValueError()
            text, calls, finish = answer(body)
            message = {"role": "assistant", "content": text}
            if calls:
                message["tool_calls"] = calls
            if not body.get("stream"):
                self.send_json({"id": "fixture-completion", "object": "chat.completion", "model": MODEL_ID,
                                "choices": [{"index": 0, "finish_reason": finish, "message": message}]})
                return
            delta = {"role": "assistant"}
            if text is not None:
                delta["content"] = text
            if calls:
                delta["tool_calls"] = [{"index": i, **call} for i, call in enumerate(calls)]
            event = json.dumps({"choices": [{"index": 0, "delta": delta, "finish_reason": finish}]})
            encoded = f"data: {event}\n\ndata: [DONE]\n\n".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
        except (ValueError, TypeError, KeyError, AttributeError):
            self.send_json({"error": "invalid_request"}, 400)
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=18766)
    args = parser.parse_args()
    with ThreadingHTTPServer(("127.0.0.1", args.port), Handler) as server:
        print(f"{FIXTURE_ID} listening on http://127.0.0.1:{args.port}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
