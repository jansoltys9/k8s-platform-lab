# Minimal Node.js runtime without npm, apk or a shell.
FROM gcr.io/distroless/nodejs26-debian13:nonroot

LABEL org.opencontainers.image.title="PlatformLab Backend"

ENV NODE_ENV=production \
    PORT=3000

WORKDIR /app
COPY --chown=1000:1000 server.js ./server.js

# Match Kubernetes securityContext.runAsUser/runAsGroup.
USER 1000:1000
EXPOSE 3000

# Distroless Node image already has ENTRYPOINT ["node"].
CMD ["server.js"]
