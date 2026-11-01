# HydraSRT Backend API Documentation

This document outlines the available API endpoints for the HydraSRT backend.

## Authentication

All API requests (except `/health` and `/api/login`) require authentication via a Bearer token.
The token is obtained by logging in and should be sent in the `Authorization` header.

**Header Format:**
`Authorization: Bearer <token>`

### Health Check

*   **Endpoint:** `GET /health`
*   **Description:** Checks if the service is running.
*   **Response:** `200 OK`

### Login

*   **Endpoint:** `POST /api/login`
*   **Description:** Authenticates a user and returns a session token.
*   **Payload:**
    ```json
    {
      "login": {
        "user": "your_username",
        "password": "your_password"
      }
    }
    ```
*   **Response:**
    ```json
    {
      "token": "generated_token",
      "user": "username"
    }
    ```
*   **Response:** `401 Unauthorized`
    ```json
    {
      "error": {
        "code": "INVALID_CREDENTIALS",
        "message": "Invalid username or password"
      }
    }
    ```
*   **Response:** `400 Bad Request`
    ```json
    {
      "error": {
        "code": "INVALID_REQUEST",
        "message": "Invalid request format"
      }
    }
    ```

## Routes Management

### List Routes

*   **Endpoint:** `GET /api/routes`
*   **Description:** Retrieves a list of all configured routes.
*   **Response:**
    ```json
    {
      "data": [
        {
          "id": "route_id",
          "name": "Route Name",
          ...
        }
      ]
    }
    ```

### Create Route

*   **Endpoint:** `POST /api/routes`
*   **Description:** Creates a new route.
*   **Payload:**
    ```json
    {
      "route": {
        "name": "New Route",
        "type": "caller|listener|rendezvous",
        ...
      }
    }
    ```
*   **Response:** `201 Created` with created route data.

### Get Route

*   **Endpoint:** `GET /api/routes/:id`
*   **Description:** Retrieves details of a specific route.
*   **Response:** Route object.

### Update Route

*   **Endpoint:** `PUT /api/routes/:id`
*   **Description:** Updates an existing route.
*   **Payload:**
    ```json
    {
      "route": { ... }
    }
    ```
*   **Response:** Updated route object.

### Delete Route

*   **Endpoint:** `DELETE /api/routes/:id`
*   **Description:** Deletes a route.
*   **Response:** `204 No Content`

### Route Power Control

*   **Start Route:** `GET /api/routes/:route_id/start`
*   **Stop Route:** `GET /api/routes/:route_id/stop`
*   **Restart Route:** `GET /api/routes/:route_id/restart`

### Route Statistics Reset

Operators can set a display baseline for accumulating SRT and byte counters on a running route. A reset does **not** clear the underlying SRT socket counters. GStreamer exposes no API to zero those counters, so HydraSRT records a baseline snapshot and subtracts it for display only. Raw counters and all data written to VictoriaMetrics stay monotonic and unchanged.

When a baseline is active, the live stats snapshot (WebSocket, `metric: "snapshot"`) includes a top-level `since_reset` object:

```json
{
  "since_reset": {
    "reset_at": "2026-09-03T10:00:00.000000Z",
    "rebased_at": null,
    "source": {
      "bytes_in_total": 12345,
      "srt": { "packets-received": 900, "packets-received-lost": 3 }
    },
    "destinations": [
      {
        "id": "dest-uuid",
        "bytes_out_total": 999,
        "drops": 0,
        "srt": { "packets-sent": 900, "packets-sent-lost": 1 }
      }
    ]
  }
}
```

Only monotonic counter fields appear in `since_reset`. Rates, percentages, RTT, and negotiated latency are not included. A field missing from either the baseline or the current tick is omitted (not zero).

When the SRT connection restarts, socket counters reset to zero. If any differenced field in the current tick is lower than its baseline value, the route baseline is re-taken from the current tick and `rebased_at` is set to that moment. `reset_at` keeps the operator's original reset time. Reported figures then cover only the time since `rebased_at`.

When no baseline is set, the `since_reset` key is absent from the snapshot.

#### Set Statistics Reset Baseline

*   **Endpoint:** `POST /api/routes/:route_id/stats/reset`
*   **Description:** Captures the most recent stats tick as the display baseline.
*   **Response:** `200 OK`
    ```json
    {
      "data": {
        "route_id": "route_id",
        "stats_reset_at": "2026-09-03T10:00:00.000000Z"
      }
    }
    ```
*   **Errors:**
    *   `409 Conflict` when the route has no live handler:
        ```json
        { "error": "Route is not running" }
        ```
    *   `409 Conflict` when the handler is running but no statistics tick has arrived yet:
        ```json
        { "error": "No statistics received yet" }
        ```

#### Clear Statistics Reset Baseline

*   **Endpoint:** `DELETE /api/routes/:route_id/stats/reset`
*   **Description:** Discards the display baseline. Stored history and raw counters are unchanged.
*   **Response:** `200 OK`
    ```json
    {
      "data": {
        "route_id": "route_id",
        "stats_reset_at": null
      }
    }
    ```
*   **Errors:**
    *   `409 Conflict` when the route has no live handler:
        ```json
        { "error": "Route is not running" }
        ```

### Route Runtime Statuses

Route runtime status is exposed in route payloads via `schema_status` (fallback: `status`).

Canonical runtime statuses:

*   `starting` - route start was requested and pipeline startup is in progress.
*   `processing` - pipeline is running and processing stream data.
*   `reconnecting` - pipeline lost source continuity and is attempting to reconnect.
*   `failed` - pipeline reported a terminal failure for the current run.
*   `stopped` - route is not running.

Notes:

*   `stopping` is a UI transitional state shown while a stop request is in flight; it is not a canonical runtime status emitted by the pipeline lifecycle.
*   `started` may appear in legacy flows and should be treated as an active/running state for compatibility.

## Sources Management

### SRT Caller Stream ID

SRT source and destination endpoints in `caller` or `rendezvous` mode accept an optional
`streamid`. HydraSRT preserves the value as an opaque string and URL-encodes it when building
the SRT connection URI. Stream ID is independent of passphrase authentication.

Example caller source payload:

```json
{
  "source": {
    "schema": "SRT",
    "mode": "caller",
    "address": "198.51.100.20",
    "port": 4209,
    "streamid": "#!::r=channel",
    "authentication": true,
    "passphrase": "some_pass_1",
    "pbkeylen": 16
  }
}
```

The same `streamid` field is accepted for an SRT caller/rendezvous destination. Listener
endpoints receive the Stream ID from the remote caller and do not configure an outgoing value.

### SRT Listener IP Access Control

SRT source endpoints in `mode=listener` can optionally limit incoming caller connections by IP address. This is a source-level stream access control feature; route control only stores and forwards the source settings to the native pipeline process.

Source fields:

*   `limit_access` - boolean switch. When `false`, saved allow/deny lists are ignored and callers are not filtered by IP.
*   `allowed_list` - JSON array of IP addresses or CIDR ranges. When non-empty and `limit_access=true`, callers must match at least one entry unless they are denied.
*   `denied_list` - JSON array of IP addresses or CIDR ranges. Denied entries take priority over allowed entries.

Example source payload:

```json
{
  "source": {
    "schema": "SRT",
    "mode": "listener",
    "localaddress": "0.0.0.0",
    "localport": 4201,
    "limit_access": true,
    "allowed_list": ["10.10.0.0/16", "203.0.113.12"],
    "denied_list": ["10.10.5.20"]
  }
}
```

Accepted list entries are exact IPv4/IPv6 addresses or CIDR ranges, for example `127.0.0.1`, `192.0.2.0/24`, or `2001:db8::/32`.

Runtime logging:

*   Native emits structured `srt_access` events for connection attempts when the GStreamer SRT listener invokes `caller-connecting`.
*   The backend forwards those events into pipeline logs with category `srt_access`.
*   Rejected callers are logged with the caller IP and rejection reason, such as `denied_list`, `not_in_allowed_list`, or `invalid_address`.

Current limitation:

*   Enforcement depends on GStreamer's `srtsrc` `caller-connecting` signal. Some local GStreamer/SRT combinations do not emit that signal for ffmpeg callers unless the SRT authentication path is active, so real rejection behavior should be verified against the deployed GStreamer version before relying on it in production.

## Destinations Management

### List Destinations

*   **Endpoint:** `GET /api/routes/:route_id/destinations`
*   **Description:** Retrieves all destinations for a specific route.

### Create Destination

*   **Endpoint:** `POST /api/routes/:route_id/destinations`
*   **Description:** Adds a new destination to a route.
*   **Payload:**
    ```json
    {
      "destination": { ... }
    }
    ```

### Get Destination

*   **Endpoint:** `GET /api/routes/:route_id/destinations/:dest_id`
*   **Description:** Retrieves details of a specific destination.

### Update Destination

*   **Endpoint:** `PUT /api/routes/:route_id/destinations/:dest_id`
*   **Description:** Updates a destination.

### Delete Destination

*   **Endpoint:** `DELETE /api/routes/:route_id/destinations/:dest_id`
*   **Description:** Removes a destination from a route.

## Notifications

### Get Telegram Settings

*   **Endpoint:** `GET /api/notifications/telegram`
*   **Description:** Returns Telegram notification settings with masked token fields.

### Update Telegram Settings

*   **Endpoint:** `PUT /api/notifications/telegram`
*   **Description:** Creates or updates Telegram notification settings.
*   **Payload:**
    ```json
    {
      "notification": {
        "enabled": true,
        "bot_token": "123456:ABCDEF",
        "chat_id": "-1001234567890"
      }
    }
    ```

### Send Telegram Test Notification

*   **Endpoint:** `POST /api/notifications/telegram/test`
*   **Description:** Sends a test Telegram notification.
*   **Payload (optional):** You can pass unsaved form values under `notification` to test credentials before saving.
    ```json
    {
      "notification": {
        "enabled": true,
        "bot_token": "123456:ABCDEF",
        "chat_id": "-1001234567890"
      }
    }
    ```

## System & Diagnostics

### List Pipelines

*   **Endpoint:** `GET /api/system/pipelines`
*   **Description:** Lists active pipeline processes (simple view).

### List Pipelines Detailed

*   **Endpoint:** `GET /api/system/pipelines/detailed`
*   **Description:** Lists active pipeline processes with detailed information.

### Kill Pipeline

*   **Endpoint:** `POST /api/system/pipelines/:pid/kill`
*   **Description:** Kills a specific pipeline process.

### Nodes (Cluster Info)

*   **Endpoint:** `GET /api/nodes`
*   **Description:** Lists all nodes in the cluster with status and resource usage (CPU, RAM, Load Average).

*   **Endpoint:** `GET /api/nodes/:id`
*   **Description:** detailed information for a specific node.

## Backup & Restore

### Routes Backup

*   **Endpoint:** `GET /api/backup/routes`
*   **Description:** Downloads a versioned `hydra-srt-routes-<ddMMyyHHmm>.json` file containing portable route, source, destination, and tag configuration.

*   **Endpoint:** `POST /api/backup/routes`
*   **Description:** Validates and imports a routes backup. A successful import replaces all existing routes.
*   **Payload:** Routes backup JSON.

Routes backups include SRT passphrases. Treat backup files as sensitive.

### Download Database Backup

*   **Endpoint:** `GET /api/backup/full`
*   **Description:** Downloads a consistent SQLite `.db` snapshot for disaster recovery.
*   **Response Content-Type:** `application/octet-stream`
*   **Security note:** The database contains route passphrases, notification credentials, tokens, and other system configuration.

### Restore Backup

*   **Endpoint:** `POST /api/backup/full/restore`
*   **Description:** Validates and restores system state from a compatible SQLite `.db` snapshot. Active routes are stopped and restarted from the restored configuration. If restore fails after the database swap, the previous database is restored.
*   **Payload:** Raw SQLite DB file bytes.
*   **Compatibility:** The backup must have the same database migration versions as the running Gateway.

## MCP Tokens

MCP tokens are long-lived API keys used to authenticate MCP clients against the `/mcp` endpoint. They are separate from login session tokens returned by `POST /api/login`.

Manage tokens in the UI at `/settings/tokens` or via the REST API below. Session authentication is required for token management endpoints.

### List Tokens

*   **Endpoint:** `GET /api/tokens`
*   **Description:** Returns configured MCP tokens. Raw token values are never included in list responses.
*   **Response:**
    ```json
    {
      "data": [
        {
          "id": "uuid",
          "name": "cursor",
          "inserted_at": "2026-05-23T12:00:00.000000Z",
          "updated_at": "2026-05-23T12:00:00.000000Z"
        }
      ]
    }
    ```

### Create Token

*   **Endpoint:** `POST /api/tokens`
*   **Description:** Creates a named MCP token. The raw token value is returned only in this response.
*   **Payload:**
    ```json
    {
      "token": {
        "name": "cursor"
      }
    }
    ```
*   **Response:**
    ```json
    {
      "data": {
        "id": "uuid",
        "name": "cursor",
        "token": "generated_mcp_token",
        "inserted_at": "2026-05-23T12:00:00.000000Z",
        "updated_at": "2026-05-23T12:00:00.000000Z"
      }
    }
    ```

### Update Token

*   **Endpoint:** `PUT /api/tokens/:id`
*   **Description:** Renames an MCP token. Token values cannot be changed; create a new token instead.
*   **Payload:**
    ```json
    {
      "token": {
        "name": "new name"
      }
    }
    ```

### Delete Token

*   **Endpoint:** `DELETE /api/tokens/:id`
*   **Description:** Revokes an MCP token immediately.

## MCP Endpoint

*   **Endpoint:** `/mcp`
*   **Description:** Streamable HTTP transport for the HydraSRT MCP server.
*   **Authentication:** Requires an MCP token (not a login session token):
    `Authorization: Bearer <mcp_token>`
*   **Unauthorized responses:** `401` with `WWW-Authenticate: Bearer`
*   **Cursor example config:**
    ```json
    {
      "mcpServers": {
        "hydrasrt": {
          "url": "http://localhost:4000/mcp",
          "headers": {
            "Authorization": "Bearer YOUR_MCP_TOKEN"
          }
        }
      }
    }
    ```
