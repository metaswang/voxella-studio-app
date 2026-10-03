#!/usr/bin/env python3
"""Exercise both running local MCP profiles without saving source text or IDs.

Requires the signed VoxStudio app. --preview generates one bounded temporary
preview through the existing media tool. No cloud answer model is called.
"""
import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path


class Client:
    def __init__(self, port):
        self.base = f"http://127.0.0.1:{port}"
        self.sequence = 0

    def rpc(self, path, method, params=None, session=None, notification=False):
        self.sequence += 1
        payload = {"jsonrpc": "2.0", "method": method}
        if not notification:
            payload["id"] = self.sequence
        if params is not None:
            payload["params"] = params
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                   "MCP-Protocol-Version": "2025-06-18"}
        if session:
            headers["Mcp-Session-Id"] = session
        request = urllib.request.Request(self.base + path, data=json.dumps(payload).encode(), headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                text, body = response.read().decode(), None
                if text and "text/event-stream" in response.headers.get("Content-Type", ""):
                    for line in text.splitlines():
                        if line.startswith("data:") and line[5:].strip():
                            item = json.loads(line[5:].strip())
                            if isinstance(item, dict) and ("result" in item or "error" in item):
                                body = item
                elif text:
                    body = json.loads(text)
                return response.status, response.headers, body
        except urllib.error.HTTPError as error:
            return error.code, error.headers, None

    def call(self, name, args, session, path="/knowledge/mcp", check=True):
        print(f"Checking {path}: {name}", file=sys.stderr, flush=True)
        status, _, body = self.rpc(path, "tools/call", {"name": name, "arguments": args}, session)
        assert status == 200 and body and "result" in body, f"{name}: HTTP/RPC failure ({status})"
        result = body["result"]
        if check:
            assert not result.get("isError"), f"{name}: tool error (source details omitted)"
        raw = next(x["text"] for x in result["content"] if x["type"] == "text")
        try:
            value = json.loads(raw)
        except json.JSONDecodeError:
            assert result.get("isError"), f"{name}: expected JSON"
            value = {"status": "error"}
        if path == "/knowledge/mcp":
            assert result["structuredContent"] == value, f"{name}: JSON/structuredContent differ"
            assert "status" in value and "complete" in value, f"{name}: incomplete output contract"
        return value, result.get("isError", False)


def check(port, preview=False):
    client, sessions, inventories = Client(port), {}, {}
    for path in ("/mcp", "/knowledge/mcp"):
        status, headers, body = client.rpc(path, "initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "knowledge-acceptance", "version": "1"}})
        assert status == 200 and body and "result" in body, f"{path}: initialization failed"
        sessions[path] = headers["Mcp-Session-Id"]
        client.rpc(path, "notifications/initialized", session=sessions[path], notification=True)
        status, _, listed = client.rpc(path, "tools/list", session=sessions[path])
        assert status == 200 and listed, f"{path}: tool discovery failed"
        inventories[path] = listed["result"]["tools"]
    knowledge, legacy = sessions["/knowledge/mcp"], sessions["/mcp"]
    expected = {"search", "fetch", "list_sources", "aggregate", "find_text", "methods"}
    assert {x["name"] for x in inventories["/knowledge/mcp"]} == expected
    assert all(x["annotations"]["readOnlyHint"] and "outputSchema" in x for x in inventories["/knowledge/mcp"])
    legacy_names = {x["name"] for x in inventories["/mcp"]}
    assert {"knowledge.ask", "media.preview", "capture_frame", "search_media"} <= legacy_names
    for path, foreign in (("/mcp", knowledge), ("/knowledge/mcp", legacy)):
        assert client.rpc(path, "tools/list", session=foreign)[0] == 404
    for path in inventories:
        status, _, body = client.rpc(path, "tools/list")
        assert status == 200 and {x["name"] for x in body["result"]["tools"]} == {x["name"] for x in inventories[path]}
    catalog, _ = client.call("list_sources", {"origin": "local", "limit": 100}, knowledge)
    aggregate, _ = client.call("aggregate", {"origin": "local"}, knowledge)
    assert catalog["total_count"] == aggregate["aggregate"]["count"]
    methods, _ = client.call("methods", {}, knowledge)
    if methods["methods"]:
        client.call("methods", {"action": "read", "method_id": methods["methods"][0]["method_id"]}, knowledge)
    report = {"knowledge_tools": sorted(expected), "legacy_tool_count": len(legacy_names), "profile_isolation": True,
              "stateless_inventory_isolation": True, "structured_content_matches_json": True,
              "local_source_count": catalog["total_count"], "methods_enabled": len(methods["methods"])}
    readable = next((x for x in catalog["sources"] if x.get("body_readable")), None)
    if readable:
        source_id = readable["source_id"]
        body, _ = client.call("fetch", {"source_id": source_id, "limit": 1}, knowledge)
        term = body["segments"][0]["text"].strip()[:12]
        found, _ = client.call("find_text", {"source_id": source_id, "text": term}, knowledge)
        assert found["occurrence_count"] > 0
        hits, _ = client.call("search", {"source_id": source_id, "query": term, "rerank": "none"}, knowledge)
        assert hits["results"] and all(x["material_kind"] in ("transcript", "subtitle_fallback") for x in hits["results"])
        fetched, _ = client.call("fetch", {"evidence_id": hits["results"][0]["evidence_id"], "limit": 1}, knowledge)
        assert fetched["segments"]
        report.update(canonical_search=True, canonical_fetch=True, literal_find=True, evidence_fetch=True)
        fetched, _ = client.call("session.get_segments", {"session_id": source_id, "limit": 1, "origin": "local"}, legacy, "/mcp")
        report["legacy_body_read"] = bool(fetched.get("segments"))
    subtitle = next((x for x in catalog["sources"] if x.get("subtitle_track_available")), None)
    if subtitle:
        source_id = subtitle["source_id"]
        body, _ = client.call("fetch", {"source_id": source_id, "material": "subtitles", "limit": 1}, knowledge)
        term = body["segments"][0]["text"].strip()[:12]
        hits, _ = client.call("search", {"source_id": source_id, "target": "subtitle_passages", "query": term, "rerank": "none"}, knowledge)
        assert hits["results"] and all(x["material_kind"] == "subtitles" for x in hits["results"])
        clips, _ = client.call("search", {"source_id": source_id, "target": "media_clips", "query": term, "rerank": "none"}, knowledge)
        report.update(explicit_subtitle_search=True, media_search_returned_count=len(clips["results"]))
        if clips["results"]:
            media, _ = client.call("fetch", {"evidence_id": clips["results"][0]["evidence_id"]}, knowledge)
            assert media.get("kind") == "media_clip" and media.get("visual_verified") is False
            report.update(media_fetch=True, media_locator_available=bool(media.get("media_path") or media.get("preview_locator")))
        if preview:
            _, error = client.call("media.preview", {"session_id": source_id, "duration": 1}, legacy, "/mcp", check=False)
            report["legacy_media_preview_status"] = "error" if error else "ok"
    for name, args in (("fetch", {"source_id": "00000000-0000-0000-0000-000000000099"}), ("search", {"query": "test", "origin": "invalid"})):
        _, error = client.call(name, args, knowledge, check=False)
        assert error
    report["authorization_and_schema_errors"] = True
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=19789)
    parser.add_argument("--preview", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        report = json.dumps(check(args.port, args.preview), indent=2) + "\n"
        if args.output:
            args.output.write_text(report)
        print(report, end="")
    except (AssertionError, OSError, KeyError, StopIteration, ValueError) as error:
        parser.exit(1, f"MCP acceptance failed: {error}\n")
