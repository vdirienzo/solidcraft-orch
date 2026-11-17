#!/usr/bin/env python3
"""A stand-in ACP agent for the evidence of #17070.

It speaks the Agent Client Protocol over stdin/stdout (one JSON-RPC line per
message), so the question card in SolidCraft's Assistant panel is produced by
the real protocol path and not by a mock: `initialize`, `session/new`, and then,
on a prompt, the agent's own question (`elicitation/create`).

    fake_acp_agent.py <form|link> [logfile]

`form` asks a question with choices (the panel shows a button per choice, plus
Decline and Cancel). `link` asks a question with an address (the panel shows
the address and its Open button).

Everything the agent reads and writes goes to the log file, so the evidence can
show what the agent really said.
"""
import json
import sys

MODE = sys.argv[1] if len(sys.argv) > 1 else "form"
LOG = open(sys.argv[2], "a", buffering=1) if len(sys.argv) > 2 else None

SESSION = "sess_evidence_17070"

FORM_QUESTION = {
    "sessionId": SESSION,
    "mode": "form",
    "message": "Which approach should I take for the bracket?",
    "requestedSchema": {
        "type": "object",
        "properties": {
            "approach": {
                "type": "string",
                "enum": ["conservative", "balanced", "aggressive"],
                "description": "How much of the design the agent may change on its own",
            }
        },
        "required": ["approach"],
    },
}

LINK_QUESTION = {
    "sessionId": SESSION,
    "mode": "url",
    "message": "Open this page to let the agent connect to your account.",
    "url": "https://agent.example.com/oauth/authorize?client_id=solidcraft&scope=design%20read%20write&state=7f3c1d",
}


def send(obj):
    line = json.dumps(obj)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()
    if LOG:
        LOG.write("agent -> app  " + line + "\n")


def note(obj):
    if LOG:
        LOG.write("app -> agent  " + json.dumps(obj) + "\n")


def main():
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            msg = json.loads(raw)
        except ValueError:
            continue
        note(msg)
        method = msg.get("method")
        mid = msg.get("id")
        if method is None:
            # A reply to one of our own requests: the user answered the question.
            continue
        if method == "initialize":
            send({
                "jsonrpc": "2.0",
                "id": mid,
                "result": {
                    "protocolVersion": 1,
                    "agentInfo": {"name": "Evidence Agent", "version": "1.0.0"},
                    "agentCapabilities": {},
                    "authMethods": [],
                },
            })
        elif method == "session/new":
            send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": SESSION}})
        elif method == "session/prompt":
            # The agent asks the user a question of its own, and waits for the answer.
            send({
                "jsonrpc": "2.0",
                "id": 9001,
                "method": "elicitation/create",
                "params": FORM_QUESTION if MODE == "form" else LINK_QUESTION,
            })
        elif method in ("session/set_mode", "session/set_model", "session/set_config_option"):
            send({"jsonrpc": "2.0", "id": mid, "result": {}})
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "not served"}})


if __name__ == "__main__":
    main()
