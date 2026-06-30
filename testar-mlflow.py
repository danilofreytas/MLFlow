#!/usr/bin/env python3
"""Smoke test do MLflow no mark-server."""
import os
import sys

import mlflow

URI = os.environ.get("MLFLOW_TRACKING_URI", "http://192.168.15.56:31906")
EXPERIMENT = "gromit-smoke-test"

mlflow.set_tracking_uri(URI)
mlflow.set_experiment(EXPERIMENT)

with mlflow.start_run(run_name="smoke-test") as run:
    mlflow.log_param("source", "gromit-mlflow-test")
    mlflow.log_metric("accuracy", 0.99)
    print(f"tracking_uri={URI}")
    print(f"experiment={EXPERIMENT}")
    print(f"run_id={run.info.run_id}")
    print("OK")
