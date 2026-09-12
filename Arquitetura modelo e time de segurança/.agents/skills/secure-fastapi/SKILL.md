---
name: secure-fastapi
description: >-
  Ensures the agent builds secure FastAPI + React applications following Zero Trust principles.
  Prevents common vulnerabilities (RLS leaks, exposed secrets, unauthenticated routes, missing RBAC).
  Always trigger this skill when creating new routes, services, or authentication logic.
---

# Secure FastAPI + React Development

When writing code for FastAPI backends and React frontends, you MUST follow these security requirements based on the OWASP Top 10 and real-world vulnerability reports.

## 1. Zero Trust & Backend Validation

- **NEVER trust the frontend.** The frontend React app is merely a UI. Hiding a button or filtering a list in React is NOT security.
- Every single validation (roles, ownership, file types) MUST happen in the FastAPI backend.

## 2. Row-Level Security (RLS / Tenant Isolation)

- When querying the database, you MUST filter by the user's tenant or organization ID (Application-level filtering). Differentiate this from database-native RLS (PostgreSQL Policies) - both are valid but offer different guarantees.
- **BAD**: `db.query(User).all()`
- **GOOD**: `db.query(User).filter(User.company_id == current_user.company_id).all()`
- When updating or deleting, verify the resource belongs to the user's company before modifying it (IDOR protection).

## 3. Role-Based Access Control (RBAC) & Audit

- Create a reusable dependency (e.g., `require_permission("users.manage")`) to protect routes based on the user's role.
- Apply this dependency to ALL routes that modify data (POST, PUT, DELETE).
- **Audit Logging**: All sensitive actions (creating/deleting users, changing permissions) MUST be logged with the user ID, timestamp, and action details.

## 4. Authentication, Tokens & Sessions

- Apply a 'deny by default' policy with explicit exceptions (e.g., login, healthcheck, validated webhooks).
- **Token Storage**: Recommend storing JWT tokens in `HttpOnly`, `Secure`, `SameSite=Strict` cookies rather than `localStorage` to prevent XSS exfiltration.
- **CSRF Protection**: If using cookies for session management, you must implement CSRF protection. Note that `SameSite=Strict` is a strong defense but does not cover all subdomains/cross-site scenarios; evaluate anti-CSRF tokens if relying solely on cookies.
- **Account Lockout**: Implement a lockout policy for failed login attempts.
- **Token Revocation**: Implement a blacklist or revocation mechanism upon logout so Refresh Tokens can be invalidated early.

## 5. Secrets Management & Deployment

- **NEVER** hardcode database URLs, passwords, or secret keys in `.py` files.
- Always use `os.environ.get()` or Pydantic `Settings`. Fail fast if secrets are missing in production.
- Exclude `.env` in `.gitignore`.
- **Container Security**: When generating `Dockerfile`s, DO NOT run the application as the `root` user.

## 6. Input Validation (File Uploads & SSRF)

- **Uploads**: You MUST validate file extensions (whitelist), limit max file size, and check magic bytes. Sanitize the filename by generating a UUID.
- **SSRF Prevention**: If the application makes outbound HTTP requests, you must validate the `url` against a strict whitelist of allowed domains/IPs. You must enforce DNS resolution checks (block private/link-local/loopback IPs), limit redirects, set strict timeouts, limit response size, and ideally use egress control in the infrastructure.

## 7. Password Hashing & Database

- Passwords MUST be hashed using Argon2id or bcrypt (via `passlib`) depending on corporate standards. Never store plain-text passwords.
- Configure the SQLAlchemy engine with `pool_pre_ping=True` and `pool_recycle=300`.

## 8. Automated Verification (Closing the Loop)

After generating or modifying code, you MUST instruct the user or subagents to run the CI/CD gate script:
- Run `./audit.sh` which encapsulates Bandit, pip-audit, safety, npm audit, and custom AST checks (SSRF, CORS, auth, path traversal). Note: Gitleaks runs as a separate GitHub Action in the CI pipeline, not via `audit.sh`.
- Recommend setting up a GitHub Actions workflow and a pre-commit hook.

If you are asked to generate a new endpoint, setup auth, or create a service layer, you must review this checklist before outputting the code.
