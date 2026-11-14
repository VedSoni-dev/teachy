//
//  FakeServers.swift
//
//  The two fake MCP servers the connector tests talk to. Both are small Python
//  scripts, written to a temp folder by the tests and run on this machine only.
//
//  - The stdio one speaks newline-delimited JSON-RPC on stdin/stdout.
//  - The HTTP one listens on 127.0.0.1 (random port) and serves streamable HTTP,
//    the older HTTP+SSE transport, and a pretend OAuth authorization server.
//

import Foundation

nonisolated enum FakeServers {
    static let stdioServerSource = #"""
import json, os, sys, time

def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()

if "--exit-immediately" in sys.argv:
    sys.stderr.write("fatal: missing configuration\n")
    sys.stderr.flush()
    sys.exit(7)

# A real server sometimes prints a banner on stdout. The client must survive it.
sys.stdout.write("fake server starting up\n")
sys.stdout.flush()
sys.stderr.write("fake server ready\n")
if os.environ.get("FAKE_SECRET"):
    sys.stderr.write("loaded key " + os.environ["FAKE_SECRET"] + "\n")
sys.stderr.flush()

TOOLS = [
    {"name": "echo", "description": "Says the text back.",
     "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]},
     "annotations": {"readOnlyHint": True, "openWorldHint": False}},
    {"name": "add", "description": "Adds two numbers.",
     "inputSchema": {"type": "object", "properties": {"a": {"type": "number"}, "b": {"type": "number"}}, "required": ["a", "b"]}},
    {"name": "delete everything!", "description": "Pretends to delete.",
     "inputSchema": {"type": "object"},
     "annotations": {"readOnlyHint": False, "destructiveHint": True}},
    {"name": "boom", "description": "Always fails.", "inputSchema": {"type": "object"},
     "annotations": {"readOnlyHint": False, "destructiveHint": False}},
    {"name": "crash", "description": "Kills the server.", "inputSchema": {"type": "object"}},
    {"name": "grow", "description": "Adds a tool and announces it.", "inputSchema": {"type": "object"}},
    {"name": "getenv", "description": "Reads an environment variable.", "inputSchema": {"type": "object"}},
    {"name": "argv", "description": "Returns the command-line arguments.", "inputSchema": {"type": "object"}},
    {"name": "ask_client", "description": "Sends requests to the client.", "inputSchema": {"type": "object"}},
    {"name": "client_answers", "description": "What the client answered.", "inputSchema": {"type": "object"}},
    {"name": "picture", "description": "Returns mixed content.", "inputSchema": {"type": "object"}},
]
client_answers = []

def text_result(text, is_error=False):
    result = {"content": [{"type": "text", "text": text}]}
    if is_error:
        result["isError"] = True
    return result

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    message = json.loads(line)
    method = message.get("method")
    request_id = message.get("id")
    params = message.get("params") or {}

    if method is None:
        client_answers.append(message)
        continue

    if method == "initialize":
        version = "1999-01-01" if "--bad-version" in sys.argv else params.get("protocolVersion")
        send({"jsonrpc": "2.0", "id": request_id, "result": {
            "protocolVersion": version,
            "capabilities": {"tools": {"listChanged": True}},
            "serverInfo": {"name": "fake-stdio", "version": "0.1"},
            "clientSeen": params.get("clientInfo"),
        }})
        sys.stderr.write("client " + json.dumps(params.get("clientInfo")) + " caps " + json.dumps(params.get("capabilities")) + "\n")
        sys.stderr.flush()
    elif method == "notifications/initialized":
        pass
    elif method == "ping":
        send({"jsonrpc": "2.0", "id": request_id, "result": {}})
    elif method == "tools/list":
        # Three pages, to exercise the cursor.
        cursor = params.get("cursor")
        start = int(cursor) if cursor else 0
        page = TOOLS[start:start + 4]
        result = {"tools": page}
        if start + 4 < len(TOOLS):
            result["nextCursor"] = str(start + 4)
        send({"jsonrpc": "2.0", "id": request_id, "result": result})
    elif method == "tools/call":
        name = params.get("name")
        arguments = params.get("arguments") or {}
        if name == "echo":
            send({"jsonrpc": "2.0", "id": request_id, "result": text_result(arguments.get("text", ""))})
        elif name == "add":
            total = arguments.get("a", 0) + arguments.get("b", 0)
            send({"jsonrpc": "2.0", "id": request_id, "result": text_result(str(total))})
        elif name == "boom":
            send({"jsonrpc": "2.0", "id": request_id, "result": text_result("it broke", True)})
        elif name == "crash":
            sys.stderr.write("fatal: crashing on request\n")
            sys.stderr.flush()
            os._exit(3)
        elif name == "grow":
            TOOLS.append({"name": "new_tool_%d" % len(TOOLS), "description": "Added later.", "inputSchema": {"type": "object"}})
            send({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
            send({"jsonrpc": "2.0", "id": request_id, "result": text_result("grew")})
        elif name == "getenv":
            send({"jsonrpc": "2.0", "id": request_id, "result": text_result(os.environ.get(arguments.get("name", ""), "(unset)"))})
        elif name == "argv":
            send({"jsonrpc": "2.0", "id": request_id, "result": text_result(json.dumps(sys.argv[1:]))})
        elif name == "ask_client":
            send({"jsonrpc": "2.0", "id": "srv-ping", "method": "ping"})
            send({"jsonrpc": "2.0", "id": "srv-sampling", "method": "sampling/createMessage", "params": {"messages": []}})
            send({"jsonrpc": "2.0", "id": "srv-roots", "method": "roots/list"})
            send({"jsonrpc": "2.0", "id": request_id, "result": text_result("asked")})
        elif name == "client_answers":
            send({"jsonrpc": "2.0", "id": request_id, "result": text_result(json.dumps(client_answers, sort_keys=True))})
        elif name == "picture":
            send({"jsonrpc": "2.0", "id": request_id, "result": {"content": [
                {"type": "text", "text": "here you go"},
                {"type": "image", "data": "aGk=", "mimeType": "image/png"},
            ]}})
        else:
            send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32602, "message": "Unknown tool: %s" % name}})
    elif request_id is not None:
        send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Method not found"}})
"""#

    static let httpServerSource = #"""
import base64, hashlib, json, os, queue, sys, threading, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {
    "session_number": 0,
    "sessions": set(),
    "expire_next": False,
    "tools": [
        {"name": "echo", "description": "Says the text back.",
         "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}},
         "annotations": {"readOnlyHint": True}},
        {"name": "whoami", "description": "Returns the session id the client sent.", "inputSchema": {"type": "object"}},
        {"name": "grow", "description": "Adds a tool and announces it on the GET stream.", "inputSchema": {"type": "object"}},
    ],
    "push": queue.Queue(),
    "legacy": {},
    "oauth_clients": {},
    "oauth_codes": {},
    "oauth_valid": set(),
    "oauth_refresh_count": 0,
    "oauth_authorize_seen": [],
}
LOCK = threading.Lock()

def text_result(text):
    return {"content": [{"type": "text", "text": text}]}

def answer(message, session_header):
    """Returns the JSON-RPC response for a request, or None for a notification."""
    method = message.get("method")
    request_id = message.get("id")
    params = message.get("params") or {}
    if request_id is None:
        return None
    if method == "initialize":
        return {"jsonrpc": "2.0", "id": request_id, "result": {
            "protocolVersion": params.get("protocolVersion"),
            "capabilities": {"tools": {"listChanged": True}},
            "serverInfo": {"name": "fake-http", "version": "0.1"}}}
    if method == "ping":
        return {"jsonrpc": "2.0", "id": request_id, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": request_id, "result": {"tools": STATE["tools"]}}
    if method == "tools/call":
        name = params.get("name")
        arguments = params.get("arguments") or {}
        if name == "echo":
            return {"jsonrpc": "2.0", "id": request_id, "result": text_result(arguments.get("text", ""))}
        if name == "whoami":
            return {"jsonrpc": "2.0", "id": request_id, "result": text_result(session_header or "(none)")}
        if name == "grow":
            STATE["tools"].append({"name": "later_%d" % len(STATE["tools"]), "description": "Added later.", "inputSchema": {"type": "object"}})
            STATE["push"].put({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
            return {"jsonrpc": "2.0", "id": request_id, "result": text_result("grew")}
        return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32602, "message": "Unknown tool"}}
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Method not found"}}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def base(self):
        return "http://127.0.0.1:%d" % self.server.server_address[1]

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def reply(self, status, payload=None, headers=None, content_type="application/json"):
        data = b"" if payload is None else (payload if isinstance(payload, bytes) else json.dumps(payload).encode())
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        if data:
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def event(self, name, data):
        text = ""
        if name:
            text += "event: %s\n" % name
        for line in data.split("\n"):
            text += "data: %s\n" % line
        self.wfile.write((text + "\n").encode())
        self.wfile.flush()

    # -- who may come in ---------------------------------------------------
    def allowed(self, path):
        if path.startswith("/token/"):
            return self.headers.get("Authorization") == "Bearer good-token"
        if path.startswith("/key/"):
            return self.headers.get("X-API-Key") == "key-123"
        if path.startswith("/oauth/"):
            header = self.headers.get("Authorization") or ""
            return header.startswith("Bearer ") and header[7:] in STATE["oauth_valid"]
        return True

    def refuse(self, path):
        headers = {}
        if path.startswith("/oauth/"):
            headers["WWW-Authenticate"] = 'Bearer realm="fake", resource_metadata="%s/.well-known/oauth-protected-resource/oauth/mcp"' % self.base()
        else:
            headers["WWW-Authenticate"] = 'Bearer realm="fake"'
        self.reply(401, {"error": "unauthorized"}, headers)

    # -- GET ---------------------------------------------------------------
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = dict(urllib.parse.parse_qsl(parsed.query))

        if path == "/.well-known/oauth-protected-resource/oauth/mcp":
            return self.reply(200, {"resource": self.base() + "/oauth/mcp",
                                    "authorization_servers": [self.base() + "/as"],
                                    "scopes_supported": ["tools.read", "tools.write"]})
        if path == "/.well-known/oauth-authorization-server/as":
            return self.reply(200, {"issuer": self.base() + "/as",
                                    "authorization_endpoint": self.base() + "/as/authorize",
                                    "token_endpoint": self.base() + "/as/token",
                                    "registration_endpoint": self.base() + "/as/register",
                                    "code_challenge_methods_supported": ["S256"]})
        if path == "/as/authorize":
            client = STATE["oauth_clients"].get(query.get("client_id"))
            redirect = query.get("redirect_uri")
            if not client or redirect not in client["redirect_uris"]:
                return self.reply(400, {"error": "invalid_client"})
            if query.get("code_challenge_method") != "S256" or not query.get("code_challenge"):
                return self.reply(400, {"error": "pkce_required"})
            STATE["oauth_authorize_seen"].append(query)
            code = "code-%d" % (len(STATE["oauth_codes"]) + 1)
            STATE["oauth_codes"][code] = {"challenge": query["code_challenge"], "redirect": redirect,
                                          "client": query["client_id"], "resource": query.get("resource")}
            location = redirect + "?" + urllib.parse.urlencode({"code": code, "state": query.get("state", "")})
            return self.reply(302, None, {"Location": location})
        if path == "/test/oauth-log":
            return self.reply(200, {"authorize": STATE["oauth_authorize_seen"], "refreshes": STATE["oauth_refresh_count"],
                                    "clients": STATE["oauth_clients"]})

        if path == "/legacy/sse":
            session = "legacy-%d" % (len(STATE["legacy"]) + 1)
            outbox = queue.Queue()
            STATE["legacy"][session] = outbox
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                self.wfile.write(b": hello, this is a comment\n\n")
                self.event("endpoint", "/legacy/messages?session=%s" % session)
                while True:
                    try:
                        message = outbox.get(timeout=0.25)
                    except queue.Empty:
                        self.wfile.write(b": keep-alive\n\n")
                        self.wfile.flush()
                        continue
                    self.event("message", json.dumps(message))
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            return

        if path == "/open/mcp" and "text/event-stream" in (self.headers.get("Accept") or ""):
            # The optional server-to-client stream of streamable HTTP.
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            try:
                while True:
                    try:
                        message = STATE["push"].get(timeout=0.25)
                    except queue.Empty:
                        self.wfile.write(b": keep-alive\n\n")
                        self.wfile.flush()
                        continue
                    self.event(None, json.dumps(message))
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            return

        if path.endswith("/mcp"):
            if not self.allowed(path):
                return self.refuse(path)
            return self.reply(405, {"error": "no stream here"})
        self.reply(404, {"error": "not found"})

    # -- DELETE ------------------------------------------------------------
    def do_DELETE(self):
        self.reply(200, {})

    # -- POST --------------------------------------------------------------
    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = dict(urllib.parse.parse_qsl(parsed.query))
        raw = self.body()

        if path == "/as/register":
            registration = json.loads(raw or b"{}")
            client_id = "client-%d" % (len(STATE["oauth_clients"]) + 1)
            STATE["oauth_clients"][client_id] = registration
            return self.reply(201, {"client_id": client_id, "redirect_uris": registration.get("redirect_uris")})
        if path == "/as/token":
            form = dict(urllib.parse.parse_qsl(raw.decode()))
            if form.get("grant_type") == "authorization_code":
                issued = STATE["oauth_codes"].pop(form.get("code"), None)
                digest = hashlib.sha256((form.get("code_verifier") or "").encode()).digest()
                challenge = base64.urlsafe_b64encode(digest).decode().rstrip("=")
                if (not issued or issued["challenge"] != challenge or issued["redirect"] != form.get("redirect_uri")
                        or issued["client"] != form.get("client_id") or issued["resource"] != form.get("resource")):
                    return self.reply(400, {"error": "invalid_grant", "error_description": "PKCE or redirect mismatch"})
                STATE["oauth_valid"].add("access-1")
                return self.reply(200, {"access_token": "access-1", "token_type": "Bearer", "expires_in": 3600,
                                        "refresh_token": "refresh-1"})
            if form.get("grant_type") == "refresh_token":
                if form.get("refresh_token") != "refresh-1":
                    return self.reply(400, {"error": "invalid_grant"})
                STATE["oauth_refresh_count"] += 1
                token = "access-%d" % (STATE["oauth_refresh_count"] + 1)
                STATE["oauth_valid"].add(token)
                return self.reply(200, {"access_token": token, "token_type": "Bearer", "expires_in": 3600})
            return self.reply(400, {"error": "unsupported_grant_type"})
        if path == "/test/revoke-access-tokens":
            STATE["oauth_valid"].clear()
            return self.reply(200, {})
        if path == "/test/expire-session":
            STATE["expire_next"] = True
            return self.reply(200, {})

        if path == "/legacy/sse":
            return self.reply(405, {"error": "use GET"})
        if path == "/legacy/messages":
            outbox = STATE["legacy"].get(query.get("session"))
            if outbox is None:
                return self.reply(404, {"error": "no such session"})
            response = answer(json.loads(raw), None)
            if response is not None:
                outbox.put(response)
            return self.reply(202)

        if path.endswith("/mcp"):
            if not self.allowed(path):
                return self.refuse(path)
            message = json.loads(raw)
            method = message.get("method")
            session_header = self.headers.get("Mcp-Session-Id")
            headers = {}
            if method == "initialize":
                with LOCK:
                    STATE["session_number"] += 1
                    issued = "sess-%d" % STATE["session_number"]
                    STATE["sessions"].add(issued)
                headers["Mcp-Session-Id"] = issued
            else:
                with LOCK:
                    known = session_header in STATE["sessions"]
                    if known and STATE["expire_next"]:
                        STATE["sessions"].discard(session_header)
                        STATE["expire_next"] = False
                        return self.reply(404, {"error": "session expired"})
                if not known:
                    return self.reply(400, {"error": "missing or wrong Mcp-Session-Id"})
                if not self.headers.get("MCP-Protocol-Version"):
                    return self.reply(400, {"error": "missing MCP-Protocol-Version"})
            response = answer(message, session_header)
            if response is None:
                return self.reply(202, None, headers)
            if method == "tools/list":
                # Answer as an SSE stream: a notification first, then the response spread over several data lines.
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                for name, value in headers.items():
                    self.send_header(name, value)
                self.end_headers()
                self.wfile.write(b": about to answer\n\n")
                self.event("message", json.dumps({"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "info", "data": "listing"}}))
                self.event(None, json.dumps(response, indent=2))
                return
            return self.reply(200, response, headers)
        self.reply(404, {"error": "not found"})

def exit_when_parent_goes_away():
    sys.stdin.read()
    os._exit(0)

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
threading.Thread(target=exit_when_parent_goes_away, daemon=True).start()
sys.stdout.write("PORT %d\n" % server.server_address[1])
sys.stdout.flush()
server.serve_forever()
"""#
}
