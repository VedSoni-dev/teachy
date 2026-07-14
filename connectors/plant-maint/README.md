# Plant Maintenance ERP — Teachy OpenAPI Connection

Reference **OpenAPI connection** for a legacy engineering maintenance app. Teachy reads `openapi.json`, registers tools like `plant_maint__create_work_order`, and calls the REST API directly.

## Quick start

```bash
cd connectors/plant-maint
npm start
```

Rebuild/run Teachy. The **Connections** section in the Agents tab should show **Plant Maintenance ERP** as **OpenAPI**.

## Voice demo

> "Agent, list open work orders in plant maintenance"

> "Agent, create a critical work order on PUMP-101 for bearing inspection"

## How OpenAPI connections work

1. Drop a manifest in `~/.teachy/connectors/your-app.json`
2. Point `transport.type` to `openapi` and set `spec_url` or `spec_path`
3. Teachy parses the spec → registers one agent tool per `operationId`
4. Agent calls `your_app__operation_id` → Teachy executes the HTTP request

### Manifest example

```json
{
  "connector_id": "plant-maint",
  "name": "Plant Maintenance ERP",
  "description": "Legacy plant maintenance system",
  "transport": {
    "type": "openapi",
    "base_url": "http://127.0.0.1:9477",
    "spec_url": "http://127.0.0.1:9477/openapi.json"
  },
  "enabled": true
}
```

Use `spec_path` instead of `spec_url` for local specs:

```json
"spec_path": "~/.teachy/connectors/plant-maint.openapi.json"
```

## REST API (this demo)

| Method | Path | operationId |
|--------|------|-------------|
| GET | `/assets` | `list_assets` |
| GET | `/assets/{asset_id}` | `get_asset` |
| GET | `/work-orders` | `list_work_orders` |
| POST | `/work-orders` | `create_work_order` |
| GET | `/work-orders/{work_order_id}` | `get_work_order` |
| PATCH | `/work-orders/{work_order_id}/status` | `update_work_order_status` |

Internal routes (hidden from agent via `x-clicky-hidden`):

- `GET /health` — connection health check
- `GET /openapi.json` — OpenAPI spec

## Teachy-specific HTTP connector (alternative)

For apps without OpenAPI, use `transport.type: "http"` with the legacy Teachy protocol:

- `GET /tools` — tool list
- `POST /tools/{name}` — invoke tool with `{ "arguments": { ... } }`

OpenAPI is preferred when you have or can generate a spec.

## Add your own app

1. Write or export an OpenAPI 3 JSON spec for the app's API
2. Add a manifest pointing at `base_url` + `spec_url`/`spec_path`
3. Hit **Refresh** in Teachy → **Connections**

For legacy desktop software, run a thin local adapter that exposes REST + OpenAPI and translates to CLI/COM/batch jobs behind the scenes.
