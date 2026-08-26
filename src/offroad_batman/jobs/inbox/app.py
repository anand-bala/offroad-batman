"""FastAPI callback inbox application."""

from __future__ import annotations

from typing import Any

from fastapi import Body, FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import ValidationError

from ..errors import IdempotencyConflict
from ..models import CallbackReceipt
from .storage import CallbackInbox


def create_callback_inbox_app(inbox: CallbackInbox) -> FastAPI:
    """Create the temporary callback endpoint used on ragnarhorn."""

    app = FastAPI()

    @app.exception_handler(RequestValidationError)
    async def invalid_request(
        request: Request,
        error: RequestValidationError,
    ) -> JSONResponse:
        del request, error
        return JSONResponse(
            status_code=422,
            content={"error": {"code": "invalid_submission", "retryable": False}},
        )

    @app.post("/v1/callbacks")
    async def receive_callback(
        payload: dict[str, Any] = Body(...),
    ) -> JSONResponse:
        try:
            event, duplicate = await inbox.accept(payload)
        except ValidationError:
            return JSONResponse(
                status_code=422,
                content={
                    "error": {
                        "code": "invalid_submission",
                        "message": "callback payload is invalid",
                        "retryable": False,
                    }
                },
            )
        except IdempotencyConflict as exc:
            return JSONResponse(
                status_code=409,
                content={
                    "error": {
                        "code": exc.code.value,
                        "message": exc.message,
                        "retryable": exc.retryable,
                    }
                },
            )
        receipt = CallbackReceipt(event_id=event.event_id, duplicate=duplicate)
        return JSONResponse(content=receipt.model_dump(mode="json"))

    return app
