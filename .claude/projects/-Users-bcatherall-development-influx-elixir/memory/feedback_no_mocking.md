---
name: no-mocking-ever
description: Never use mocking libraries (Mox, Bypass, etc.) in this project — test against real services
type: feedback
---

Never use mocking in this project. No Mox, no Bypass, no mock libraries of any kind.

**Why:** The design philosophy requires testing against real InfluxDB instances, not fakes. Mocks hide real integration issues.

**How to apply:** All tests that need HTTP interaction should hit a real InfluxDB v3 instance. Use tagged tests to skip integration tests when no instance is available.
