FROM python:3.12-slim
WORKDIR /app
COPY relay.py .
USER nobody
EXPOSE 27970/udp
CMD ["python", "-u", "relay.py", "--port", "27970"]
