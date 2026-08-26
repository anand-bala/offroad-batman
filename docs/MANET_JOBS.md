# MANET NumPy Jobs

`offroad_batman.jobs` runs one asynchronous NumPy job at a time over the repository's
`bat0` mesh.
The initial topology is fixed:

* `olo` runs the foreground receiver and processor.
* `ragnarhorn` submits and runs a temporary callback inbox while waiting.
* Both listeners bind to IPv6 with `::` and use port 8080.
* Peer URLs use the static `.mesh` names supplied by `etc/bat-hosts`.

The mesh is trusted.
The protocol has no authentication or encryption.
Do not expose these listeners to an untrusted network.

## Foreground Workflow

After creating the repository virtual environment, run this on `olo`:

```sh
.venv/bin/offroad-batman-jobs receive \
  --host :: \
  --port 8080 \
  --processor offroad_batman.jobs.processors:busywork \
  --once
```

Omit `--once` to run until interrupted.
The process logs to stdout and stderr.
There is no system service, installer, container, or file under `/etc`.

Run this on `ragnarhorn`:

```sh
.venv/bin/offroad-batman-jobs submit \
  --receiver http://olo.mesh:8080 \
  --input input.npy \
  --metadata metadata.json \
  --output result.npy
```

`submit` binds a temporary inbox to `[::]:8080`,
advertises `http://ragnarhorn.mesh:8080/v1/callbacks`,
generates a stable idempotency key, submits,
and waits for the durable terminal callback.
On success it downloads the result,
compares its size and SHA-256 with the callback and response headers,
loads with `allow_pickle=False`, acknowledges it, writes atomically, and exits.
A failed or cancelled event is printed as JSON and produces a nonzero exit.

## User-Owned State

The receiver defaults to `$XDG_STATE_HOME/offroad-batman/jobs`.
When `XDG_STATE_HOME` is unset it uses `~/.local/state/offroad-batman/jobs`.
Override this with `--state-dir`.

```text
jobs.sqlite3
jobs/
    JOB_ID/
        input.npy
        result.npy
```

The inbox defaults to the `inbox` subdirectory and stores `inbox.sqlite3`.
SQLite uses its default journal and full synchronous writes.
One foreground receiver owns one `JobStorage` instance.

## HTTP Protocol

All endpoints are under `/v1`.

### Submission

```http
POST /v1/jobs
Idempotency-Key: SENDER_GENERATED_KEY
Content-Type: multipart/form-data
```

Fields are `metadata` (a JSON object), mandatory `callback_url`, and one `.npy` `array`.
The default array limit is 4 MiB.
Request and metadata limits are separate.
Object dtypes, pickle payloads, archives, corrupt files, trailing bytes,
and oversized arrays are rejected.

Durable admission returns `202` with a job ID and status URL.
The receiver checks an existing key before checking its active slot.
An identical retry returns the existing job.
Reusing a key for different content returns `409`.
A distinct job while occupied returns `503` with `Retry-After: 5`.

### Status and Cancellation

```http
GET  /v1/jobs/JOB_ID
POST /v1/jobs/JOB_ID/cancel
```

Status reports computation, callback delivery, and result state separately.
Cancellation returns `202` when initiated, `200` when already cancelling or cancelled,
`409` for completed jobs, and `404` for unknown jobs.

### Result Transfer

```http
GET  /v1/jobs/JOB_ID/result
POST /v1/jobs/JOB_ID/result-ack
```

Results use `application/x-npy`, `Content-Length`, `Digest`, and `X-Content-SHA256`.
Acknowledgement occurs only after full verification and safe loading.
It is idempotent and deletes the result.
Unacknowledged results expire after one hour by default and then return `410 Gone`.

## Terminal Callbacks

Every terminal job has one persistent callback row and stable `event_id`.
Any `2xx` acknowledges delivery.
Connection failures, timeouts, HTTP 408, 425, 429,
and 5xx responses use capped exponential backoff with jitter.
Other 4xx responses abandon delivery.
Delivery lasts up to 24 hours by default, independently of the one-hour result lifetime.

A success event contains no array:

```json
{
  "event_id": "...",
  "job_id": "...",
  "state": "succeeded",
  "result_url": "http://olo.mesh:8080/v1/jobs/.../result",
  "result_ack_url": "http://olo.mesh:8080/v1/jobs/.../result-ack",
  "content_type": "application/x-npy",
  "size_bytes": 1452312,
  "sha256": "..."
}
```

Failed and cancelled events contain stable structured errors.
Tracebacks remain only in `olo`'s local SQLite state.

The ragnarhorn inbox inserts by `event_id`.
Repeated identical events return `200` with `duplicate: true`;
conflicting reuse returns `409`.
Waiting always checks durable storage first, so an early callback is retained.

## Independent States

Computation:

```text
accepted -> running -> succeeded | failed
                  \-> cancelling -> cancelled | failed
```

Only `accepted`, `running`, and `cancelling` occupy the slot.
Terminal computation releases it immediately;
callback retries and result retention cannot block the next job.

Delivery:

```text
pending -> retrying -> acknowledged | abandoned
```

Result:

```text
unavailable -> available -> acknowledged | expired
```

Transition keys include lifecycle type as well as string value,
since delivery and result states both contain `acknowledged`.

## Processor Contract

Processors are importable top-level `module:function` objects
because workers use the multiprocessing `spawn` context.

```python
def process_image(metadata, array, context):
    context.raise_if_cancelled()
    result = array.copy()
    context.heartbeat()
    return result
```

The processor receives JSON metadata, one NumPy array, and a child context.
It returns exactly one non-object NumPy array.
Long processors must call `context.heartbeat()` as they make progress
and should call `context.raise_if_cancelled()` at cooperative interruption points.

`offroad_batman.jobs.processors:busywork` is the temporary processor.
Arrays pass by file path, never through a process queue.
The child loads without pickle and fsyncs a temporary result;
the parent validates it before atomic publication.

## Watchdogs and Cancellation

Live deadlines use monotonic time.
Wall time is persisted only for retry and retention state.
Python `spawn` requires distinct lifecycle signals:

1. The startup deadline waits for the first automatic runtime heartbeat.
2. Runtime heartbeats prove the child interpreter remains responsive.
3. `processor_started` begins the explicit progress deadline.
4. A terminal outcome starts a bounded normal-exit interval.
   The parent keeps draining the process queue
   so queue flushing cannot become a false crash.

On cancellation or timeout the parent sets the cooperative event, waits its grace,
calls `terminate()`, waits the termination grace, then calls `kill()` if needed.
All thresholds and graces are receiver settings.

## Restart and Cleanup

Startup never reruns interrupted computation.
Persisted `accepted`, `running`,
or `cancelling` jobs become `failed` with `receiver_restarted`, release the slot,
and receive a durable failed callback.
Terminal jobs and unexpired results remain.
Pending callbacks resume delivery.

Startup removes temporary crash leftovers before any worker starts.
Periodic in-process cleanup expires results,
abandons callbacks after their independent lifetime,
and removes fully settled diagnostic records after 24 hours.
Periodic cleanup never touches worker temporary files.

This policy is deterministic
and does not claim exactly-once computation across machine crashes.

## Stable Error Codes

```text
invalid_submission
receiver_busy
worker_exception
worker_crashed
worker_startup_timeout
worker_unresponsive
progress_timeout
invalid_result
cancelled
receiver_restarted
receiver_error
result_expired
```

Callers should branch on the code and `retryable` field.
Human messages are for diagnostics.

## Python Sender API

```python
import numpy as np
from offroad_batman.jobs import Client

async with Client() as client:
    job = await client.submit(
        receiver_url="http://olo.mesh:8080",
        array=np.arange(10),
        metadata={"operation": "busywork"},
        callback_url="http://ragnarhorn.mesh:8080/v1/callbacks",
    )
    status = await job.status()
```

HTTPX uses libc hostname resolution, explicit mesh-appropriate timeouts,
and `trust_env=False`.
Advanced foreground integrations can construct `ReceiverService`, call `start()`,
mount `create_receiver_app(service)`, and call `shutdown()`.
Use one Uvicorn worker.

## Testing

```sh
.venv/bin/pytest -q
```

The suite covers array safety, SQLite durability and admission,
real spawned workers and watchdogs, ASGI protocol behavior,
callback retry and deduplication, expiration, restart reconciliation, CLI helpers,
and a real Uvicorn IPv6 loopback socket.

Loopback does not emulate `batman-adv`, packet loss, or radio reconvergence.
Final validation requires a 1-2 MiB submission from `ragnarhorn.mesh` to `olo.mesh` over
live `bat0`.
A privileged network-namespace/netem smoke test may be added later.

## Limits

The implementation supports one receiver process, one Uvicorn worker, one active job,
one input, and one result.
It has no authentication, encryption, queued work, distributed scheduling,
multiple workers, progress percentages, per-job deadlines, or resumable downloads.
Do not run two receivers against one state directory.
