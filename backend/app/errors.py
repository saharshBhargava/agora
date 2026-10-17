from fastapi import Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse


class Problem(Exception):
    """An RFC 7807 problem response. ``detail`` is shown to users, so it must never echo private data."""

    def __init__(self, status: int, code: str, detail: str = ""):
        self.status, self.code, self.detail = status, code, detail


def problem_response(request: Request, status: int, code: str, detail: str = "") -> JSONResponse:
    body = {"type": f"https://agora.app/problems/{code}", "title": code, "status": status, "detail": detail,
            "request_id": getattr(request.state, "request_id", None)}
    return JSONResponse(body, status_code=status, media_type="application/problem+json")


async def handle_problem(request: Request, exc: Problem) -> JSONResponse:
    return problem_response(request, exc.status, exc.code, exc.detail)


async def handle_validation(request: Request, exc: RequestValidationError) -> JSONResponse:
    # Report where validation failed, but not the submitted values.
    fields = sorted({".".join(str(p) for p in err["loc"]) for err in exc.errors()})
    return problem_response(request, 422, "invalid_request", "Invalid fields: " + ", ".join(fields))


def not_found(what: str = "resource") -> Problem:
    return Problem(404, "not_found", f"No such {what}.")
