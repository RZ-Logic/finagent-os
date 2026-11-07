"""
FinAgent OS: Supabase Auth password session for one user.

FAO-GOV-002 / FAO-GOV-004 (identity): the database takes identity only from
the signed-in session (auth.uid()). The MCP server reads as the dedicated
reader user and starts runs with the human invoker's own session, so every
call is attributed to a real Auth user and never to a key.
"""
from __future__ import annotations

import threading
import time
from typing import Callable, Optional

from fao_rest import FaoError, RestClient

# Refresh the cached access token this many seconds before it expires.
EXPIRY_MARGIN_SECONDS = 60


class UserSession:
    """Password-grant session with a cached access token.

    The password is held only in this object and is never part of any
    error, repr or return value.
    """

    def __init__(
        self,
        email: str,
        password: str,
        rest: RestClient,
        *,
        clock: Callable[[], float] = time.time,
    ) -> None:
        if not isinstance(email, str) or not email:
            raise ValueError("email is required")
        if not isinstance(password, str) or not password:
            raise ValueError("password is required")
        self.email = email
        self._password = password
        self._rest = rest
        self._clock = clock
        self._token: Optional[str] = None
        self._expires_at = 0.0
        self._lock = threading.Lock()

    def __repr__(self) -> str:
        return "UserSession()"

    def bearer(self) -> str:
        """Return a valid access token, signing in again when needed.

        Raises FaoError('auth', status) when sign-in is refused, or the
        transport kinds (timeout, connect) when Auth cannot be reached.
        """
        with self._lock:
            now = self._clock()
            if self._token and now < self._expires_at - EXPIRY_MARGIN_SECONDS:
                return self._token
            self._token = None
            status, payload = self._rest.password_grant(self.email, self._password)
            if status != 200 or not isinstance(payload, dict):
                raise FaoError("auth", status)
            token = payload.get("access_token")
            if not isinstance(token, str) or not token:
                raise FaoError("auth", status)
            expires_at = payload.get("expires_at")
            expires_in = payload.get("expires_in")
            if isinstance(expires_at, (int, float)) and not isinstance(expires_at, bool):
                self._expires_at = float(expires_at)
            elif isinstance(expires_in, (int, float)) and not isinstance(expires_in, bool):
                self._expires_at = now + float(expires_in)
            else:
                # Unknown lifetime: use the token for this call only.
                self._expires_at = now
            self._token = token
            return token
