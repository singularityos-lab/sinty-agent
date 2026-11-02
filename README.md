# Sinty Agent

Lets a model control Sinty OS: open apps, run what they expose, read what they
show. The model is the user's choice, local or remote, and connects over MCP.
The feature is off by default.

## Components

- `cmd/sinty-agentd/`: session daemon. Serves MCP on
  `$XDG_RUNTIME_DIR/sinty-agent/mcp.sock`, owns `dev.sinty.Agent` on the session bus,
  applies the mode, asks for confirmations and writes receipts.
- `cmd/sinty-agent/`: `sinty-agent mcp` bridges stdio to the daemon for MCP clients.
  The other commands change the mode, stop the agent and answer confirmations.

## Modes

- `plan`: reads only.
- `ask`: runs what can be undone, confirms the rest.
- `auto`: confirms what cannot be undone only after reading outside content.
- `autopilot`: never confirms.

Every call ends in `$XDG_STATE_HOME/sinty-agent/receipts.jsonl`. `sinty-agent stop`
refuses all calls until `resume`.

## Build

Zig 0.16, GLib and GIO.

    zig build
    zig build test

## License

GPL-3.0-only.
