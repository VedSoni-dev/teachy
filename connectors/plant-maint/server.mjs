#!/usr/bin/env node
/**
 * Plant Maintenance ERP — HeyClicky OpenAPI connection demo.
 *
 * REST API + OpenAPI spec. HeyClicky reads openapi.json and calls operations
 * directly (list_assets, create_work_order, etc.) — no mouse automation.
 */

import http from "node:http";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const CONNECTOR_ID = "plant-maint";
const PORT = Number(process.env.PLANT_MAINT_PORT || 9477);
const moduleDirectory = dirname(fileURLToPath(import.meta.url));
const openAPISpecJSON = readFileSync(join(moduleDirectory, "openapi.json"), "utf8");

/** @type {Record<string, { asset_id: string, name: string, plant: string, criticality: string }>} */
const assets = {
  "PUMP-101": { asset_id: "PUMP-101", name: "Cooling Water Pump #1", plant: "Building A", criticality: "high" },
  "COMPRESSOR-204": { asset_id: "COMPRESSOR-204", name: "Air Compressor Line 2", plant: "Building B", criticality: "medium" },
  "MOTOR-305": { asset_id: "MOTOR-305", name: "Conveyor Drive Motor", plant: "Warehouse", criticality: "low" },
  "VALVE-412": { asset_id: "VALVE-412", name: "Steam Isolation Valve", plant: "Building A", criticality: "high" },
};

/** @type {Array<{ work_order_id: string, asset_id: string, priority: string, status: string, description: string, created_at: string }>} */
const workOrders = [
  {
    work_order_id: "WO-1001",
    asset_id: "PUMP-101",
    priority: "high",
    status: "open",
    description: "Unusual vibration detected on bearing housing",
    created_at: "2026-07-01T08:30:00Z",
  },
  {
    work_order_id: "WO-1002",
    asset_id: "COMPRESSOR-204",
    priority: "medium",
    status: "in_progress",
    description: "Quarterly filter replacement",
    created_at: "2026-07-05T14:00:00Z",
  },
];

let nextWorkOrderNumber = 1003;

function readJSONBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => {
      if (chunks.length === 0) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      } catch (error) {
        reject(error);
      }
    });
    request.on("error", reject);
  });
}

function sendJSON(response, statusCode, payload) {
  const body = JSON.stringify(payload, null, 2);
  response.writeHead(statusCode, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(body),
  });
  response.end(body);
}

const server = http.createServer(async (request, response) => {
  const requestURL = new URL(request.url || "/", `http://127.0.0.1:${PORT}`);
  const pathname = requestURL.pathname;

  try {
    if (request.method === "GET" && pathname === "/health") {
      sendJSON(response, 200, {
        status: "ok",
        connector_id: CONNECTOR_ID,
        name: "Plant Maintenance ERP",
        version: "1.0.0",
      });
      return;
    }

    if (request.method === "GET" && pathname === "/openapi.json") {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(openAPISpecJSON);
      return;
    }

    if (request.method === "GET" && pathname === "/assets") {
      const plantFilter = requestURL.searchParams.get("plant")?.trim().toLowerCase() ?? null;
      const assetList = Object.values(assets).filter((asset) => {
        if (!plantFilter) return true;
        return asset.plant.toLowerCase().includes(plantFilter);
      });
      sendJSON(response, 200, { assets: assetList, count: assetList.length });
      return;
    }

    const assetMatch = pathname.match(/^\/assets\/([^/]+)$/);
    if (request.method === "GET" && assetMatch) {
      const assetID = decodeURIComponent(assetMatch[1]).trim().toUpperCase();
      const asset = assets[assetID];
      if (!asset) {
        sendJSON(response, 404, { error: `Unknown asset_id: ${assetID}` });
        return;
      }
      sendJSON(response, 200, { asset });
      return;
    }

    if (request.method === "GET" && pathname === "/work-orders") {
      const statusFilter = requestURL.searchParams.get("status")?.trim().toLowerCase() ?? null;
      const orders = workOrders.filter((workOrder) => {
        if (!statusFilter) return true;
        return workOrder.status === statusFilter;
      });
      sendJSON(response, 200, { work_orders: orders, count: orders.length });
      return;
    }

    if (request.method === "POST" && pathname === "/work-orders") {
      const requestBody = await readJSONBody(request);
      const assetID = String(requestBody.asset_id || "").trim().toUpperCase();
      if (!assets[assetID]) {
        sendJSON(response, 400, { error: `Unknown asset_id: ${assetID}` });
        return;
      }

      const priority = String(requestBody.priority || "medium").toLowerCase();
      const description = String(requestBody.description || "").trim();
      if (!description) {
        sendJSON(response, 400, { error: "description is required" });
        return;
      }

      const workOrderID = `WO-${nextWorkOrderNumber}`;
      nextWorkOrderNumber += 1;

      const newWorkOrder = {
        work_order_id: workOrderID,
        asset_id: assetID,
        priority,
        status: "open",
        description,
        created_at: new Date().toISOString(),
      };
      workOrders.push(newWorkOrder);
      sendJSON(response, 201, {
        work_order: newWorkOrder,
        message: `Created ${workOrderID} for ${assetID}`,
      });
      return;
    }

    const workOrderMatch = pathname.match(/^\/work-orders\/([^/]+)$/);
    if (request.method === "GET" && workOrderMatch) {
      const workOrderID = decodeURIComponent(workOrderMatch[1]).trim().toUpperCase();
      const workOrder = workOrders.find((order) => order.work_order_id === workOrderID);
      if (!workOrder) {
        sendJSON(response, 404, { error: `Unknown work_order_id: ${workOrderID}` });
        return;
      }
      sendJSON(response, 200, { work_order: workOrder });
      return;
    }

    const statusMatch = pathname.match(/^\/work-orders\/([^/]+)\/status$/);
    if (request.method === "PATCH" && statusMatch) {
      const workOrderID = decodeURIComponent(statusMatch[1]).trim().toUpperCase();
      const requestBody = await readJSONBody(request);
      const newStatus = String(requestBody.status || "").trim().toLowerCase();
      const workOrder = workOrders.find((order) => order.work_order_id === workOrderID);
      if (!workOrder) {
        sendJSON(response, 404, { error: `Unknown work_order_id: ${workOrderID}` });
        return;
      }
      workOrder.status = newStatus;
      sendJSON(response, 200, {
        work_order: workOrder,
        message: `Updated ${workOrderID} to ${newStatus}`,
      });
      return;
    }

    sendJSON(response, 404, { error: "Not found" });
  } catch (error) {
    sendJSON(response, 400, { error: error instanceof Error ? error.message : String(error) });
  }
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`Plant Maintenance ERP listening on http://127.0.0.1:${PORT}`);
  console.log(`OpenAPI spec: http://127.0.0.1:${PORT}/openapi.json`);
  console.log(`Connector ID: ${CONNECTOR_ID}`);
});
