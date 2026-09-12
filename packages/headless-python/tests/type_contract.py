from __future__ import annotations

from typing import assert_type

from headless_sdk import AsyncClient, AuthenticationRequiredError, Client, Untrusted
from headless_sdk.generated import AuthenticationLogin, PageState


def sync_contract(client: Client, error: AuthenticationRequiredError) -> None:
    page = client.session("work").visit(url="https://example.com")
    assert_type(page, Untrusted[PageState])
    login = client.session("work").auth_login(challenge="id", account="work")
    assert_type(login, Untrusted[AuthenticationLogin])
    assert_type(error.details.value["challenge"], str)


async def async_contract(client: AsyncClient) -> None:
    page = await client.session("work").visit(url="https://example.com")
    assert_type(page, Untrusted[PageState])
    login = await client.session("work").auth_login(interactive=True)
    assert_type(login, Untrusted[AuthenticationLogin])
