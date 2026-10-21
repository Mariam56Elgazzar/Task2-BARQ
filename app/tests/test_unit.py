from unittest.mock import Mock

import psycopg
import pytest

from app.config import Settings
from app.db import Database


def valid_env():
    return {"DB_HOST": "127.0.0.1", "DB_NAME": "notes", "DB_USER": "notes_app", "DB_PASSWORD": "test-only"}


def test_configuration_has_no_default_password():
    env = valid_env()
    del env["DB_PASSWORD"]
    with pytest.raises(ValueError, match="DB_PASSWORD"):
        Settings.from_env(env)


@pytest.mark.parametrize("port", ["0", "65536", "invalid-sensitive-value"])
def test_bad_port_is_rejected_without_echoing_value(port):
    with pytest.raises(ValueError) as error:
        Settings.from_env({**valid_env(), "DB_PORT": port})
    assert str(error.value) == "DB_PORT must be an integer between 1 and 65535"


def test_password_is_not_in_settings_repr():
    settings = Settings.from_env(valid_env())
    assert settings.password not in repr(settings)
    assert settings.port == 5432


@pytest.mark.parametrize("host", ["host1,host2", "host with spaces", "host\nother"])
def test_only_one_host_is_accepted(host):
    with pytest.raises(ValueError, match="DB_HOST"):
        Settings.from_env({**valid_env(), "DB_HOST": host})


def test_startup_retry_is_bounded_and_does_not_log_connection_errors(monkeypatch, caplog):
    database = Database(Settings.from_env(valid_env()))
    probe = Mock(side_effect=psycopg.OperationalError("sensitive-database-details"))
    sleep = Mock()
    monkeypatch.setattr(database, "ready", probe)
    monkeypatch.setattr("app.db.time.sleep", sleep)
    assert database.wait_until_ready() is False
    assert probe.call_count == 4
    assert [call.args[0] for call in sleep.call_args_list] == [0.5, 1.0, 2.0]
    assert "sensitive-database-details" not in caplog.text


def test_startup_retry_stops_on_recovery(monkeypatch):
    database = Database(Settings.from_env(valid_env()))
    probe = Mock(side_effect=[psycopg.OperationalError(), None])
    sleep = Mock()
    monkeypatch.setattr(database, "ready", probe)
    monkeypatch.setattr("app.db.time.sleep", sleep)
    assert database.wait_until_ready() is True
    assert probe.call_count == 2
    sleep.assert_called_once_with(0.5)
