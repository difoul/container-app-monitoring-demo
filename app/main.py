import os
from fastapi import FastAPI
from app.routers import load, errors, latency, scaling

_connection_string = os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING")

if _connection_string:
    from azure.monitor.opentelemetry import configure_azure_monitor
    configure_azure_monitor(connection_string=_connection_string)

app = FastAPI(
    title="Azure Container App Monitoring Demo",
    description="Endpoints for generating load, errors, latency, and scaling events to test Azure monitoring.",
    version="1.0.0",
)

app.include_router(load.router)
app.include_router(errors.router)
app.include_router(latency.router)
app.include_router(scaling.router)

if _connection_string:
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
    FastAPIInstrumentor.instrument_app(app)


@app.get("/health", tags=["health"])
def health():
    return {"status": "ok"}


@app.get("/", tags=["health"])
def root():
    return {
        "service": "azure-container-app-monitoring-demo",
        "endpoints": {
            "cpu_load": "POST /load/cpu?duration=30&intensity=80",
            "memory_load": "POST /load/memory?mb=256&duration=30",
            "error": "GET /errors/{code}",
            "latency": "GET /latency?ms=2000",
            "burst": "GET /burst?requests=100",
            "health": "GET /health",
            "docs": "GET /docs",
        },
    }
