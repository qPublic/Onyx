import json, http.server, sys
LOG = sys.argv[1]
def log(d):
    with open(LOG, "a") as f: f.write(json.dumps(d) + "\n")
def has_image(msgs):
    for m in msgs:
        c = m.get("content")
        if isinstance(c, list):
            for p in c:
                if p.get("type") in ("image", "image_url"): return True
    return False
def text_of(msgs):
    out = []
    for m in msgs:
        c = m.get("content")
        if isinstance(c, str): out.append(c)
        elif isinstance(c, list):
            for p in c:
                if p.get("type") == "text": out.append(p.get("text", ""))
    return " ".join(out)
class H(http.server.BaseHTTPRequestHandler):
    def reply(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
    def do_GET(self):
        log({"get": self.path, "auth": self.headers.get("Authorization"), "xkey": self.headers.get("x-api-key")})
        self.reply(200, {"data": [{"id": "mock-large"}, {"id": "mock-small"}, {"id": "text-embedding-3"}]})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        msgs = body.get("messages", [])
        anth = self.path.endswith("/messages")
        ok = (self.headers.get("x-api-key") == "mock-key" and self.headers.get("anthropic-version")) if anth else self.headers.get("Authorization") == "Bearer mock-key"
        entry = {"path": self.path, "model": body.get("model"), "tools": len(body.get("tools", [])), "image": has_image(msgs), "n": len(msgs), "system": bool(body.get("system")) or any(m.get("role") == "system" for m in msgs), "auth_ok": bool(ok)}
        log(entry)
        if not ok: return self.reply(401, {"error": {"message": "invalid key"}})
        t = text_of(msgs)
        if anth:
            tool_done = any(isinstance(m.get("content"), list) and any(p.get("type") == "tool_result" for p in m["content"]) for m in msgs)
            if tool_done: return self.reply(200, {"content": [{"type": "text", "text": "17 × 23 = 391."}], "stop_reason": "end_turn"})
            if body.get("tools") and "17 times 23" in t:
                return self.reply(200, {"content": [{"type": "text", "text": "Let me calculate."}, {"type": "tool_use", "id": "tu1", "name": "calculate", "input": {"expression": "17*23"}}], "stop_reason": "tool_use"})
            if has_image(msgs): return self.reply(200, {"content": [{"type": "text", "text": "The picture says Invoice 4417."}]})
            return self.reply(200, {"content": [{"type": "text", "text": "Hello from mock Claude."}]})
        else:
            tool_done = any(m.get("role") == "tool" for m in msgs)
            if tool_done: return self.reply(200, {"choices": [{"message": {"role": "assistant", "content": "17 × 23 = 391."}}]})
            if body.get("tools") and "17 times 23" in t:
                return self.reply(200, {"choices": [{"message": {"role": "assistant", "content": None, "tool_calls": [{"id": "c1", "type": "function", "function": {"name": "calculate", "arguments": "{\"expression\": \"17*23\"}"}}]}}]})
            if has_image(msgs): return self.reply(200, {"choices": [{"message": {"role": "assistant", "content": "The picture says Invoice 4417."}}]})
            return self.reply(200, {"choices": [{"message": {"role": "assistant", "content": "Hello from mock GPT."}}]})
http.server.HTTPServer(("127.0.0.1", 8765), H).serve_forever()
