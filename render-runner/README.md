# Render isolated test runner

This service runs only the synthetic fixture in `tests/setup.sql` and `tests/assert_concurrency.sql`.
It does not connect to Supabase or the GAME WORLD production site.

## Render configuration

- Runtime: Python
- Root directory: repository root
- Build command: `pip install -r render-runner/requirements.txt`
- Start command: `uvicorn render-runner.main:app --host 0.0.0.0 --port $PORT`

Set these environment variables in the Render Dashboard:
- `DATABASE_URL`: the **internal** connection URL of the isolated Render database named `royal-arena-isolated-test`.
- `TEST_TOKEN`: a long random secret used only to authorize the test endpoint.

The public `GET /` route is a health check. Run the test by sending a POST request to `/run` with header `X-Test-Token: <TEST_TOKEN>`.

The runner recreates only the `concurrency_test` schema on every run. Do not point it at any production database.
