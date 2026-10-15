"""Deterministic OpenAI SSE fixture. Only run on the CI runner's loopback."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ready")

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert self.path.endswith("/chat/completions"), self.path
        assert request["stream"] is True
        marks = {"marks": [
            {"l": 0, "q": "LifeNarrator visible English paragraph", "t": "A little company", "e": "✨"},
            {"l": 1, "q": "又要上班了", "t": "辛苦啦，慢慢来", "e": "😺"},
        ]}
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        content = json.dumps(marks, ensure_ascii=False)
        for offset in range(0, len(content), 24):
            chunk = {"choices": [{"delta": {"content": content[offset:offset + 24]}}]}
            self.wfile.write(("data: " + json.dumps(chunk, ensure_ascii=False) + "\n\n").encode())
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18765), Handler).serve_forever()
