-- Adds the per-user revocation cutoff for stateless JWTs. We compare
-- a token's `iat` (issued-at) against this column; if iat <
-- password_changed_at, the token is treated as stale and rejected
-- with 401, even though it's still cryptographically valid and
-- before its `exp`.
--
-- The default (`1970-01-01T00:00:00Z`) is the unix epoch, which is
-- earlier than any real-world iat. Existing users imported into
-- this column don't get their tokens invalidated unless / until
-- the operator runs `yata_backend reset-password` (which bumps the
-- column to "now").
--
-- The column is also bumped at user creation time, so a brand-new
-- user can never receive a token whose iat predates their account.

ALTER TABLE users
    ADD COLUMN password_changed_at TEXT NOT NULL
    DEFAULT '1970-01-01T00:00:00Z';
