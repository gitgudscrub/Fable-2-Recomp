FROM python:3.12-slim
WORKDIR /app
COPY friends.py .
RUN mkdir /data && chown nobody /data
USER nobody
VOLUME /data
EXPOSE 18090
# RELAY = the relay address handed to players (host:port), set with -e RELAY=...
ENV RELAY=""
CMD ["sh", "-c", "exec python -u friends.py --db /data/friends.sqlite --port 18090 --relay \"$RELAY\" --trust-cf-ip"]
