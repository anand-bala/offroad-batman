"""FastAPI receiver application."""

from __future__ import annotations

import json
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Form, Header, Request, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from pydantic import ValidationError
from starlette.middleware.base import RequestResponseEndpoint
from starlette.responses import Response

from ..errors import (
    ArrayValidationError,
    IdempotencyConflict,
    JobsError,
    ReceiverBusy,
    ResultExpired,
    ResultUnavailable,
    UnknownJob,
)
from ..models import (
    ErrorInfo,
    JobAccepted,
    JobStatus,
    JobSubmission,
    ResultAcknowledgement,
)
from .service import ReceiverService


def create_receiver_app(service: ReceiverService) -> FastAPI:
    """Create one receiver app intended for a single Uvicorn worker."""

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        del app
        await service.start()
        yield
        await service.shutdown()

    app = FastAPI(lifespan=lifespan)

    @app.middleware("http")
    async def enforce_request_size(
        request: Request,
        call_next: RequestResponseEndpoint,
    ) -> Response:
        if request.method == "POST" and request.url.path == "/v1/jobs":
            content_length = request.headers.get("content-length")
            try:
                request_size = int(content_length) if content_length else None
            except ValueError:
                return _error_response(
                    ArrayValidationError("Content-Length header is invalid"),
                    400,
                )
            if (
                request_size is not None
                and request_size > service.settings.max_request_bytes
            ):
                return _error_response(
                    ArrayValidationError("submission exceeds the request-size limit"),
                    413,
                )
        return await call_next(request)

    @app.exception_handler(RequestValidationError)
    async def request_validation_error(
        request: Request,
        error: RequestValidationError,
    ) -> JSONResponse:
        del request, error
        return _error_response(
            ArrayValidationError("submission fields are missing or invalid"),
            422,
        )

    @app.exception_handler(JobsError)
    async def jobs_error(request: Request, error: JobsError) -> JSONResponse:
        del request
        if isinstance(error, ReceiverBusy):
            return _error_response(
                error,
                503,
                headers={"Retry-After": str(error.retry_after_seconds)},
            )
        if isinstance(error, IdempotencyConflict):
            return _error_response(error, 409)
        if isinstance(error, UnknownJob):
            return _error_response(error, 404)
        if isinstance(error, ResultExpired):
            return _error_response(error, 410)
        if isinstance(error, ResultUnavailable):
            return _error_response(error, 409)
        if isinstance(error, ArrayValidationError):
            return _error_response(error, 422)
        return _error_response(error, 409)

    @app.post("/v1/jobs", status_code=202)
    async def submit_job(
        array: UploadFile,
        metadata: str = Form(...),
        callback_url: str = Form(...),
        idempotency_key: str = Header(..., alias="Idempotency-Key"),
    ) -> JobAccepted:
        if not idempotency_key.strip():
            raise ArrayValidationError("Idempotency-Key must not be empty")
        if len(metadata.encode("utf-8")) > service.settings.max_metadata_bytes:
            raise ArrayValidationError("metadata exceeds the size limit")
        try:
            parsed_metadata = json.loads(metadata)
            submission = JobSubmission.model_validate(
                {
                    "metadata": parsed_metadata,
                    "callback_url": callback_url,
                }
            )
        except (json.JSONDecodeError, ValidationError, TypeError) as exc:
            raise ArrayValidationError("metadata or callback URL is invalid") from exc
        input_data = await array.read(service.settings.max_array_bytes + 1)
        return service.submit(
            idempotency_key=idempotency_key,
            metadata=submission.metadata,
            callback_url=str(submission.callback_url),
            input_data=input_data,
        )

    @app.get("/v1/jobs/{job_id}")
    async def get_status(job_id: str) -> JobStatus:
        return service.status(job_id)

    @app.post("/v1/jobs/{job_id}/cancel")
    async def cancel_job(job_id: str) -> JSONResponse:
        status, initiated = service.cancel(job_id)
        return JSONResponse(
            content=status.model_dump(mode="json"),
            status_code=202 if initiated else 200,
        )

    @app.get("/v1/jobs/{job_id}/result")
    async def get_result(job_id: str) -> FileResponse:
        artifact = service.result(job_id)
        return FileResponse(
            artifact.path,
            media_type="application/x-npy",
            headers={
                "Digest": f"sha-256={artifact.sha256}",
                "X-Content-SHA256": artifact.sha256,
            },
        )

    @app.post("/v1/jobs/{job_id}/result-ack")
    async def acknowledge_result(job_id: str) -> ResultAcknowledgement:
        return service.acknowledge_result(job_id)

    return app


def _error_response(
    error: JobsError,
    status_code: int,
    *,
    headers: dict[str, str] | None = None,
) -> JSONResponse:
    payload = ErrorInfo(
        code=error.code,
        message=error.message,
        retryable=error.retryable,
    )
    return JSONResponse(
        content={"error": payload.model_dump(mode="json")},
        status_code=status_code,
        headers=headers,
    )
