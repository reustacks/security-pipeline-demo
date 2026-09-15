# Slim base: smaller image, smaller attack surface than the full python image.
FROM python:3.12-slim

# Upgrade OS packages before installing anything else. The base image
# tag can lag behind Debian's own security patches by days or weeks,
# and this is exactly the gap container-scan (Trivy) catches: CVEs in
# packages baked into the base image, not in requirements.txt.
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*

# Dedicated non-root user. Matches the least-privilege pattern used
# elsewhere in this project (the IAM policy scoped to one bucket ARN, no
# root AWS user) applied one layer down, to the container itself.
RUN useradd --create-home --shell /usr/sbin/nologin appuser

WORKDIR /app

# Copy requirements and install dependencies before copying app code.
# Docker caches layers by content hash: as long as requirements.txt is
# unchanged, this layer is reused on rebuilds instead of reinstalling
# every dependency each time app.py changes.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Safe here specifically because Docker's network isolation means
# 0.0.0.0 inside the container is only reachable via an explicit `-p`
# port mapping to the host, unlike binding 0.0.0.0 directly on a bare
# host, which exposes the port to the whole network.
ENV FLASK_HOST=0.0.0.0

# Hand the app directory to the non-root user, then drop root privileges
# for the rest of the image (including the process that ends up running).
RUN chown -R appuser:appuser /app
USER appuser

EXPOSE 8000

# gunicorn, not `flask run` / the Flask dev server: the dev server isn't
# meant to sit behind a real deployment (ECS/EKS next), and doesn't
# handle concurrent requests the way a production WSGI server does.
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "app:app"]
