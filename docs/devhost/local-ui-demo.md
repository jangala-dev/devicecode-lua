# Local UI devhost demo

This demo is for the initial local UI port. It starts the real HTTP, UI and GSM
services, and uses a fake HAL control-store capability for GSM APN persistence.
No hardware is required.

Run from the repository root:

```sh
scripts/devhost-local-ui-demo --port 18089
```

Then open:

```text
http://127.0.0.1:18089/
```

Useful checks:

```sh
curl -fsS http://127.0.0.1:18089/api/local-ui/bootstrap
curl -fsS http://127.0.0.1:18089/api/gsm/apns/custom
curl -fsS http://127.0.0.1:18089/api/diagnostics
```

Update the prototype APN store:

```sh
curl -fsS -X PUT \
  -H 'Content-Type: application/json' \
  -d '{"records":[{"carrier":"Demo Carrier","mcc":"234","mnc":"10","apn":"demo.internet"}]}' \
  http://127.0.0.1:18089/api/gsm/apns/custom
```

The fake control-store is in-memory and lasts only for the lifetime of the demo
process. This is deliberate: the demo proves the service boundaries and UI HTTP
paths without writing host state.
