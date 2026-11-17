FROM forkop-ci

RUN apt-get update && apt-get install -y --no-install-recommends python3 time \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /repo
ENTRYPOINT ["python3", "/repo/tests/benchmarks/singbox.py"]
